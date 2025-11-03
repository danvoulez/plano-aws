output "stage0_lambda_arn" {
  description = "Stage 0 loader Lambda ARN"
  value       = aws_lambda_function.stage0_loader.arn
}

output "stage0_lambda_name" {
  description = "Stage 0 loader Lambda name"
  value       = aws_lambda_function.stage0_loader.function_name
}

output "migration_lambda_arn" {
  description = "Migration Lambda ARN"
  value       = aws_lambda_function.db_migration.arn
}

output "migration_lambda_name" {
  description = "Migration Lambda name"
  value       = aws_lambda_function.db_migration.function_name
}

output "api_handler_lambda_arn" {
  description = "API handler Lambda ARN"
  value       = aws_lambda_function.api_handler.arn
}

output "timeline_handler_lambda_arn" {
  description = "Timeline handler Lambda ARN"
  value       = aws_lambda_function.timeline_handler.arn
}

output "lambda_role_arn" {
  description = "Lambda IAM role ARN"
  value       = aws_iam_role.lambda_role.arn
}
