#!/bin/bash
# complete-setup.sh - Fully automated setup script for LogLineOS
# This script requires ZERO manual intervention after initial confirmation

set -e

echo "🚀 LogLineOS Complete Automated Setup"
echo "======================================"
echo ""

# Color codes for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Function to print colored output
print_status() {
    echo -e "${GREEN}✓${NC} $1"
}

print_error() {
    echo -e "${RED}✗${NC} $1"
}

print_info() {
    echo -e "${YELLOW}ℹ${NC} $1"
}

print_section() {
    echo -e "\n${BLUE}=== $1 ===${NC}\n"
}

# Check if running on supported OS
OS_TYPE="unknown"
if [[ "$OSTYPE" == "darwin"* ]]; then
    OS_TYPE="macos"
elif [[ "$OSTYPE" == "linux-gnu"* ]]; then
    OS_TYPE="linux"
else
    print_error "Unsupported operating system: $OSTYPE"
    exit 1
fi

print_info "Detected OS: $OS_TYPE"

# Check for required privileges
if [[ "$OS_TYPE" == "linux" ]] && [[ $EUID -eq 0 ]]; then
   print_error "This script should not be run as root on Linux"
   exit 1
fi

print_section "Installation Plan"
echo "This script will install and configure:"
echo "  1. System package manager (Homebrew/apt)"
echo "  2. Docker and Docker Compose"
echo "  3. Node.js 18+ and npm"
echo "  4. Python 3.11+ and pip"
echo "  5. AWS CLI"
echo "  6. Terraform"
echo "  7. PostgreSQL client tools"
echo "  8. Additional utilities (jq, git, curl)"
echo "  9. Local development infrastructure"
echo " 10. Project dependencies"
echo ""

# Non-interactive mode flag
NONINTERACTIVE=${NONINTERACTIVE:-false}

if [ "$NONINTERACTIVE" != "true" ]; then
    read -p "Continue with automated setup? (y/N) " -n 1 -r
    echo
    if [[ ! $REPLY =~ ^[Yy]$ ]]; then
        echo "Setup cancelled"
        exit 0
    fi
fi

# Create log file
LOG_FILE="/tmp/loglineos-setup-$(date +%Y%m%d-%H%M%S).log"
exec > >(tee -a "$LOG_FILE")
exec 2>&1

print_info "Setup log: $LOG_FILE"

# ========================================
# macOS Setup
# ========================================
if [[ "$OS_TYPE" == "macos" ]]; then
    print_section "macOS Setup"
    
    # Install Homebrew
    if ! command -v brew &> /dev/null; then
        print_info "Installing Homebrew..."
        NONINTERACTIVE=1 /bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"
        
        # Add Homebrew to PATH
        if [[ $(uname -m) == 'arm64' ]]; then
            echo 'eval "$(/opt/homebrew/bin/brew shellenv)"' >> ~/.zprofile
            eval "$(/opt/homebrew/bin/brew shellenv)"
        else
            echo 'eval "$(/usr/local/bin/brew shellenv)"' >> ~/.zprofile
            eval "$(/usr/local/bin/brew shellenv)"
        fi
        print_status "Homebrew installed"
    else
        print_status "Homebrew already installed"
        brew update
    fi
    
    # Install Docker Desktop
    if ! command -v docker &> /dev/null; then
        print_info "Installing Docker Desktop..."
        brew install --cask docker --force
        
        # Start Docker Desktop
        open -a Docker
        print_info "Starting Docker Desktop (this may take a minute)..."
        
        # Wait for Docker to start (max 3 minutes)
        COUNTER=0
        MAX_WAIT=180
        while ! docker info &> /dev/null && [ $COUNTER -lt $MAX_WAIT ]; do
            sleep 5
            COUNTER=$((COUNTER + 5))
            echo -n "."
        done
        echo ""
        
        if docker info &> /dev/null; then
            print_status "Docker Desktop installed and running"
        else
            print_error "Docker Desktop installation requires manual start. Please start Docker Desktop and run this script again."
            exit 1
        fi
    else
        print_status "Docker already installed"
        if ! docker info &> /dev/null; then
            print_info "Starting Docker..."
            open -a Docker
            sleep 10
        fi
    fi
    
    # Install other dependencies
    print_info "Installing development tools..."
    brew install node@18 python@3.11 awscli terraform postgresql@15 jq git curl wget 2>&1 | grep -v "already installed" || true
    
    # Link Node.js
    brew link --overwrite node@18 --force 2>&1 || true
    
    print_status "macOS dependencies installed"
