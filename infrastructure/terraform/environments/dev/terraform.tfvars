# LogLineOS Development Environment Configuration
environment = "dev"
aws_region  = "us-east-1"

# VPC Configuration
vpc_cidr           = "10.0.0.0/16"
availability_zones = ["us-east-1a", "us-east-1b"]

# RDS Configuration  
db_instance_class = "db.t3.medium"
db_multi_az       = false

# ElastiCache Configuration
cache_node_type     = "cache.t3.micro"
cache_cluster_count = 1

# Lambda Configuration
lambda_memory_size = 512
lambda_timeout     = 30

# API Gateway Configuration
api_throttle_burst_limit = 1000
api_throttle_rate_limit  = 500

# Tags
tags = {
  Environment = "dev"
  Project     = "LogLineOS"
  Owner       = "Engineering"
  CostCenter  = "Development"
}
