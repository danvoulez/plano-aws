# LogLineOS Local Setup Guide for macOS (Mac mini)

This guide will help you set up LogLineOS for local development on a Mac mini with no dependencies pre-installed.

## Table of Contents

1. [Prerequisites](#prerequisites)
2. [Quick Start](#quick-start)
3. [Detailed Setup](#detailed-setup)
4. [Local Development Workflow](#local-development-workflow)
5. [Database Management](#database-management)
6. [Troubleshooting](#troubleshooting)
7. [Next Steps](#next-steps)

---

## Prerequisites

- **macOS** 11.0 or later (Big Sur, Monterey, Ventura, or Sonoma)
- **Internet connection** for downloading dependencies
- **~10 GB free disk space** for Docker images and dependencies
- **Administrator access** for installing system packages

---

## Quick Start

If you're starting with a fresh Mac mini with no dependencies installed, follow these steps:

### Step 1: Clone the Repository

```bash
# Open Terminal (Applications > Utilities > Terminal)
# Clone the repository
git clone https://github.com/danvoulez/plano-aws.git
cd plano-aws
```

### Step 2: Run the Setup Script

The setup script will install all required dependencies:

```bash
# Make the script executable and run it
chmod +x setup-macos.sh
./setup-macos.sh
```

This will install:
- ✅ **Homebrew** - Package manager for macOS
- ✅ **Docker Desktop** - Container runtime for local infrastructure
- ✅ **Node.js 18+** - JavaScript runtime for Lambda functions
- ✅ **Python 3.11+** - Python runtime for Python Lambda functions
- ✅ **AWS CLI** - Command-line tool for AWS
- ✅ **Terraform** - Infrastructure as Code tool
- ✅ **PostgreSQL client** - Database client tools
- ✅ **jq** - JSON processor

**Expected time:** 15-30 minutes (depending on internet speed)

### Step 3: Start Local Infrastructure

```bash
# Start PostgreSQL and Redis using Docker
make local-up
```

This starts:
- PostgreSQL with pgvector extension (port 5432)
- Redis for caching (port 6379)

### Step 4: Initialize the Database

```bash
# Create database schema and extensions
make local-db-init
```

### Step 5: Install Project Dependencies

```bash
# Install Node.js and Python dependencies for Lambda functions
make install
```

### Step 6: Verify Setup

```bash
# Check that all services are running
make local-ps

# Connect to the database to verify
make local-db-shell
# Type \l to list databases, \q to quit
```

**🎉 You're ready to develop!**

---

## Detailed Setup

### Manual Installation (Alternative to setup-macos.sh)

If you prefer to install dependencies manually or the script fails:

#### 1. Install Homebrew

```bash
/bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"

# For Apple Silicon Macs, add Homebrew to PATH
echo 'eval "$(/opt/homebrew/bin/brew shellenv)"' >> ~/.zprofile
eval "$(/opt/homebrew/bin/brew shellenv)"
```

#### 2. Install Docker Desktop

```bash
brew install --cask docker
```

Then:
1. Open Docker Desktop from Applications
2. Wait for Docker to start (you'll see the whale icon in the menu bar)
3. Configure Docker to start automatically on login (optional)

#### 3. Install Development Tools

```bash
# Install Node.js
brew install node@18

# Install Python
brew install python@3.11

# Install AWS CLI
brew install awscli

# Install Terraform
brew tap hashicorp/tap
brew install hashicorp/tap/terraform

# Install PostgreSQL client
brew install postgresql@15

# Install jq
brew install jq
```

#### 4. Verify Installation

```bash
docker --version
node --version
npm --version
python3 --version
pip3 --version
aws --version
terraform --version
psql --version
jq --version
```

---

## Local Development Workflow

### Starting Your Development Environment

```bash
# Option 1: Quick start (most common)
make dev

# Option 2: Step by step
make local-up          # Start infrastructure
make install           # Install dependencies
make local-db-init     # Initialize database
```

### Working with the Database

```bash
# Connect to PostgreSQL shell
make local-db-shell

# Run migrations
make local-db-migrate

# Seed test data (if available)
make local-db-seed

# Reset database (clean slate)
make local-db-reset
```

### Viewing Logs

```bash
# View all service logs
make local-logs

# View PostgreSQL logs only
make local-logs-postgres

# View Redis logs only
make local-logs-redis
```

### Stopping Services

```bash
# Stop services (keeps data)
make local-down

# Stop services and remove all data
make local-down-clean
```

---

## Database Management

### Connection Details

- **Host:** localhost
- **Port:** 5432
- **Database:** loglineos
- **Username:** loglineos
- **Password:** loglineos_dev_password

### Using pgAdmin (Optional)

If you want a graphical database management tool:

```bash
# Start all services including pgAdmin
make local-up-all
```

Then open http://localhost:5050 in your browser:
- **Email:** admin@loglineos.local
- **Password:** admin

Add the PostgreSQL server in pgAdmin:
1. Right-click "Servers" → "Create" → "Server"
2. Name: LogLineOS Local
3. Connection tab:
   - Host: host.docker.internal (on Mac)
   - Port: 5432
   - Database: loglineos
   - Username: loglineos
   - Password: loglineos_dev_password

### Direct psql Commands

```bash
# Connect using psql
docker-compose exec postgres psql -U loglineos -d loglineos

# Run a single query
docker-compose exec -T postgres psql -U loglineos -d loglineos -c "SELECT version();"

# Execute a SQL file
docker-compose exec -T postgres psql -U loglineos -d loglineos < my_script.sql
```

---

## Testing Lambda Functions Locally

### Node.js Lambda Functions

```bash
# Navigate to a Lambda function
cd infrastructure/lambda/stage0_loader

# Install dependencies
npm install

# Run the function locally (example)
node -e "
  const handler = require('./index.js');
  handler.handler({
    // Your test event here
  }, {}).then(console.log).catch(console.error);
"
```

### Python Lambda Functions

```bash
# Navigate to a Lambda function
cd infrastructure/lambda/db_migration

# Install dependencies
pip3 install -r requirements.txt

# Run the function locally (example)
python3 -c "
import index
event = {}  # Your test event
context = {}  # Mock context
result = index.handler(event, context)
print(result)
"
```

---

## Using LocalStack for AWS Service Emulation

LocalStack allows you to test AWS services locally without deploying to AWS.

### Start LocalStack

```bash
make local-up-localstack
```

This starts:
- PostgreSQL (port 5432)
- Redis (port 6379)
- LocalStack (port 4566) - Emulates AWS services

### Configure AWS CLI for LocalStack

```bash
# Set endpoint URL
export AWS_ENDPOINT_URL=http://localhost:4566

# Set dummy credentials
export AWS_ACCESS_KEY_ID=test
export AWS_SECRET_ACCESS_KEY=test
export AWS_DEFAULT_REGION=us-east-1

# Test LocalStack
aws --endpoint-url=http://localhost:4566 s3 ls
```

### Services Available in LocalStack

- Lambda
- S3
- DynamoDB
- Secrets Manager
- SQS
- SNS
- Step Functions
- API Gateway

---

## Common Makefile Commands

```bash
# View all available commands
make help

# Check if dependencies are installed
make check-deps

# Start development environment
make dev

# Start infrastructure
make local-up

# Start all services including pgAdmin
make local-up-all

# Stop infrastructure
make local-down

# Initialize database
make local-db-init

# Connect to database
make local-db-shell

# Connect to Redis
make local-redis-cli

# View logs
make local-logs

# Check service status
make local-ps

# Clean build artifacts
make clean

# Install dependencies
make install
```

---

## Troubleshooting

### Docker Not Starting

**Problem:** "Cannot connect to Docker daemon"

**Solution:**
1. Open Docker Desktop from Applications
2. Wait for it to fully start (whale icon in menu bar)
3. Check Docker is running: `docker info`

### Port Already in Use

**Problem:** "Port 5432 is already allocated"

**Solution:**
```bash
# Stop any conflicting services
brew services stop postgresql  # If you have PostgreSQL installed via Homebrew

# Or use different ports by editing docker-compose.yml
# Change "5432:5432" to "5433:5432"
```

### Database Connection Refused

**Problem:** "Could not connect to PostgreSQL"

**Solution:**
```bash
# Check if PostgreSQL container is running
docker-compose ps

# Check PostgreSQL logs
make local-logs-postgres

# Restart PostgreSQL
docker-compose restart postgres

# Wait for it to be healthy
docker-compose ps
```

### Node.js or Python Version Issues

**Problem:** "Node version too old" or "Python version incompatible"

**Solution:**
```bash
# Upgrade Node.js
brew unlink node
brew install node@18
brew link node@18

# Upgrade Python
brew install python@3.11
```

### Permission Denied Errors

**Problem:** "Permission denied" when running scripts

**Solution:**
```bash
# Make scripts executable
chmod +x setup-macos.sh
chmod +x infrastructure/scripts/deploy.sh
```

### Docker Desktop Won't Install

**Problem:** Homebrew can't install Docker Desktop

**Solution:**
Download and install manually from https://www.docker.com/products/docker-desktop/

### Clean Slate Reset

If everything is broken, start fresh:

```bash
# Stop and remove all containers and data
make local-down-clean

# Remove Docker images (optional)
docker system prune -a --volumes

# Restart Docker Desktop
# Then start over
make local-up
make local-db-init
```

---

## Environment Variables

Copy the example environment file and customize:

```bash
cp .env.example .env
# Edit .env with your preferred settings
```

Key variables:
- `DB_HOST` - Database host (default: localhost)
- `DB_PORT` - Database port (default: 5432)
- `ENVIRONMENT` - Environment name (default: local)
- `LOG_LEVEL` - Logging level (default: debug)

---

## Next Steps

### For Local Development

1. **Explore the codebase**
   ```bash
   code .  # Opens VS Code
   ```

2. **Read the architecture docs**
   - [README.md](README.md) - Project overview
   - [plano-aws.md](plano-aws.md) - Detailed architecture
   - [QUICKSTART.md](QUICKSTART.md) - AWS deployment guide

3. **Start developing**
   - Lambda functions are in `infrastructure/lambda/`
   - Terraform modules are in `infrastructure/terraform/modules/`

### For AWS Deployment

Once you're ready to deploy to AWS:

1. **Configure AWS credentials**
   ```bash
   aws configure
   ```

2. **Deploy to AWS development environment**
   ```bash
   cd infrastructure
   make apply ENVIRONMENT=dev
   ```

3. **See the deployment guide**
   - [QUICKSTART.md](QUICKSTART.md) - Full AWS deployment steps

---

## Additional Tools

### Recommended VS Code Extensions

If using Visual Studio Code:

```bash
# Install VS Code
brew install --cask visual-code

# Recommended extensions:
# - AWS Toolkit
# - Docker
# - Terraform
# - PostgreSQL
# - ESLint
# - Python
```

### Useful macOS Shortcuts

- **Terminal:** `Cmd + Space`, type "Terminal"
- **Force Quit:** `Cmd + Option + Esc`
- **Activity Monitor:** `Applications > Utilities > Activity Monitor`

---

## Support and Resources

- **Repository:** https://github.com/danvoulez/plano-aws
- **Issues:** https://github.com/danvoulez/plano-aws/issues
- **Docker Docs:** https://docs.docker.com/desktop/mac/
- **AWS CLI Docs:** https://aws.amazon.com/cli/
- **Terraform Docs:** https://www.terraform.io/docs

---

## Summary

This local setup allows you to:

✅ Develop and test Lambda functions locally  
✅ Run database migrations and seeds  
✅ Test with a real PostgreSQL database  
✅ Use Redis for caching  
✅ Avoid AWS costs during development  
✅ Work offline (except for AWS deployments)  

For production deployments, see [QUICKSTART.md](QUICKSTART.md) for AWS deployment instructions.

**Happy coding! 🚀**
