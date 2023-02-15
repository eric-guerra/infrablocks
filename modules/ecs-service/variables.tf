variable "name" { type = string }
variable "cluster_name" { type = string }
variable "cluster_arn" { type = string }
variable "vpc_id" { type = string }
variable "private_subnet_ids" { type = list(string) }
variable "alb_security_group_id" { type = string }
variable "listener_arn" { type = string }
variable "listener_priority" { type = number }
variable "host_headers" { type = list(string) }

variable "image" {
  type        = string
  description = "Image reference; must be pinned by digest or immutable tag, never :latest."
  validation {
    condition     = !can(regex(":latest$", var.image))
    error_message = "Do not deploy :latest; pin a version or digest."
  }
}

variable "container_port" {
  type    = number
  default = 8080
}

variable "health_check_path" {
  type    = string
  default = "/health"
}

variable "cpu" {
  type    = number
  default = 512
}

variable "memory" {
  type    = number
  default = 1024
}

variable "min_count" {
  type    = number
  default = 2
}

variable "max_count" {
  type    = number
  default = 10
}

variable "target_cpu_percent" {
  type    = number
  default = 60
}

variable "environment" {
  type    = map(string)
  default = {}
}

variable "secrets" {
  type        = map(string)
  default     = {}
  description = "Env var name -> Secrets Manager / SSM ARN. Injected at start, never in the task definition."
}

variable "task_policy_json" {
  type    = string
  default = null
}

variable "enable_exec" {
  type    = bool
  default = false
}

variable "log_retention_days" {
  type    = number
  default = 30
}

variable "tags" { type = map(string) }
