#!/bin/bash
# setup-macos.sh - Complete setup script for LogLineOS on macOS (Mac mini)
# This script installs all dependencies needed to run LogLineOS locally

set -e

echo "🍎 Setting up LogLineOS on macOS..."
echo ""

# Color codes for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
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

# Check if running on macOS
if [[ "$OSTYPE" != "darwin"* ]]; then
    print_error "This script is designed for macOS only"
    exit 1
fi

print_info "This script will install:"
echo "  - Homebrew (package manager)"
echo "  - Docker Desktop (for local infrastructure)"
echo "  - Node.js 18+ (for Lambda functions)"
echo "  - Python 3.11+ (for Python Lambda functions)"
echo "  - AWS CLI (for AWS interactions)"
echo "  - Terraform (for infrastructure as code)"
echo "  - PostgreSQL client tools"
echo "  - jq (JSON processor)"
echo ""

read -p "Continue with installation? (y/n) " -n 1 -r
echo
if [[ ! $REPLY =~ ^[Yy]$ ]]; then
    echo "Installation cancelled"
    exit 1
fi

echo ""
echo "=== Installing Dependencies ==="
echo ""

# 1. Install Homebrew if not installed
if ! command -v brew &> /dev/null; then
    print_info "Installing Homebrew..."
    /bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"
    
    # Add Homebrew to PATH for Apple Silicon Macs
    if [[ $(uname -m) == 'arm64' ]]; then
        echo 'eval "$(/opt/homebrew/bin/brew shellenv)"' >> ~/.zprofile
        eval "$(/opt/homebrew/bin/brew shellenv)"
    fi
    
    print_status "Homebrew installed"
else
    print_status "Homebrew already installed"
    brew update
fi

# 2. Install Docker Desktop
if ! command -v docker &> /dev/null; then
    print_info "Installing Docker Desktop..."
    brew install --cask docker
    
    print_info "Please start Docker Desktop from Applications folder"
    print_info "Waiting for Docker to start..."
    
    # Wait for Docker to start
    while ! docker info &> /dev/null; do
        sleep 2
    done
    
    print_status "Docker Desktop installed and running"
else
    print_status "Docker already installed"
    
    # Check if Docker is running
    if ! docker info &> /dev/null; then
        print_info "Docker is installed but not running"
        print_info "Please start Docker Desktop from Applications folder"
        read -p "Press enter when Docker is running..."
    fi
fi

# 3. Install Node.js
if ! command -v node &> /dev/null; then
    print_info "Installing Node.js..."
    brew install node@18
    brew link node@18
    print_status "Node.js installed"
else
    NODE_VERSION=$(node -v | cut -d'v' -f2 | cut -d'.' -f1)
    if [ "$NODE_VERSION" -lt 18 ]; then
        print_info "Upgrading Node.js to version 18..."
        brew install node@18
        brew link --overwrite node@18
        print_status "Node.js upgraded"
    else
        print_status "Node.js $(node -v) already installed"
    fi
fi

# 4. Install Python 3.11+
if ! command -v python3 &> /dev/null; then
    print_info "Installing Python 3.11..."
    brew install python@3.11
    print_status "Python installed"
else
    PYTHON_VERSION=$(python3 --version | cut -d' ' -f2 | cut -d'.' -f1,2)
    print_status "Python $(python3 --version) already installed"
fi

# 5. Install AWS CLI
if ! command -v aws &> /dev/null; then
    print_info "Installing AWS CLI..."
    brew install awscli
    print_status "AWS CLI installed"
else
    print_status "AWS CLI already installed"
fi

# 6. Install Terraform
if ! command -v terraform &> /dev/null; then
    print_info "Installing Terraform..."
    brew tap hashicorp/tap
    brew install hashicorp/tap/terraform
    print_status "Terraform installed"
else
    print_status "Terraform already installed"
fi

# 7. Install PostgreSQL client tools
if ! command -v psql &> /dev/null; then
    print_info "Installing PostgreSQL client..."
    brew install postgresql@15
    print_status "PostgreSQL client installed"
else
    print_status "PostgreSQL client already installed"
fi

# 8. Install jq (JSON processor)
if ! command -v jq &> /dev/null; then
    print_info "Installing jq..."
    brew install jq
    print_status "jq installed"
else
    print_status "jq already installed"
fi

# 9. Install additional useful tools
print_info "Installing additional tools..."
brew install git curl wget

echo ""
echo "=== Verifying Installation ==="
echo ""

# Verify all installations
FAILED=0

check_command() {
    if command -v $1 &> /dev/null; then
        print_status "$2 $(command -v $1)"
    else
        print_error "$2 not found"
        FAILED=1
    fi
}

check_command brew "Homebrew"
check_command docker "Docker"
check_command node "Node.js"
check_command npm "npm"
check_command python3 "Python"
check_command pip3 "pip"
check_command aws "AWS CLI"
check_command terraform "Terraform"
check_command psql "PostgreSQL client"
check_command jq "jq"
check_command git "Git"

echo ""
if [ $FAILED -eq 0 ]; then
    print_status "All dependencies installed successfully!"
else
    print_error "Some dependencies failed to install"
    exit 1
fi

echo ""
echo "=== Next Steps ==="
echo ""
echo "1. Configure AWS credentials:"
echo "   aws configure"
echo ""
echo "2. Start local infrastructure:"
echo "   make local-up"
echo ""
echo "3. Initialize the database:"
echo "   make local-db-init"
echo ""
echo "4. Run tests:"
echo "   make test-local"
echo ""
echo "5. See LOCAL_SETUP.md for detailed instructions"
echo ""

print_status "Setup complete! 🎉"
