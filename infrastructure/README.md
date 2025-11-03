# LogLineOS Infrastructure

This directory contains the Infrastructure as Code (IaC) for deploying LogLineOS to AWS.

## Directory Structure

```
infrastructure/
├── terraform/           # Terraform configuration
│   ├── environments/    # Environment-specific configs
│   │   ├── dev/        # Development environment
│   │   ├── staging/    # Staging environment
│   │   └── production/ # Production environment
│   └── modules/        # Reusable Terraform modules
│       ├── vpc/        # VPC and networking
│       ├── rds/        # PostgreSQL database
│       ├── elasticache/# Redis cache
│       ├── lambda/     # Lambda functions
│       ├── api_gateway/# API Gateway
│       ├── security/   # Security groups and WAF
│       └── monitoring/ # CloudWatch dashboards
├── lambda/             # Lambda function code
│   ├── stage0_loader/  # Boot loader
│   ├── db_migration/   # Database migrations
│   ├── api_handlers/   # API endpoints
│   └── timeline_handler/# WebSocket handler
└── scripts/            # Deployment scripts
    └── deploy.sh       # Main deployment script
```

## Prerequisites

- AWS CLI configured with appropriate credentials
- Terraform >= 1.5
- Node.js 18+ (for Lambda functions)
- Python 3.11+ (for Python Lambda functions)

## Quick Start

### Deploy to Development

```bash
cd infrastructure/scripts
./deploy.sh dev us-east-1 apply
```

### Deploy to Production

```bash
cd infrastructure/scripts
./deploy.sh production us-east-1 apply
```

### Plan Changes

```bash
cd infrastructure/scripts
./deploy.sh dev us-east-1 plan
```

### Destroy Infrastructure

```bash
cd infrastructure/scripts
./deploy.sh dev us-east-1 destroy
```

## Environment Variables

Each environment has its own `terraform.tfvars` file in `terraform/environments/{env}/`.

### Development (dev)
- Smaller instance sizes
- No multi-AZ
- Shorter backup retention
- Lower costs

### Staging
- Medium instance sizes
- Multi-AZ enabled
- Longer backup retention
- Production-like configuration

### Production
- Large instance sizes
- Multi-AZ enabled
- 30-day backup retention
- High availability

## Manual Deployment Steps

If you prefer to deploy manually without the script:

```bash
# 1. Package Lambda functions
cd infrastructure/lambda/stage0_loader
npm ci --production
cd ..
zip -r stage0_loader.zip stage0_loader/

# 2. Initialize Terraform
cd ../terraform/environments/dev
terraform init

# 3. Plan changes
terraform plan -var-file="terraform.tfvars"

# 4. Apply changes
terraform apply -var-file="terraform.tfvars"

# 5. Run migrations
aws lambda invoke \
  --function-name loglineos-db-migration-dev \
  --payload '{}' \
  /tmp/migration-result.json
```

## Architecture

The infrastructure creates:

1. **VPC** with public and private subnets across multiple AZs
2. **RDS PostgreSQL** with the Universal Registry schema
3. **ElastiCache Redis** for memory system caching
4. **Lambda Functions** for serverless compute
5. **API Gateway** for REST API and WebSocket endpoints
6. **CloudWatch** for monitoring and logging
7. **WAF** for API protection
8. **Secrets Manager** for secure credential storage

## Database Schema

The database migration creates:
- `ledger.universal_registry` - Main ledger table with 70 semantic columns
- `ledger.memory_embeddings` - Vector embeddings for memory system
- Row-Level Security (RLS) policies for multi-tenancy

## Cost Estimates

### Development (~$50-100/month)
- RDS t3.medium
- ElastiCache t3.micro
- Lambda (pay per use)
- Data transfer

### Production (~$500-1000/month)
- RDS r6g.xlarge with multi-AZ
- ElastiCache r6g.large cluster
- Lambda at scale
- CloudFront CDN
- Data transfer

## Security

- All data encrypted at rest and in transit
- VPC isolation for database and cache
- WAF protection on API Gateway
- Secrets stored in AWS Secrets Manager
- Row-Level Security (RLS) for multi-tenancy

## Monitoring

Access the CloudWatch dashboard:
```bash
aws cloudwatch get-dashboard \
  --dashboard-name loglineos-dashboard-dev
```

## Troubleshooting

### Migration fails
Check the Lambda logs:
```bash
aws logs tail /aws/lambda/loglineos-db-migration-dev --follow
```

### Cannot connect to RDS
Ensure Lambda functions are in the same VPC and security groups allow traffic.

### Terraform state locked
Clear the lock manually in DynamoDB:
```bash
aws dynamodb delete-item \
  --table-name terraform-locks \
  --key '{"LockID": {"S": "loglineos-terraform-state-dev/dev/terraform.tfstate"}}'
```

## Support

For issues and questions, see the main [README.md](../../README.md) or [plano-aws.md](../../plano-aws.md).
