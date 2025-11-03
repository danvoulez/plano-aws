output "db_instance_id" {
  description = "RDS instance ID"
  value       = aws_db_instance.ledger.id
}

output "db_endpoint" {
  description = "RDS endpoint"
  value       = aws_db_instance.ledger.endpoint
  sensitive   = true
}

output "db_name" {
  description = "Database name"
  value       = aws_db_instance.ledger.db_name
}

output "db_secret_arn" {
  description = "ARN of the Secrets Manager secret containing DB credentials"
  value       = aws_secretsmanager_secret.db_credentials.arn
}
