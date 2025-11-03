# LogLineOS AWS Quick Start Guide

This guide will help you deploy LogLineOS to AWS in under 30 minutes.

## Prerequisites

Before you begin, ensure you have:

1. **AWS Account** with administrative access
2. **AWS CLI** installed and configured
   ```bash
   aws configure
   ```
3. **Terraform** (>= 1.5) installed
   ```bash
   # macOS
   brew install terraform
   
   # Linux
   wget https://releases.hashicorp.com/terraform/1.6.0/terraform_1.6.0_linux_amd64.zip
   unzip terraform_1.6.0_linux_amd64.zip
   sudo mv terraform /usr/local/bin/
   ```
4. **Node.js** (>= 18) and npm
5. **Python** (>= 3.11) and pip

## Step 1: Clone the Repository

```bash
git clone https://github.com/danvoulez/plano-aws.git
cd plano-aws
```

## Step 2: Deploy Infrastructure

### Option A: Automated Deployment (Recommended)

```bash
cd infrastructure/scripts
./deploy.sh dev us-east-1 apply
```

This will:
- Create S3 bucket for Terraform state
- Create DynamoDB table for state locking
- Package Lambda functions
- Deploy all infrastructure
- Run database migrations

### Option B: Using Makefile

```bash
cd infrastructure
make apply ENVIRONMENT=dev REGION=us-east-1
```

### Option C: Manual Deployment

```bash
# 1. Package Lambda functions
cd infrastructure/lambda

# Package Node.js functions
cd stage0_loader && npm ci --production && cd ..
zip -r stage0_loader.zip stage0_loader/

cd api_handlers && npm ci --production && cd ..
zip -r api_handlers.zip api_handlers/

cd kernel_executor && npm ci --production && cd ..
zip -r kernel_executor.zip kernel_executor/

# Package Python functions
cd db_migration && pip install -r requirements.txt -t . && cd ..
zip -r db_migration.zip db_migration/

cd timeline_handler && pip install -r requirements.txt -t . && cd ..
zip -r timeline_handler.zip timeline_handler/

cd memory_upsert && pip install -r requirements.txt -t . && cd ..
zip -r memory_upsert.zip memory_upsert/

# 2. Deploy with Terraform
cd ../terraform/environments/dev
terraform init
terraform plan -var-file="terraform.tfvars"
terraform apply -var-file="terraform.tfvars" -auto-approve

# 3. Run database migrations
MIGRATION_LAMBDA=$(terraform output -raw migration_lambda_name)
aws lambda invoke \
  --function-name "$MIGRATION_LAMBDA" \
  --payload '{}' \
  /tmp/migration-result.json

cat /tmp/migration-result.json
```

## Step 3: Verify Deployment

### Check Terraform Outputs

```bash
cd infrastructure/terraform/environments/dev
terraform output
```

You should see:
- `api_gateway_url` - Your REST API endpoint
- `websocket_url` - Your WebSocket endpoint
- `db_endpoint` - RDS database endpoint

### Test the API

```bash
# Get the API URL
API_URL=$(cd infrastructure/terraform/environments/dev && terraform output -raw api_gateway_url)

# Health check (if implemented)
curl $API_URL/health

# Create a test span
curl -X POST $API_URL/spans \
  -H "Content-Type: application/json" \
  -H "x-user-id: test-user" \
  -d '{
    "entity_type": "test",
    "who": "quickstart",
    "this": "test.span",
    "name": "My First Span",
    "description": "Testing LogLineOS deployment"
  }'

# List spans
curl "$API_URL/spans?limit=10" \
  -H "x-user-id: test-user"
```

### Test Boot Function

```bash
# First, you need to create a function span in the database
# Then you can boot it:
curl -X POST $API_URL/boot \
  -H "Content-Type: application/json" \
  -d '{
    "boot_function_id": "YOUR_FUNCTION_UUID",
    "user_id": "test-user",
    "tenant_id": "test-tenant"
  }'
```

## Step 4: Access AWS Console Resources

### CloudWatch Dashboard

```bash
# Get dashboard URL
echo "https://console.aws.amazon.com/cloudwatch/home?region=us-east-1#dashboards:name=loglineos-dashboard-dev"
```

### RDS Database

To connect to the database:

```bash
# Get database credentials from Secrets Manager
aws secretsmanager get-secret-value \
  --secret-id loglineos-db-dev \
  --query SecretString \
  --output text | jq -r .

# Connect with psql (if you have it installed)
DB_HOST=$(aws secretsmanager get-secret-value --secret-id loglineos-db-dev --query SecretString --output text | jq -r .host)
DB_USER=$(aws secretsmanager get-secret-value --secret-id loglineos-db-dev --query SecretString --output text | jq -r .username)
DB_PASS=$(aws secretsmanager get-secret-value --secret-id loglineos-db-dev --query SecretString --output text | jq -r .password)

PGPASSWORD=$DB_PASS psql -h $DB_HOST -U $DB_USER -d loglineos
```