fi

# ========================================
# Linux Setup
# ========================================
if [[ "$OS_TYPE" == "linux" ]]; then
    print_section "Linux Setup"
    
    # Update package list
    print_info "Updating package list..."
    sudo apt-get update -qq
    
    # Install Docker
    if ! command -v docker &> /dev/null; then
        print_info "Installing Docker..."
        curl -fsSL https://get.docker.com -o /tmp/get-docker.sh
        sudo sh /tmp/get-docker.sh
        sudo usermod -aG docker $USER
        print_status "Docker installed (may require logout/login for group membership)"
    else
        print_status "Docker already installed"
    fi
    
    # Install Docker Compose
    if ! command -v docker-compose &> /dev/null; then
        print_info "Installing Docker Compose..."
        sudo apt-get install -y docker-compose
        print_status "Docker Compose installed"
    else
        print_status "Docker Compose already installed"
    fi
    
    # Install Node.js
    if ! command -v node &> /dev/null; then
        print_info "Installing Node.js..."
        curl -fsSL https://deb.nodesource.com/setup_18.x | sudo -E bash -
        sudo apt-get install -y nodejs
        print_status "Node.js installed"
    else
        print_status "Node.js already installed"
    fi
    
    # Install Python
    if ! command -v python3 &> /dev/null; then
        print_info "Installing Python 3.11..."
        sudo apt-get install -y python3.11 python3-pip python3.11-venv
        print_status "Python installed"
    else
        print_status "Python already installed"
    fi
    
    # Install AWS CLI
    if ! command -v aws &> /dev/null; then
        print_info "Installing AWS CLI..."
        curl "https://awscli.amazonaws.com/awscli-exe-linux-x86_64.zip" -o "/tmp/awscliv2.zip"
        unzip -q /tmp/awscliv2.zip -d /tmp
        sudo /tmp/aws/install
        print_status "AWS CLI installed"
    else
        print_status "AWS CLI already installed"
    fi
    
    # Install Terraform
    if ! command -v terraform &> /dev/null; then
        print_info "Installing Terraform..."
        wget -q https://releases.hashicorp.com/terraform/1.6.0/terraform_1.6.0_linux_amd64.zip -O /tmp/terraform.zip
        unzip -q /tmp/terraform.zip -d /tmp
        sudo mv /tmp/terraform /usr/local/bin/
        print_status "Terraform installed"
    else
        print_status "Terraform already installed"
    fi
    
    # Install PostgreSQL client
    if ! command -v psql &> /dev/null; then
        print_info "Installing PostgreSQL client..."
        sudo apt-get install -y postgresql-client
        print_status "PostgreSQL client installed"
    else
        print_status "PostgreSQL client already installed"
    fi
    
    # Install utilities
    print_info "Installing utilities..."
    sudo apt-get install -y jq git curl wget
    
    print_status "Linux dependencies installed"
fi

# ========================================
# Verify Installations
# ========================================
print_section "Verification"

FAILED=0
check_command() {
    if command -v $1 &> /dev/null; then
        VERSION=$($1 --version 2>&1 | head -n 1 || echo "unknown")
        print_status "$2: $VERSION"
    else
        print_error "$2 not found"
        FAILED=1
    fi
}

check_command docker "Docker"
check_command docker-compose "Docker Compose"
check_command node "Node.js"
check_command npm "npm"
check_command python3 "Python"
check_command pip3 "pip"
check_command aws "AWS CLI"
check_command terraform "Terraform"
check_command psql "PostgreSQL client"
check_command jq "jq"
check_command git "Git"

if [ $FAILED -eq 1 ]; then
    print_error "Some dependencies failed to install. Please check the log: $LOG_FILE"
    exit 1
fi

# ========================================
# Start Local Infrastructure
# ========================================
print_section "Starting Local Infrastructure"

# Ensure we're in the right directory
cd "$(dirname "$0")"

# Make sure docker-compose.yml exists
if [ ! -f "docker-compose.yml" ]; then
    print_error "docker-compose.yml not found in current directory"
    exit 1
