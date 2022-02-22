terraform {
  required_version = ">= 0.14"
  required_providers {
    aws    = { source = "hashicorp/aws", version = "~> 3.27" }
    random = { source = "hashicorp/random", version = "~> 3.0" }
  }

  backend "s3" {
    bucket         = "infrablocks-tfstate-123456789012"
    key            = "staging/platform.tfstate"
    region         = "us-east-1"
    dynamodb_table = "infrablocks-tf-locks"
    encrypt        = true
  }
}

provider "aws" {
  region = "us-east-1"
  default_tags {
    tags = local.tags
  }
}

locals {
  env = "staging"
  tags = {
    Environment = local.env
    Owner       = "platform-team"
    CostCenter  = "ecom-1042"
    ManagedBy   = "terraform"
  }
}

module "logs" {
  source             = "../../modules/s3-bucket"
  name               = "infrablocks-${local.env}-logs"
  allow_log_delivery = true
  expire_after_days  = 30
  force_destroy      = true
  tags               = local.tags
}

module "vpc" {
  source              = "../../modules/vpc"
  name                = "ecom-${local.env}"
  cidr                = "10.20.0.0/16"
  az_count            = 2
  single_nat_gateway  = true
  flow_log_bucket_arn = module.logs.arn
  tags                = local.tags
}

module "orders_db" {
  source                     = "../../modules/rds-postgres"
  name                       = "orders-${local.env}"
  vpc_id                     = module.vpc.vpc_id
  private_subnet_ids         = module.vpc.private_subnet_ids
  allowed_security_group_ids = [module.orders_api.security_group_id]
  database_name              = "orders"
  instance_class             = "db.t3.small"
  multi_az                   = false
  deletion_protection        = false
  backup_retention_days      = 3
  tags                       = local.tags
}

module "orders_api" {
  source                = "../../modules/ecs-service"
  name                  = "orders-api"
  cluster_name          = aws_ecs_cluster.main.name
  cluster_arn           = aws_ecs_cluster.main.arn
  vpc_id                = module.vpc.vpc_id
  private_subnet_ids    = module.vpc.private_subnet_ids
  alb_security_group_id = aws_security_group.alb.id
  listener_arn          = aws_lb_listener.https.arn
  listener_priority     = 100
  host_headers          = ["orders.staging.example.com"]
  image                 = "123456789012.dkr.ecr.us-east-1.amazonaws.com/orders-api:${var.orders_api_version}"
  min_count             = 1
  max_count             = 3
  enable_exec           = true
  environment = {
    SPRING_PROFILES_ACTIVE = local.env
  }
  secrets = {
    DB_SECRET = module.orders_db.secret_arn
  }
  tags = local.tags
}
