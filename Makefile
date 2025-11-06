.PHONY: help setup local-up local-down local-db-init local-db-migrate local-db-seed local-clean test-local install clean

# Default target
.DEFAULT_GOAL := help

# Colors for output
BLUE := \033[0;34m
GREEN := \033[0;32m
YELLOW := \033[1;33m
NC := \033[0m # No Color

help: ## Show this help message
	@echo "$(BLUE)LogLineOS - Local Development Makefile$(NC)"
	@echo ""
	@echo "$(GREEN)Setup Commands:$(NC)"
	@grep -E '^[a-zA-Z_-]+:.*?## .*$$' $(MAKEFILE_LIST) | awk 'BEGIN {FS = ":.*?## "}; {printf "  $(YELLOW)%-20s$(NC) %s\n", $$1, $$2}'
	@echo ""
	@echo "For AWS deployment, see infrastructure/Makefile"

setup: ## Run initial macOS setup (installs dependencies)
	@echo "$(GREEN)Running macOS setup...$(NC)"
	@chmod +x setup-macos.sh
	@./setup-macos.sh

install: ## Install all project dependencies (Node.js and Python)
	@echo "$(GREEN)Installing Lambda function dependencies...$(NC)"
	@for dir in infrastructure/lambda/*/; do \
		if [ -f "$$dir/package.json" ]; then \
			echo "  Installing Node.js dependencies for $$(basename $$dir)..."; \
			(cd "$$dir" && npm install); \
		elif [ -f "$$dir/requirements.txt" ]; then \
			echo "  Installing Python dependencies for $$(basename $$dir)..."; \
			(cd "$$dir" && pip3 install --user -r requirements.txt); \
		fi \
	done
	@echo "$(GREEN)✓ All dependencies installed$(NC)"

local-up: ## Start local infrastructure (PostgreSQL + Redis)
	@echo "$(GREEN)Starting local infrastructure...$(NC)"
	@docker-compose up -d postgres redis
	@echo "$(GREEN)Waiting for services to be healthy...$(NC)"
	@sleep 5
	@docker-compose ps
	@echo ""
	@echo "$(GREEN)✓ Local infrastructure is running$(NC)"
	@echo ""
	@echo "  PostgreSQL: localhost:5432"
	@echo "  Redis: localhost:6379"
	@echo ""
	@echo "Database connection:"
	@echo "  Host: localhost"
	@echo "  Port: 5432"
	@echo "  Database: loglineos"
	@echo "  User: loglineos"
	@echo "  Password: loglineos_dev_password"

local-up-all: ## Start all local services including pgAdmin
	@echo "$(GREEN)Starting all local services...$(NC)"
	@docker-compose --profile tools up -d
	@echo "$(GREEN)Waiting for services to be healthy...$(NC)"
	@sleep 5
	@docker-compose ps
	@echo ""
	@echo "$(GREEN)✓ All services are running$(NC)"
	@echo ""
	@echo "  PostgreSQL: localhost:5432"
	@echo "  Redis: localhost:6379"
	@echo "  pgAdmin: http://localhost:5050"
	@echo "    Email: admin@loglineos.local"
	@echo "    Password: admin"

local-up-localstack: ## Start local services with LocalStack for AWS emulation
	@echo "$(GREEN)Starting local services with LocalStack...$(NC)"
	@docker-compose --profile localstack up -d
	@echo "$(GREEN)Waiting for services to be healthy...$(NC)"
	@sleep 10
	@docker-compose ps
	@echo ""
	@echo "$(GREEN)✓ All services including LocalStack are running$(NC)"
	@echo ""
	@echo "  LocalStack: http://localhost:4566"

local-down: ## Stop local infrastructure
	@echo "$(YELLOW)Stopping local infrastructure...$(NC)"
	@docker-compose down
	@echo "$(GREEN)✓ Local infrastructure stopped$(NC)"

local-down-clean: ## Stop and remove all local data (volumes)
	@echo "$(YELLOW)Stopping and cleaning local infrastructure...$(NC)"
	@docker-compose down -v
	@echo "$(GREEN)✓ Local infrastructure stopped and data cleaned$(NC)"

local-db: local-up ## Alias for local-up (backwards compatibility)

local-db-init: ## Initialize the local database schema
	@echo "$(GREEN)Initializing database schema...$(NC)"
	@docker-compose exec -T postgres psql -U loglineos -d loglineos -c "CREATE EXTENSION IF NOT EXISTS vector;"
	@docker-compose exec -T postgres psql -U loglineos -d loglineos -c "CREATE SCHEMA IF NOT EXISTS ledger;"
	@echo "$(GREEN)Running migrations...$(NC)"
	@if [ -f infrastructure/lambda/db_migration/migrations/001_initial_schema.sql ]; then \
		docker-compose exec -T postgres psql -U loglineos -d loglineos < infrastructure/lambda/db_migration/migrations/001_initial_schema.sql; \
	else \
		echo "$(YELLOW)No migration files found. Database initialized with extensions only.$(NC)"; \
	fi
	@echo "$(GREEN)✓ Database initialized$(NC)"

local-db-migrate: ## Run database migrations
	@echo "$(GREEN)Running database migrations...$(NC)"
	@if [ -d infrastructure/lambda/db_migration/migrations ]; then \
		for sql in infrastructure/lambda/db_migration/migrations/*.sql; do \
			if [ -f "$$sql" ]; then \
				echo "  Running $$(basename $$sql)..."; \
				docker-compose exec -T postgres psql -U loglineos -d loglineos < "$$sql"; \
			fi \
		done; \
		echo "$(GREEN)✓ Migrations complete$(NC)"; \
	else \
		echo "$(YELLOW)No migration directory found$(NC)"; \
	fi

local-db-seed: ## Seed the database with test data
	@echo "$(GREEN)Seeding database with test data...$(NC)"
	@if [ -f infrastructure/lambda/db_migration/seed.sql ]; then \
		docker-compose exec -T postgres psql -U loglineos -d loglineos < infrastructure/lambda/db_migration/seed.sql; \
		echo "$(GREEN)✓ Database seeded$(NC)"; \
	else \
		echo "$(YELLOW)No seed file found. Skipping.$(NC)"; \
	fi

local-db-reset: local-down-clean local-up local-db-init ## Reset database (clean + init)
	@echo "$(GREEN)✓ Database reset complete$(NC)"

local-db-shell: ## Connect to the local PostgreSQL database
	@docker-compose exec postgres psql -U loglineos -d loglineos

local-redis-cli: ## Connect to the local Redis instance
	@docker-compose exec redis redis-cli

local-logs: ## View logs from local services
	@docker-compose logs -f

local-logs-postgres: ## View PostgreSQL logs
	@docker-compose logs -f postgres

local-logs-redis: ## View Redis logs
	@docker-compose logs -f redis

local-ps: ## Show status of local services
	@docker-compose ps

test-local: ## Run tests against local infrastructure
	@echo "$(GREEN)Running tests...$(NC)"
	@echo "$(YELLOW)Note: Test infrastructure not yet implemented$(NC)"
	@echo "$(YELLOW)This would run unit and integration tests$(NC)"

local-clean: ## Clean up local build artifacts
	@echo "$(GREEN)Cleaning build artifacts...$(NC)"
	@find infrastructure/lambda -name "*.zip" -delete
	@find infrastructure/lambda -name "node_modules" -type d -exec rm -rf {} + 2>/dev/null || true
	@find infrastructure/lambda -name "__pycache__" -type d -exec rm -rf {} + 2>/dev/null || true
	@echo "$(GREEN)✓ Clean complete$(NC)"

clean: local-clean ## Alias for local-clean

# AWS deployment targets (delegate to infrastructure Makefile)
deploy: ## Deploy to AWS (use: make deploy ENVIRONMENT=dev)
	@cd infrastructure && $(MAKE) apply ENVIRONMENT=$(or $(ENVIRONMENT),dev)

destroy: ## Destroy AWS infrastructure (use: make destroy ENVIRONMENT=dev)
	@cd infrastructure && $(MAKE) destroy ENVIRONMENT=$(or $(ENVIRONMENT),dev)

# Development workflow
dev: local-up install ## Start local environment and install dependencies
	@echo ""
	@echo "$(GREEN)✓ Development environment ready!$(NC)"
	@echo ""
	@echo "Next steps:"
	@echo "  1. Initialize database: make local-db-init"
	@echo "  2. View logs: make local-logs"
	@echo "  3. Connect to DB: make local-db-shell"

check-deps: ## Check if all dependencies are installed
	@echo "$(GREEN)Checking dependencies...$(NC)"
	@command -v docker >/dev/null 2>&1 || { echo "$(YELLOW)✗ Docker not installed$(NC)"; exit 1; }
	@command -v node >/dev/null 2>&1 || { echo "$(YELLOW)✗ Node.js not installed$(NC)"; exit 1; }
	@command -v python3 >/dev/null 2>&1 || { echo "$(YELLOW)✗ Python not installed$(NC)"; exit 1; }
	@command -v aws >/dev/null 2>&1 || { echo "$(YELLOW)✗ AWS CLI not installed$(NC)"; exit 1; }
	@command -v terraform >/dev/null 2>&1 || { echo "$(YELLOW)✗ Terraform not installed$(NC)"; exit 1; }
	@echo "$(GREEN)✓ All required dependencies are installed$(NC)"