fi

# Start Docker services
print_info "Starting PostgreSQL and Redis..."
docker-compose up -d postgres redis

# Wait for services to be healthy
print_info "Waiting for services to be ready..."
sleep 10

# Check service status
if docker-compose ps | grep -q "postgres.*Up"; then
    print_status "PostgreSQL is running"
else
    print_error "PostgreSQL failed to start"
    FAILED=1
fi

if docker-compose ps | grep -q "redis.*Up"; then
    print_status "Redis is running"
else
    print_error "Redis failed to start"
    FAILED=1
fi

if [ $FAILED -eq 1 ]; then
    print_error "Local infrastructure failed to start"
    exit 1
fi

# ========================================
# Initialize Database
# ========================================
print_section "Database Initialization"

print_info "Creating database extensions..."
docker-compose exec -T postgres psql -U loglineos -d loglineos -c "CREATE EXTENSION IF NOT EXISTS vector;" 2>&1 | grep -v "already exists" || true

print_info "Creating database schemas..."
docker-compose exec -T postgres psql -U loglineos -d loglineos -c "CREATE SCHEMA IF NOT EXISTS ledger;" 2>&1 | grep -v "already exists" || true

# Run migrations if they exist
if [ -f "infrastructure/lambda/db_migration/migrations/001_initial_schema.sql" ]; then
    print_info "Running database migrations..."
    docker-compose exec -T postgres psql -U loglineos -d loglineos < infrastructure/lambda/db_migration/migrations/001_initial_schema.sql 2>&1 | grep -E "CREATE|ALTER|ERROR" || true
    print_status "Database migrations complete"
else
    print_info "No migration files found, skipping"
fi

print_status "Database initialized"

# ========================================
# Install Project Dependencies
# ========================================
print_section "Installing Project Dependencies"

# Install Node.js dependencies
for dir in infrastructure/lambda/*/; do
    if [ -f "${dir}package.json" ]; then
        print_info "Installing Node.js dependencies for $(basename $dir)..."
        (cd "$dir" && npm ci --silent --prefer-offline 2>&1 | grep -E "added|ERR" || true)
    fi
done

# Install Python dependencies
for dir in infrastructure/lambda/*/; do
    if [ -f "${dir}requirements.txt" ]; then
        print_info "Installing Python dependencies for $(basename $dir)..."
        (cd "$dir" && pip3 install --user -q -r requirements.txt 2>&1 | grep -E "Successfully|ERROR" || true)
    fi
done

print_status "Project dependencies installed"

# ========================================
# Final Verification
# ========================================
print_section "Final Verification"

# Test database connection
print_info "Testing database connection..."
if docker-compose exec -T postgres psql -U loglineos -d loglineos -c "SELECT version();" > /dev/null 2>&1; then
    print_status "Database connection successful"
else
    print_error "Database connection failed"
    FAILED=1
fi

# Test Redis connection
print_info "Testing Redis connection..."
if docker-compose exec -T redis redis-cli ping > /dev/null 2>&1; then
    print_status "Redis connection successful"
else
    print_error "Redis connection failed"
    FAILED=1
fi

# ========================================
# Summary
# ========================================
print_section "Setup Complete!"

if [ $FAILED -eq 0 ]; then
    echo -e "${GREEN}✅ All components installed and verified successfully!${NC}"
    echo ""
    echo "🎯 Next Steps:"
    echo "  1. Configure AWS credentials: aws configure"
    echo "  2. Start development: make dev"
    echo "  3. View logs: make local-logs"
    echo "  4. Access database: make local-db-shell"
    echo ""
    echo "📚 Documentation:"
    echo "  - Quick Reference: QUICKREF.md"
    echo "  - Local Setup Guide: LOCAL_SETUP.md"
    echo "  - Deployment Guide: QUICKSTART.md"
    echo ""
    echo "💡 Useful Commands:"
    echo "  make help              - Show all available commands"
    echo "  make local-ps          - Check service status"
    echo "  make local-logs        - View service logs"
    echo "  make local-db-reset    - Reset database"
    echo ""
else
    echo -e "${RED}❌ Setup completed with errors${NC}"
    echo "Please check the log file: $LOG_FILE"
    exit 1
fi

print_info "Log saved to: $LOG_FILE"
