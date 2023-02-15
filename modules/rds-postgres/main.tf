terraform {
  required_version = ">= 0.14"
  required_providers {
    aws    = { source = "hashicorp/aws", version = "~> 3.27" }
    random = { source = "hashicorp/random", version = "~> 3.0" }
  }
}

locals {
  tags = merge(var.tags, { Module = "rds-postgres" })
}

resource "aws_db_subnet_group" "this" {
  name       = var.name
  subnet_ids = var.private_subnet_ids
  tags       = local.tags
}

resource "aws_security_group" "db" {
  name        = "${var.name}-db"
  description = "Postgres; reachable only from the listed app security groups"
  vpc_id      = var.vpc_id
  tags        = local.tags
}

resource "aws_security_group_rule" "from_apps" {
  for_each                 = toset(var.allowed_security_group_ids)
  type                     = "ingress"
  security_group_id        = aws_security_group.db.id
  from_port                = 5432
  to_port                  = 5432
  protocol                 = "tcp"
  source_security_group_id = each.value
}

resource "random_password" "master" {
  length  = 32
  special = false
}

resource "aws_secretsmanager_secret" "master" {
  name       = "${var.name}/master"
  kms_key_id = var.kms_key_arn
  tags       = local.tags
}

resource "aws_secretsmanager_secret_version" "master" {
  secret_id = aws_secretsmanager_secret.master.id
  secret_string = jsonencode({
    username = var.master_username
    password = random_password.master.result
    host     = aws_db_instance.this.address
    port     = 5432
    dbname   = var.database_name
  })
}

resource "aws_db_parameter_group" "this" {
  name   = "${var.name}-pg${var.major_version}"
  family = "postgres${var.major_version}"
  tags   = local.tags

  parameter {
    name  = "rds.force_ssl"
    value = "1"
  }
  parameter {
    name  = "log_min_duration_statement"
    value = tostring(var.slow_query_ms)
  }
  parameter {
    name         = "shared_preload_libraries"
    value        = "pg_stat_statements"
    apply_method = "pending-reboot"
  }
}

resource "aws_db_instance" "this" {
  identifier                   = var.name
  engine                       = "postgres"
  engine_version               = var.engine_version
  instance_class               = var.instance_class
  allocated_storage            = var.allocated_storage_gb
  max_allocated_storage        = var.allocated_storage_gb * 4
  storage_type                 = "gp2"
  storage_encrypted            = true
  kms_key_id                   = var.kms_key_arn
  name                         = var.database_name
  username                     = var.master_username
  password                     = random_password.master.result
  multi_az                     = var.multi_az
  db_subnet_group_name         = aws_db_subnet_group.this.name
  vpc_security_group_ids       = [aws_security_group.db.id]
  parameter_group_name         = aws_db_parameter_group.this.name
  publicly_accessible          = false
  backup_retention_period      = var.backup_retention_days
  backup_window                = "07:00-08:00"
  maintenance_window           = "sun:08:30-sun:09:30"
  deletion_protection          = var.deletion_protection
  skip_final_snapshot          = !var.deletion_protection
  final_snapshot_identifier    = var.deletion_protection ? "${var.name}-final" : null
  copy_tags_to_snapshot        = true
  performance_insights_enabled = true
  auto_minor_version_upgrade   = true
  tags                         = local.tags

  lifecycle {
    ignore_changes = [password]
  }
}
