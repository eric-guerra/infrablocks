terraform {
  required_version = ">= 0.14"
  required_providers {
    aws    = { source = "hashicorp/aws", version = "~> 3.27" }
    random = { source = "hashicorp/random", version = "~> 3.0" }
  }

  backend "s3" {
    bucket         = "infrablocks-tfstate-123456789012"
    key            = "prod/platform.tfstate"
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
  env = "prod"
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
  expire_after_days  = 365
  tags               = local.tags
}

module "vpc" {
  source              = "../../modules/vpc"
  name                = "ecom-${local.env}"
  cidr                = "10.30.0.0/16"
  az_count            = 3
  single_nat_gateway  = false
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
  instance_class             = "db.r5.large"
  allocated_storage_gb       = 200
  multi_az                   = true
  deletion_protection        = true
  backup_retention_days      = 30
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
  host_headers          = ["orders.example.com"]
  image                 = "123456789012.dkr.ecr.us-east-1.amazonaws.com/orders-api:${var.orders_api_version}"
  min_count             = 3
  max_count             = 20
  cpu                   = 1024
  memory                = 2048
  environment = {
    SPRING_PROFILES_ACTIVE = local.env
  }
  secrets = {
    DB_SECRET = module.orders_db.secret_arn
  }
  tags = local.tags
}
