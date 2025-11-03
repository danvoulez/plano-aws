# IAM Role for Lambda
resource "aws_iam_role" "lambda_role" {
  name = "${var.project}-lambda-role-${var.environment}"
  
  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Action = "sts:AssumeRole"
      Effect = "Allow"
      Principal = {
        Service = "lambda.amazonaws.com"
      }
    }]
  })
  
  tags = {
    Name = "${var.project}-lambda-role"
  }
}

# Attach basic Lambda execution policy
resource "aws_iam_role_policy_attachment" "lambda_basic" {
  role       = aws_iam_role.lambda_role.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AWSLambdaBasicExecutionRole"
}

# Attach VPC execution policy
resource "aws_iam_role_policy_attachment" "lambda_vpc" {
  role       = aws_iam_role.lambda_role.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AWSLambdaVPCAccessExecutionRole"
}

# Policy for accessing Secrets Manager
resource "aws_iam_policy" "secrets_access" {
  name        = "${var.project}-lambda-secrets-${var.environment}"
  description = "Allow Lambda to access Secrets Manager"
  
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect = "Allow"
      Action = [
        "secretsmanager:GetSecretValue"
      ]
      Resource = [
        var.db_secret_arn,
        var.redis_secret_arn
      ]
    }]
  })
}

resource "aws_iam_role_policy_attachment" "secrets_access" {
  role       = aws_iam_role.lambda_role.name
  policy_arn = aws_iam_policy.secrets_access.arn
}

# Stage 0 Loader Lambda
resource "aws_lambda_function" "stage0_loader" {
  filename      = "${path.module}/../../lambda/stage0_loader.zip"
  function_name = "${var.project}-stage0-loader-${var.environment}"
  role          = aws_iam_role.lambda_role.arn
  handler       = "index.handler"
  runtime       = "nodejs18.x"
  
  memory_size = var.lambda_memory_size
  timeout     = var.lambda_timeout
  
  vpc_config {
    subnet_ids         = var.subnet_ids
    security_group_ids = var.security_group_ids
  }
  
  environment {
    variables = {
      DB_SECRET_ARN    = var.db_secret_arn
      REDIS_SECRET_ARN = var.redis_secret_arn
      ENVIRONMENT      = var.environment
    }
  }
  
  tags = {
    Name = "${var.project}-stage0-loader"
  }
}

# Database Migration Lambda
resource "aws_lambda_function" "db_migration" {
  filename      = "${path.module}/../../lambda/db_migration.zip"
  function_name = "${var.project}-db-migration-${var.environment}"
  role          = aws_iam_role.lambda_role.arn
  handler       = "handler.handler"
  runtime       = "python3.11"
  
  memory_size = var.lambda_memory_size
  timeout     = 300  # Migrations may take longer
  
  vpc_config {
    subnet_ids         = var.subnet_ids
    security_group_ids = var.security_group_ids
  }
  
  environment {
    variables = {
      DB_SECRET_ARN = var.db_secret_arn
      ENVIRONMENT   = var.environment
    }
  }
  
  tags = {
    Name = "${var.project}-db-migration"
  }
}

# API Handler Lambda
resource "aws_lambda_function" "api_handler" {
  filename      = "${path.module}/../../lambda/api_handlers.zip"
  function_name = "${var.project}-api-handler-${var.environment}"
  role          = aws_iam_role.lambda_role.arn
  handler       = "index.handler"
  runtime       = "nodejs18.x"
  
  memory_size = var.lambda_memory_size
  timeout     = var.lambda_timeout
  
  vpc_config {
    subnet_ids         = var.subnet_ids
    security_group_ids = var.security_group_ids
  }
  
  environment {
    variables = {
      DB_SECRET_ARN    = var.db_secret_arn
      REDIS_SECRET_ARN = var.redis_secret_arn
      ENVIRONMENT      = var.environment
    }
  }
  
  tags = {
    Name = "${var.project}-api-handler"
  }
}

# Timeline Handler Lambda
resource "aws_lambda_function" "timeline_handler" {
  filename      = "${path.module}/../../lambda/timeline_handler.zip"
  function_name = "${var.project}-timeline-handler-${var.environment}"
  role          = aws_iam_role.lambda_role.arn
  handler       = "handler.handler"
  runtime       = "python3.11"
  
  memory_size = var.lambda_memory_size
  timeout     = var.lambda_timeout
  
  vpc_config {
    subnet_ids         = var.subnet_ids
    security_group_ids = var.security_group_ids
  }
  
  environment {
    variables = {
      DB_SECRET_ARN    = var.db_secret_arn
      REDIS_SECRET_ARN = var.redis_secret_arn
      ENVIRONMENT      = var.environment
    }
  }
  
  tags = {
    Name = "${var.project}-timeline-handler"
  }
}
