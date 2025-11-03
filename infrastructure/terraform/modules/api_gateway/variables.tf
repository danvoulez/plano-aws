variable "project" {
  description = "Project name"
  type        = string
}

variable "environment" {
  description = "Environment name"
  type        = string
}

variable "stage0_lambda_arn" {
  description = "Stage 0 loader Lambda ARN"
  type        = string
}

variable "api_handler_lambda_arn" {
  description = "API handler Lambda ARN"
  type        = string
}

variable "timeline_handler_lambda_arn" {
  description = "Timeline handler Lambda ARN"
  type        = string
}

variable "api_throttle_burst_limit" {
  description = "API Gateway throttle burst limit"
  type        = number
}

variable "api_throttle_rate_limit" {
  description = "API Gateway throttle rate limit"
  type        = number
}
