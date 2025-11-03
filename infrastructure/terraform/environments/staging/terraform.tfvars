# LogLineOS Staging Environment Configuration
environment = "staging"
aws_region  = "us-east-1"

# VPC Configuration
vpc_cidr           = "10.1.0.0/16"
availability_zones = ["us-east-1a", "us-east-1b", "us-east-1c"]

# RDS Configuration  
db_instance_class = "db.r6g.large"
db_multi_az       = true

# ElastiCache Configuration
cache_node_type     = "cache.r6g.large"
cache_cluster_count = 2

# Lambda Configuration
lambda_memory_size = 1024
lambda_timeout     = 30

# API Gateway Configuration
api_throttle_burst_limit = 3000
api_throttle_rate_limit  = 1500

# Tags
tags = {
  Environment = "staging"
  Project     = "LogLineOS"
  Owner       = "Engineering"
  CostCenter  = "Staging"
}
