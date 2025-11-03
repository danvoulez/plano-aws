#!/bin/bash
# deploy.sh - Complete deployment script for LogLineOS on AWS

set -e

ENVIRONMENT=${1:-dev}
REGION=${2:-us-east-1}
ACTION=${3:-apply}

echo "🚀 Deploying LogLineOS to AWS [$ENVIRONMENT]"

# Check prerequisites
command -v terraform >/dev/null 2>&1 || { echo "❌ Terraform not installed"; exit 1; }
command -v aws >/dev/null 2>&1 || { echo "❌ AWS CLI not installed"; exit 1; }

# Validate AWS credentials
aws sts get-caller-identity > /dev/null || { echo "❌ AWS credentials not configured"; exit 1; }

# Create S3 bucket for Terraform state if not exists
STATE_BUCKET="loglineos-terraform-state-$ENVIRONMENT"
if ! aws s3api head-bucket --bucket "$STATE_BUCKET" 2>/dev/null; then
    echo "📦 Creating state bucket: $STATE_BUCKET"
    if [ "$REGION" = "us-east-1" ]; then
        aws s3api create-bucket \
            --bucket "$STATE_BUCKET" \
            --region "$REGION"
    else
        aws s3api create-bucket \
            --bucket "$STATE_BUCKET" \
            --region "$REGION" \
            --create-bucket-configuration LocationConstraint="$REGION"
    fi
    
    aws s3api put-bucket-versioning \
        --bucket "$STATE_BUCKET" \
        --versioning-configuration Status=Enabled
    
    aws s3api put-bucket-encryption \
        --bucket "$STATE_BUCKET" \
        --server-side-encryption-configuration '{
            "Rules": [{
                "ApplyServerSideEncryptionByDefault": {
                    "SSEAlgorithm": "AES256"
                }
            }]
        }'
fi

# Create DynamoDB table for state locks if not exists
LOCK_TABLE="terraform-locks"
if ! aws dynamodb describe-table --table-name "$LOCK_TABLE" --region "$REGION" 2>/dev/null; then
    echo "🔒 Creating lock table: $LOCK_TABLE"
    aws dynamodb create-table \
        --table-name "$LOCK_TABLE" \
        --attribute-definitions AttributeName=LockID,AttributeType=S \
        --key-schema AttributeName=LockID,KeyType=HASH \
        --provisioned-throughput ReadCapacityUnits=5,WriteCapacityUnits=5 \
        --region "$REGION"
fi

# Package Lambda functions
echo "📦 Packaging Lambda functions..."
cd "$(dirname "$0")/../lambda"
for dir in */; do
    if [ -f "${dir}package.json" ]; then
        echo "  Building Node.js function: $dir"
        (cd "$dir" && npm ci --production 2>/dev/null && cd .. && zip -qr "${dir%/}.zip" "$dir" -x "*/node_modules/.cache/*")
    elif [ -f "${dir}requirements.txt" ]; then
        echo "  Building Python function: $dir"
        rm -rf "${dir}.zip"
        (cd "$dir" && pip install -r requirements.txt -t . --quiet && cd .. && zip -qr "${dir%/}.zip" "$dir")
    fi
done
cd -

# Initialize Terraform
echo "🔧 Initializing Terraform..."
cd "$(dirname "$0")/../terraform/environments/$ENVIRONMENT"
terraform init \
    -backend-config="bucket=$STATE_BUCKET" \
    -backend-config="key=$ENVIRONMENT/terraform.tfstate" \
    -backend-config="region=$REGION" \
    -upgrade

# Plan or Apply
if [ "$ACTION" == "plan" ]; then
    echo "📋 Planning Terraform changes..."
    terraform plan -var-file="terraform.tfvars" -out=tfplan
elif [ "$ACTION" == "apply" ]; then
    echo "⚙️  Applying Terraform changes..."
    terraform apply -var-file="terraform.tfvars" -auto-approve
    
    # Wait for RDS to be available
    echo "⏳ Waiting for RDS to be available..."
    sleep 30
    
    # Run database migrations
    echo "🗄️  Running database migrations..."
    MIGRATION_FUNCTION=$(terraform output -raw migration_lambda_name)
    aws lambda invoke \
        --function-name "$MIGRATION_FUNCTION" \
        --invocation-type RequestResponse \
        --payload '{}' \
        --region "$REGION" \
        /tmp/migration-result.json
    
    echo "✅ Migration result:"
    cat /tmp/migration-result.json
    echo ""
    
elif [ "$ACTION" == "destroy" ]; then
    echo "🗑️  Destroying infrastructure..."
    terraform destroy -var-file="terraform.tfvars" -auto-approve
fi

echo "✅ Deployment complete!"

# Output important endpoints
if [ "$ACTION" == "apply" ]; then
    echo ""
    echo "📌 Important Endpoints:"
    echo "  API Gateway: $(terraform output -raw api_gateway_url)"
    echo "  WebSocket: $(terraform output -raw websocket_url)"
fi
