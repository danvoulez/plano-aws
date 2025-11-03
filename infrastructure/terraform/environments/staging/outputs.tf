# VPC Outputs
output "vpc_id" {
  description = "VPC ID"
  value       = module.vpc.vpc_id
}

output "private_subnet_ids" {
  description = "Private subnet IDs"
  value       = module.vpc.private_subnet_ids
}

# RDS Outputs
output "db_endpoint" {
  description = "RDS endpoint"
  value       = module.rds.db_endpoint
  sensitive   = true
}

output "db_secret_arn" {
  description = "Database secret ARN"
  value       = module.rds.db_secret_arn
}

# ElastiCache Outputs
output "redis_endpoint" {
  description = "Redis endpoint"
  value       = module.elasticache.redis_endpoint
  sensitive   = true
}

# Lambda Outputs
output "stage0_lambda_arn" {
  description = "Stage 0 loader Lambda ARN"
  value       = module.lambda.stage0_lambda_arn
}

output "migration_lambda_name" {
  description = "Migration Lambda function name"
  value       = module.lambda.migration_lambda_name
}

# API Gateway Outputs
output "api_gateway_url" {
  description = "API Gateway URL"
  value       = module.api_gateway.api_gateway_url
}

output "websocket_url" {
  description = "WebSocket API URL"
  value       = module.api_gateway.websocket_url
}
