# LogLineOS Development Environment
terraform {
  required_version = ">= 1.5"
  
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
    random = {
      source  = "hashicorp/random"
      version = "~> 3.5"
    }
  }
  
  backend "s3" {
    bucket         = "loglineos-terraform-state-dev"
    key            = "dev/terraform.tfstate"
    region         = "us-east-1"
    encrypt        = true
    dynamodb_table = "terraform-locks"
  }
}

provider "aws" {
  region = var.aws_region
  
  default_tags {
    tags = {
      Environment = var.environment
      Project     = "LogLineOS"
      ManagedBy   = "Terraform"
    }
  }
}

# VPC Module
module "vpc" {
  source = "../../modules/vpc"
  
  project            = var.project
  environment        = var.environment
  vpc_cidr           = var.vpc_cidr
  availability_zones = var.availability_zones
}

# Security Module
module "security" {
  source = "../../modules/security"
  
  project     = var.project
  environment = var.environment
  vpc_id      = module.vpc.vpc_id
}

# RDS Module
module "rds" {
  source = "../../modules/rds"
  
  project             = var.project
  environment         = var.environment
  db_instance_class   = var.db_instance_class
  vpc_id              = module.vpc.vpc_id
  db_subnet_group_ids = module.vpc.private_subnet_ids
  security_group_ids  = [module.security.rds_security_group_id]
}

# ElastiCache Module
module "elasticache" {
  source = "../../modules/elasticache"
  
  project             = var.project
  environment         = var.environment
  cache_node_type     = var.cache_node_type
  cache_cluster_count = var.cache_cluster_count
  vpc_id              = module.vpc.vpc_id
  subnet_ids          = module.vpc.private_subnet_ids
  security_group_ids  = [module.security.redis_security_group_id]
}

# Lambda Module
module "lambda" {
  source = "../../modules/lambda"
  
  project               = var.project
  environment           = var.environment
  vpc_id                = module.vpc.vpc_id
  subnet_ids            = module.vpc.private_subnet_ids
  security_group_ids    = [module.security.lambda_security_group_id]
  db_secret_arn         = module.rds.db_secret_arn
  redis_secret_arn      = module.elasticache.redis_secret_arn
  lambda_memory_size    = var.lambda_memory_size
  lambda_timeout        = var.lambda_timeout
}

# API Gateway Module
module "api_gateway" {
  source = "../../modules/api_gateway"
  
  project                  = var.project
  environment              = var.environment
  stage0_lambda_arn        = module.lambda.stage0_lambda_arn
  api_handler_lambda_arn   = module.lambda.api_handler_lambda_arn
  timeline_handler_lambda_arn = module.lambda.timeline_handler_lambda_arn
  api_throttle_burst_limit = var.api_throttle_burst_limit
  api_throttle_rate_limit  = var.api_throttle_rate_limit
}

# Monitoring Module
module "monitoring" {
  source = "../../modules/monitoring"
  
  project     = var.project
  environment = var.environment
  aws_region  = var.aws_region
}
