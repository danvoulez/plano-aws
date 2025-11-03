# LogLineOS Production Environment Configuration
environment = "production"
aws_region  = "us-east-1"

# VPC Configuration
vpc_cidr           = "10.2.0.0/16"
availability_zones = ["us-east-1a", "us-east-1b", "us-east-1c"]

# RDS Configuration  
db_instance_class = "db.r6g.xlarge"
db_multi_az       = true

# ElastiCache Configuration
cache_node_type     = "cache.r6g.large"
cache_cluster_count = 2

# Lambda Configuration
lambda_memory_size = 1024
lambda_timeout     = 30

# API Gateway Configuration
api_throttle_burst_limit = 5000
api_throttle_rate_limit  = 2000

# Tags
tags = {
  Environment = "production"
  Project     = "LogLineOS"
  Owner       = "Engineering"
  CostCenter  = "Platform"
}