### Lambda Functions

View Lambda functions in the console:
```bash
aws lambda list-functions --query "Functions[?starts_with(FunctionName, 'loglineos')].FunctionName"
```

## Step 5: Monitor Your Deployment

### View Lambda Logs

```bash
# Stage 0 Loader logs
aws logs tail /aws/lambda/loglineos-stage0-loader-dev --follow

# API Handler logs
aws logs tail /aws/lambda/loglineos-api-handler-dev --follow

# Migration logs
aws logs tail /aws/lambda/loglineos-db-migration-dev --follow
```

### Check Metrics

```bash
# API Gateway requests
aws cloudwatch get-metric-statistics \
  --namespace AWS/ApiGateway \
  --metric-name Count \
  --start-time $(date -u -d '1 hour ago' +%Y-%m-%dT%H:%M:%S) \
  --end-time $(date -u +%Y-%m-%dT%H:%M:%S) \
  --period 300 \
  --statistics Sum
```

## Common Operations

### Update Lambda Function Code

```bash
cd infrastructure/lambda/stage0_loader
# Make your changes to index.js
npm ci --production
cd ..
zip -r stage0_loader.zip stage0_loader/

aws lambda update-function-code \
  --function-name loglineos-stage0-loader-dev \
  --zip-file fileb://stage0_loader.zip
```

### Re-run Database Migration

```bash
aws lambda invoke \
  --function-name loglineos-db-migration-dev \
  --payload '{}' \
  /tmp/migration-result.json
```

### Scale Resources

Edit `infrastructure/terraform/environments/dev/terraform.tfvars`:

```hcl
# Increase Lambda memory
lambda_memory_size = 1024

# Use larger database
db_instance_class = "db.r6g.large"
```

Then apply:

```bash
cd infrastructure/terraform/environments/dev
terraform apply -var-file="terraform.tfvars"
```

## Clean Up

To destroy all resources:

```bash
cd infrastructure/scripts
./deploy.sh dev us-east-1 destroy
```

Or with Makefile:

```bash
cd infrastructure
make destroy ENVIRONMENT=dev
```

## Estimated Costs

### Development Environment
- **RDS** (db.t3.medium): ~$30/month
- **ElastiCache** (t3.micro): ~$15/month
- **Lambda**: Pay per use (~$5-20/month for testing)
- **Data Transfer**: ~$5/month
- **NAT Gateway**: ~$30/month
- **Total**: ~$85-100/month

### Cost Optimization Tips

1. **Stop/Start RDS** when not in use:
   ```bash
   aws rds stop-db-instance --db-instance-identifier loglineos-ledger-dev
   ```

2. **Use smaller instances** for development

3. **Delete when not needed**:
   ```bash
   ./deploy.sh dev us-east-1 destroy
   ```

## Troubleshooting

### Terraform State Locked

```bash
# Clear the lock
aws dynamodb delete-item \
  --table-name terraform-locks \
  --key '{"LockID": {"S": "loglineos-terraform-state-dev/dev/terraform.tfstate"}}'
```

### Lambda Can't Connect to RDS

1. Check security groups allow traffic
2. Ensure Lambda is in the same VPC
3. Check database is running:
   ```bash
   aws rds describe-db-instances \
     --db-instance-identifier loglineos-ledger-dev \
     --query 'DBInstances[0].DBInstanceStatus'
   ```

### Migration Failed

Check logs and retry:
```bash
aws logs tail /aws/lambda/loglineos-db-migration-dev
aws lambda invoke \
  --function-name loglineos-db-migration-dev \
  --payload '{}' \
  /tmp/migration-result.json
```

## Next Steps

1. Read the [full README](README.md) for architecture details
2. Review [plano-aws.md](plano-aws.md) for the complete deployment guide
3. Explore the [infrastructure README](infrastructure/README.md)
4. Deploy to staging/production environments

## Support

For issues and questions:
- Check the main [README.md](README.md)
- Review [plano-aws.md](plano-aws.md) deployment guide
- Open an issue on GitHub

## Security Note

This quick start guide uses simplified configurations for demonstration. For production deployments:
- Enable WAF
- Configure proper authentication/authorization
- Enable audit logging
- Set up monitoring and alerts
- Use least-privilege IAM policies
- Enable encryption at rest and in transit (already configured)
