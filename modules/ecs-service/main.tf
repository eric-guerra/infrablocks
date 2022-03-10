terraform {
  required_version = ">= 0.14"
  required_providers {
    aws = { source = "hashicorp/aws", version = "~> 3.27" }
  }
}

locals {
  tags = merge(var.tags, { Module = "ecs-service", Service = var.name })
}

data "aws_region" "current" {}

resource "aws_cloudwatch_log_group" "this" {
  name              = "/ecs/${var.cluster_name}/${var.name}"
  retention_in_days = var.log_retention_days
  tags              = local.tags
}

# --- IAM: execution role pulls images/secrets; task role is what the app itself may do ---
data "aws_iam_policy_document" "assume_ecs" {
  statement {
    actions = ["sts:AssumeRole"]
    principals {
      type        = "Service"
      identifiers = ["ecs-tasks.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "execution" {
  name               = "${var.name}-exec"
  assume_role_policy = data.aws_iam_policy_document.assume_ecs.json
  tags               = local.tags
}

resource "aws_iam_role_policy_attachment" "execution" {
  role       = aws_iam_role.execution.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AmazonECSTaskExecutionRolePolicy"
}

data "aws_iam_policy_document" "secrets" {
  count = length(var.secrets) > 0 ? 1 : 0
  statement {
    actions   = ["secretsmanager:GetSecretValue", "ssm:GetParameters"]
    resources = values(var.secrets)
  }
}

resource "aws_iam_role_policy" "secrets" {
  count  = length(var.secrets) > 0 ? 1 : 0
  role   = aws_iam_role.execution.id
  policy = data.aws_iam_policy_document.secrets[0].json
}

resource "aws_iam_role" "task" {
  name               = "${var.name}-task"
  assume_role_policy = data.aws_iam_policy_document.assume_ecs.json
  tags               = local.tags
}

resource "aws_iam_role_policy" "task" {
  count  = var.task_policy_json == null ? 0 : 1
  role   = aws_iam_role.task.id
  policy = var.task_policy_json
}

# --- Networking ---
resource "aws_security_group" "service" {
  name        = "${var.name}-svc"
  description = "${var.name} tasks; ingress only from its load balancer"
  vpc_id      = var.vpc_id
  tags        = local.tags

  ingress {
    from_port       = var.container_port
    to_port         = var.container_port
    protocol        = "tcp"
    security_groups = [var.alb_security_group_id]
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }
}

resource "aws_lb_target_group" "this" {
  name                 = substr("${var.name}-tg", 0, 32)
  port                 = var.container_port
  protocol             = "HTTP"
  target_type          = "ip"
  vpc_id               = var.vpc_id
  deregistration_delay = 30
  tags                 = local.tags

  health_check {
    path                = var.health_check_path
    matcher             = "200-299"
    interval            = 15
    healthy_threshold   = 2
    unhealthy_threshold = 3
  }
}

resource "aws_lb_listener_rule" "this" {
  listener_arn = var.listener_arn
  priority     = var.listener_priority
  tags         = local.tags

  action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.this.arn
  }

  condition {
    host_header {
      values = var.host_headers
    }
  }
}

# --- Task + service ---
resource "aws_ecs_task_definition" "this" {
  family                   = var.name
  requires_compatibilities = ["FARGATE"]
  network_mode             = "awsvpc"
  cpu                      = var.cpu
  memory                   = var.memory
  execution_role_arn       = aws_iam_role.execution.arn
  task_role_arn            = aws_iam_role.task.arn
  tags                     = local.tags

  container_definitions = jsonencode([{
    name         = var.name
    image        = var.image
    essential    = true
    portMappings = [{ containerPort = var.container_port, protocol = "tcp" }]
    environment  = [for k, v in var.environment : { name = k, value = v }]
    secrets      = [for k, arn in var.secrets : { name = k, valueFrom = arn }]
    readonlyRootFilesystem = true
    linuxParameters        = { initProcessEnabled = true }
    logConfiguration = {
      logDriver = "awslogs"
      options = {
        awslogs-group         = aws_cloudwatch_log_group.this.name
        awslogs-region        = data.aws_region.current.name
        awslogs-stream-prefix = var.name
      }
    }
  }])
}

resource "aws_ecs_service" "this" {
  name                               = var.name
  cluster                            = var.cluster_arn
  task_definition                    = aws_ecs_task_definition.this.arn
  desired_count                      = var.min_count
  launch_type                        = "FARGATE"
  deployment_minimum_healthy_percent = 100
  deployment_maximum_percent         = 200
  health_check_grace_period_seconds  = 60
  propagate_tags                     = "SERVICE"
  enable_execute_command             = var.enable_exec
  tags                               = local.tags

  deployment_circuit_breaker {
    enable   = true
    rollback = true
  }

  network_configuration {
    subnets          = var.private_subnet_ids
    security_groups  = [aws_security_group.service.id]
    assign_public_ip = false
  }

  load_balancer {
    target_group_arn = aws_lb_target_group.this.arn
    container_name   = var.name
    container_port   = var.container_port
  }

  # Autoscaling owns desired_count after creation.
  lifecycle {
    ignore_changes = [desired_count]
  }
}

resource "aws_appautoscaling_target" "this" {
  service_namespace  = "ecs"
  resource_id        = "service/${var.cluster_name}/${aws_ecs_service.this.name}"
  scalable_dimension = "ecs:service:DesiredCount"
  min_capacity       = var.min_count
  max_capacity       = var.max_count
}

resource "aws_appautoscaling_policy" "cpu" {
  name               = "${var.name}-cpu"
  service_namespace  = aws_appautoscaling_target.this.service_namespace
  resource_id        = aws_appautoscaling_target.this.resource_id
  scalable_dimension = aws_appautoscaling_target.this.scalable_dimension
  policy_type        = "TargetTrackingScaling"

  target_tracking_scaling_policy_configuration {
    target_value       = var.target_cpu_percent
    scale_in_cooldown  = 300
    scale_out_cooldown = 60
    predefined_metric_specification {
      predefined_metric_type = "ECSServiceAverageCPUUtilization"
    }
  }
}
