resource "random_password" "redis_auth" {
  length  = 32
  special = false
}

resource "aws_elasticache_subnet_group" "main" {
  name       = "${var.project}-cache-subnet-${var.environment}"
  subnet_ids = var.subnet_ids
  
  tags = {
    Name = "${var.project}-cache-subnet-group"
  }
}

resource "aws_elasticache_parameter_group" "memory" {
  name   = "${var.project}-memory-params-${var.environment}"
  family = "redis7"
  
  parameter {
    name  = "maxmemory-policy"
    value = "allkeys-lru"
  }
  
  parameter {
    name  = "timeout"
    value = "300"
  }
  
  tags = {
    Name = "${var.project}-memory-params"
  }
}

resource "aws_elasticache_replication_group" "memory_cache" {
  replication_group_id       = "${var.project}-memory-${var.environment}"
  replication_group_description = "LogLineOS Memory System Cache"
  
  engine               = "redis"
  engine_version       = "7.0"
  node_type            = var.cache_node_type
  num_cache_clusters   = var.cache_cluster_count
  
  parameter_group_name = aws_elasticache_parameter_group.memory.name
  subnet_group_name    = aws_elasticache_subnet_group.main.name
  security_group_ids   = var.security_group_ids
  
  at_rest_encryption_enabled = true
  transit_encryption_enabled = true
  auth_token                 = random_password.redis_auth.result
  
  snapshot_retention_limit = 5
  snapshot_window          = "03:00-05:00"
  
  automatic_failover_enabled = var.cache_cluster_count > 1 ? true : false
  multi_az_enabled           = var.cache_cluster_count > 1 ? true : false
  
  tags = {
    Name = "${var.project}-memory-cache"
  }
}

# Store Redis credentials in Secrets Manager
resource "aws_secretsmanager_secret" "redis_credentials" {
  name        = "${var.project}-redis-${var.environment}"
  description = "Redis credentials for LogLineOS"
  
  recovery_window_in_days = var.environment == "dev" ? 0 : 30
}

resource "aws_secretsmanager_secret_version" "redis_credentials" {
  secret_id = aws_secretsmanager_secret.redis_credentials.id
  secret_string = jsonencode({
    endpoint   = aws_elasticache_replication_group.memory_cache.primary_endpoint_address
    auth_token = random_password.redis_auth.result
    port       = 6379
  })
}
