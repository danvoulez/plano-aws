variable "project" {
  description = "Project name"
  type        = string
}

variable "environment" {
  description = "Environment name"
  type        = string
}

variable "vpc_id" {
  description = "VPC ID"
  type        = string
}

variable "subnet_ids" {
  description = "List of subnet IDs for Lambda"
  type        = list(string)
}

variable "security_group_ids" {
  description = "List of security group IDs for Lambda"
  type        = list(string)
}

variable "db_secret_arn" {
  description = "ARN of database secret"
  type        = string
}

variable "redis_secret_arn" {
  description = "ARN of Redis secret"
  type        = string
}

variable "lambda_memory_size" {
  description = "Lambda memory size in MB"
  type        = number
}

variable "lambda_timeout" {
  description = "Lambda timeout in seconds"
  type        = number
}
