resource "random_password" "db_password" {
  length  = 32
  special = true
}

resource "aws_db_subnet_group" "main" {
  name       = "${var.project}-db-subnet-${var.environment}"
  subnet_ids = var.db_subnet_group_ids
  
  tags = {
    Name = "${var.project}-db-subnet-group"
  }
}

resource "aws_db_parameter_group" "ledger" {
  name   = "${var.project}-ledger-params-${var.environment}"
  family = "postgres15"
  
  # Optimizations for append-only ledger
  parameter {
    name  = "shared_buffers"
    value = "{DBInstanceClassMemory/4}"
  }
  
  parameter {
    name  = "effective_cache_size"
    value = "{DBInstanceClassMemory*3/4}"
  }
  
  parameter {
    name  = "max_connections"
    value = "200"
  }
  
  parameter {
    name  = "work_mem"
    value = "16384"
  }
  
  tags = {
    Name = "${var.project}-ledger-params"
  }
}

resource "aws_db_instance" "ledger" {
  identifier = "${var.project}-ledger-${var.environment}"
  
  engine         = "postgres"
  engine_version = "15.4"
  instance_class = var.db_instance_class
  
  allocated_storage     = 100
  max_allocated_storage = 1000
  storage_type          = "gp3"
  storage_encrypted     = true
  
  db_name  = "loglineos"
  username = "ledger_admin"
  password = random_password.db_password.result
  
  vpc_security_group_ids = var.security_group_ids
  db_subnet_group_name   = aws_db_subnet_group.main.name
  
  backup_retention_period = 30
  backup_window           = "03:00-04:00"
  maintenance_window      = "sun:04:00-sun:05:00"
  
  enabled_cloudwatch_logs_exports = ["postgresql"]
  
  parameter_group_name = aws_db_parameter_group.ledger.name
  
  skip_final_snapshot = var.environment == "dev" ? true : false
  final_snapshot_identifier = var.environment != "dev" ? "${var.project}-ledger-final-${var.environment}" : null
  
  tags = {
    Name = "${var.project}-ledger"
  }
}

# Store database credentials in Secrets Manager
resource "aws_secretsmanager_secret" "db_credentials" {
  name        = "${var.project}-db-${var.environment}"
  description = "Database credentials for LogLineOS"
  
  recovery_window_in_days = var.environment == "dev" ? 0 : 30
}

resource "aws_secretsmanager_secret_version" "db_credentials" {
  secret_id = aws_secretsmanager_secret.db_credentials.id
  secret_string = jsonencode({
    host     = aws_db_instance.ledger.endpoint
    database = aws_db_instance.ledger.db_name
    username = aws_db_instance.ledger.username
    password = random_password.db_password.result
    port     = aws_db_instance.ledger.port
  })
}
