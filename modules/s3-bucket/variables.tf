variable "name" {
  type = string
  validation {
    condition     = can(regex("^[a-z0-9][a-z0-9.-]{2,62}$", var.name))
    error_message = "Bucket names are 3-63 lowercase letters, digits, dots and hyphens."
  }
}

variable "kms_key_arn" {
  type    = string
  default = null
}

variable "force_destroy" {
  type    = bool
  default = false
}

variable "noncurrent_retention_days" {
  type    = number
  default = 30
}

variable "expire_after_days" {
  type    = number
  default = null
}

variable "allow_log_delivery" {
  type    = bool
  default = false
}

variable "tags" {
  type = map(string)
}
