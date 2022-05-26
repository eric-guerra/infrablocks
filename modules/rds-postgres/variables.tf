variable "name" { type = string }
variable "vpc_id" { type = string }
variable "private_subnet_ids" { type = list(string) }

variable "allowed_security_group_ids" {
  type    = list(string)
  default = []
}

variable "major_version" {
  type    = string
  default = "12"
}

variable "engine_version" {
  type    = string
  default = "12.5"
}

variable "instance_class" {
  type    = string
  default = "db.t3.medium"
}

variable "allocated_storage_gb" {
  type    = number
  default = 50
}

variable "database_name" { type = string }

variable "master_username" {
  type    = string
  default = "app_admin"
}

variable "multi_az" {
  type    = bool
  default = true
}

variable "backup_retention_days" {
  type    = number
  default = 14
}

variable "deletion_protection" {
  type    = bool
  default = true
}

variable "slow_query_ms" {
  type    = number
  default = 500
}

variable "kms_key_arn" {
  type    = string
  default = null
}

variable "tags" { type = map(string) }
