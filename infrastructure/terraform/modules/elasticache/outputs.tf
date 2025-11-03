output "redis_endpoint" {
  description = "Redis primary endpoint"
  value       = aws_elasticache_replication_group.memory_cache.primary_endpoint_address
  sensitive   = true
}

output "redis_secret_arn" {
  description = "ARN of the Secrets Manager secret containing Redis credentials"
  value       = aws_secretsmanager_secret.redis_credentials.arn
}

output "redis_port" {
  description = "Redis port"
  value       = 6379
}
