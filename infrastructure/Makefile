.PHONY: help init plan apply destroy clean

ENVIRONMENT ?= dev
REGION ?= us-east-1

help:
	@echo "LogLineOS Infrastructure Makefile"
	@echo ""
	@echo "Usage:"
	@echo "  make init ENVIRONMENT=dev          - Initialize Terraform"
	@echo "  make plan ENVIRONMENT=dev          - Plan Terraform changes"
	@echo "  make apply ENVIRONMENT=dev         - Apply Terraform changes"
	@echo "  make destroy ENVIRONMENT=dev       - Destroy infrastructure"
	@echo "  make clean                         - Clean build artifacts"
	@echo ""
	@echo "Available environments: dev, staging, production"

init:
	@echo "Initializing Terraform for $(ENVIRONMENT)..."
	cd terraform/environments/$(ENVIRONMENT) && terraform init

plan:
	@echo "Planning Terraform changes for $(ENVIRONMENT)..."
	cd terraform/environments/$(ENVIRONMENT) && terraform plan -var-file="terraform.tfvars"

apply:
	@echo "Applying Terraform changes for $(ENVIRONMENT)..."
	./scripts/deploy.sh $(ENVIRONMENT) $(REGION) apply

destroy:
	@echo "Destroying infrastructure for $(ENVIRONMENT)..."
	./scripts/deploy.sh $(ENVIRONMENT) $(REGION) destroy

clean:
	@echo "Cleaning build artifacts..."
	find lambda -name "*.zip" -delete
	find lambda -name "node_modules" -type d -exec rm -rf {} + 2>/dev/null || true
	find lambda -name "__pycache__" -type d -exec rm -rf {} + 2>/dev/null || true
	find terraform -name ".terraform" -type d -exec rm -rf {} + 2>/dev/null || true
	find terraform -name "terraform.tfstate*" -delete
	find terraform -name ".terraform.lock.hcl" -delete
