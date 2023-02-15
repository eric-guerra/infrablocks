variable "name" {
  type        = string
  description = "Name prefix for every resource."
}

variable "cidr" {
  type        = string
  description = "VPC CIDR; /16 recommended (subnets are carved as /20s)."
  validation {
    condition     = can(cidrhost(var.cidr, 0)) && tonumber(split("/", var.cidr)[1]) <= 18
    error_message = "The cidr must be a valid block of /18 or larger."
  }
}

variable "az_count" {
  type    = number
  default = 3
  validation {
    condition     = var.az_count >= 2 && var.az_count <= 4
    error_message = "Use 2 to 4 availability zones."
  }
}

variable "single_nat_gateway" {
  type    = bool
  default = false
}

variable "flow_log_bucket_arn" {
  type        = string
  description = "S3 bucket ARN receiving rejected-traffic flow logs."
}

variable "tags" {
  type        = map(string)
  description = "Required tags: Environment, Owner, CostCenter."
}
