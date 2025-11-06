#!/bin/bash
# test-local-setup.sh - Validate local development environment
# This script tests that the local infrastructure is properly set up

set -e

# Colors
GREEN='\033[0;32m'
RED='\033[0;31m'
YELLOW='\033[1;33m'
NC='\033[0m'

print_success() { echo -e "${GREEN}✓${NC} $1"; }
print_error() { echo -e "${RED}✗${NC} $1"; }
print_info() { echo -e "${YELLOW}ℹ${NC} $1"; }

echo "🧪 Testing LogLineOS Local Setup"
echo ""

FAILED=0

# Test 1: Docker is running
print_info "Checking Docker..."
if docker info &> /dev/null; then
    print_success "Docker is running"
else
    print_error "Docker is not running"
    FAILED=1
fi

# Test 2: PostgreSQL container is running
print_info "Checking PostgreSQL container..."
if docker-compose ps postgres | grep -q "Up"; then
    print_success "PostgreSQL container is running"
else
    print_error "PostgreSQL container is not running (run: make local-up)"
    FAILED=1
fi

# Test 3: Redis container is running
print_info "Checking Redis container..."
if docker-compose ps redis | grep -q "Up"; then
    print_success "Redis container is running"
else
    print_error "Redis container is not running (run: make local-up)"
    FAILED=1
fi

# Test 4: PostgreSQL is accessible
print_info "Testing PostgreSQL connection..."
if docker-compose exec -T postgres psql -U loglineos -d loglineos -c "SELECT 1;" &> /dev/null; then
    print_success "PostgreSQL is accessible"
else
    print_error "Cannot connect to PostgreSQL"
    FAILED=1
fi

# Test 5: pgvector extension is installed
print_info "Checking pgvector extension..."
if docker-compose exec -T postgres psql -U loglineos -d loglineos -c "SELECT extname FROM pg_extension WHERE extname='vector';" | grep -q "vector"; then
    print_success "pgvector extension is installed"
else
    print_error "pgvector extension not found (run: make local-db-init)"
    FAILED=1
fi

# Test 6: Schemas exist
print_info "Checking database schemas..."
SCHEMAS=$(docker-compose exec -T postgres psql -U loglineos -d loglineos -c "\dn" 2>/dev/null | grep -E "app|ledger" | wc -l)
if [ "$SCHEMAS" -ge 2 ]; then
    print_success "Database schemas (app, ledger) exist"
else
    print_error "Database schemas not found (run: make local-db-init)"
    FAILED=1
fi

# Test 7: universal_registry table exists
print_info "Checking universal_registry table..."
if docker-compose exec -T postgres psql -U loglineos -d loglineos -c "\dt ledger.universal_registry" 2>/dev/null | grep -q "universal_registry"; then
    print_success "universal_registry table exists"
else
    print_error "universal_registry table not found (run: make local-db-init)"
    FAILED=1
fi

# Test 8: Redis is accessible
print_info "Testing Redis connection..."
if docker-compose exec -T redis redis-cli ping 2>/dev/null | grep -q "PONG"; then
    print_success "Redis is accessible"
else
    print_error "Cannot connect to Redis"
    FAILED=1
fi

# Test 9: Node.js dependencies installed
print_info "Checking Node.js Lambda dependencies..."
NODE_DEPS_COUNT=$(find infrastructure/lambda -name "node_modules" -type d | wc -l)
if [ "$NODE_DEPS_COUNT" -gt 0 ]; then
    print_success "Node.js dependencies installed"
else
    print_error "Node.js dependencies not found (run: make install)"
    FAILED=1
fi

# Test 10: Check required commands
print_info "Checking required commands..."
MISSING_COMMANDS=0
for cmd in docker node npm python3 pip3 aws terraform psql jq; do
    if ! command -v $cmd &> /dev/null; then
        print_error "Command not found: $cmd"
        MISSING_COMMANDS=1
        FAILED=1
    fi
done
if [ $MISSING_COMMANDS -eq 0 ]; then
    print_success "All required commands are available"
fi

echo ""
if [ $FAILED -eq 0 ]; then
    echo -e "${GREEN}✓ All tests passed! Your local environment is ready.${NC}"
    echo ""
    echo "Next steps:"
    echo "  - Connect to database: make local-db-shell"
    echo "  - View logs: make local-logs"
    echo "  - See all commands: make help"
    exit 0
else
    echo -e "${RED}✗ Some tests failed. See errors above.${NC}"
    echo ""
    echo "Common fixes:"
    echo "  - Start services: make local-up"
    echo "  - Initialize database: make local-db-init"
    echo "  - Install dependencies: make install"
    echo "  - Run setup script: ./setup-macos.sh"
    exit 1
fi
