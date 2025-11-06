#!/bin/bash
# verify-automation.sh - Verify automation setup is complete

set -e

echo "🔍 LogLineOS Automation Verification"
echo "====================================="
echo ""

# Color codes
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

FAILED=0
WARNINGS=0

print_check() {
    if [ $2 -eq 0 ]; then
        echo -e "${GREEN}✓${NC} $1"
    else
        echo -e "${RED}✗${NC} $1"
        FAILED=$((FAILED + 1))
    fi
}

print_warning() {
    echo -e "${YELLOW}⚠${NC} $1"
    WARNINGS=$((WARNINGS + 1))
}

print_section() {
    echo ""
    echo "=== $1 ==="
    echo ""
}

# Check if we're in the right directory
if [ ! -f "README.md" ] || [ ! -d ".github" ]; then
    echo -e "${RED}✗${NC} Not in LogLineOS repository root"
    exit 1
fi

print_section "Automation Files"

# Check for workflow files
[ -f ".github/workflows/ci.yml" ] && print_check "CI workflow exists" 0 || print_check "CI workflow exists" 1
[ -f ".github/workflows/deploy.yml" ] && print_check "Deploy workflow exists" 0 || print_check "Deploy workflow exists" 1
[ -f ".github/workflows/maintenance.yml" ] && print_check "Maintenance workflow exists" 0 || print_check "Maintenance workflow exists" 1
[ -f ".github/workflows/auto-rollback.yml" ] && print_check "Auto-rollback workflow exists" 0 || print_check "Auto-rollback workflow exists" 1
[ -f ".github/dependabot.yml" ] && print_check "Dependabot config exists" 0 || print_check "Dependabot config exists" 1

print_section "Setup Scripts"

[ -f "complete-setup.sh" ] && print_check "Complete setup script exists" 0 || print_check "Complete setup script exists" 1
[ -x "complete-setup.sh" ] && print_check "Setup script is executable" 0 || print_check "Setup script is executable" 1
[ -f "setup-macos.sh" ] && print_check "macOS setup script exists" 0 || print_check "macOS setup script exists" 1
[ -x "setup-macos.sh" ] && print_check "macOS setup script is executable" 0 || print_check "macOS setup script is executable" 1

print_section "Documentation"

[ -f "AUTOMATION.md" ] && print_check "Automation guide exists" 0 || print_check "Automation guide exists" 1
[ -f ".github/SECRETS_SETUP.md" ] && print_check "Secrets setup guide exists" 0 || print_check "Secrets setup guide exists" 1
[ -f "README.md" ] && grep -q "AUTOMATION.md" README.md && print_check "README references automation" 0 || print_check "README references automation" 1

print_section "Infrastructure"

[ -f "docker-compose.yml" ] && print_check "Docker Compose config exists" 0 || print_check "Docker Compose config exists" 1
[ -f "Makefile" ] && print_check "Makefile exists" 0 || print_check "Makefile exists" 1
[ -d "infrastructure/terraform" ] && print_check "Terraform configuration exists" 0 || print_check "Terraform configuration exists" 1

print_section "GitHub Configuration Check"

# Check if GitHub CLI is available
if command -v gh &> /dev/null; then
    print_check "GitHub CLI installed" 0
    
    # Check if authenticated
    if gh auth status &> /dev/null; then
        print_check "GitHub CLI authenticated" 0
        
        # Check for secrets
        echo ""
        echo "Checking GitHub Secrets (requires repository access)..."
        
        if gh secret list &> /dev/null; then
            SECRETS=$(gh secret list 2>/dev/null | wc -l)
            if [ $SECRETS -gt 0 ]; then
                print_check "GitHub Secrets configured ($SECRETS secrets found)" 0
                gh secret list 2>/dev/null | while read secret; do
                    echo "  - $secret"
                done
            else
                print_warning "No GitHub Secrets configured yet"
                echo "  See .github/SECRETS_SETUP.md for setup instructions"
            fi
        else
            print_warning "Cannot access GitHub Secrets (may need repository permissions)"
        fi
    else
        print_warning "GitHub CLI not authenticated (run: gh auth login)"
    fi
else
    print_warning "GitHub CLI not installed (optional but recommended)"
fi

print_section "Workflow Syntax Validation"

# Check if yq is installed for YAML validation
if command -v yamllint &> /dev/null; then
    print_check "yamllint installed" 0
    
    for workflow in .github/workflows/*.yml; do
        if yamllint -d relaxed "$workflow" &> /dev/null; then
            print_check "$(basename $workflow) syntax valid" 0
        else
            print_check "$(basename $workflow) syntax valid" 1
        fi
    done
else
    print_warning "yamllint not installed (cannot validate workflow syntax)"
    echo "  Install: pip install yamllint"
fi

print_section "Summary"

echo ""
if [ $FAILED -eq 0 ] && [ $WARNINGS -eq 0 ]; then
    echo -e "${GREEN}✅ All automation checks passed!${NC}"
    echo ""
    echo "Your automation setup is complete and ready to use."
    echo ""
    echo "Next steps:"
    echo "  1. Configure GitHub Secrets (see .github/SECRETS_SETUP.md)"
    echo "  2. Push to main branch to trigger CI/CD"
    echo "  3. Monitor GitHub Actions for automated workflows"
    echo ""
elif [ $FAILED -eq 0 ]; then
    echo -e "${YELLOW}⚠ Automation setup complete with $WARNINGS warning(s)${NC}"
    echo ""
    echo "Some optional components are missing but core automation is functional."
    echo ""
else
    echo -e "${RED}❌ Automation setup incomplete: $FAILED failed check(s), $WARNINGS warning(s)${NC}"
    echo ""
    echo "Please address the failed checks above."
    exit 1
fi

# Additional recommendations
print_section "Recommendations"

echo "1. Configure GitHub Secrets for AWS credentials"
echo "   - See .github/SECRETS_SETUP.md"
echo ""
echo "2. Set up GitHub Environment protection rules"
echo "   - Go to Settings → Environments → New environment"
echo "   - Add 'production' environment with required reviewers"
echo ""
echo "3. Enable Dependabot alerts"
echo "   - Go to Settings → Security → Dependabot alerts"
echo ""
echo "4. Review automation workflows"
echo "   - .github/workflows/ci.yml - Continuous Integration"
echo "   - .github/workflows/deploy.yml - Automated Deployment"
echo "   - .github/workflows/maintenance.yml - Daily Maintenance"
echo "   - .github/workflows/auto-rollback.yml - Auto Rollback"
echo ""
echo "5. Read the automation guide"
echo "   - AUTOMATION.md - Complete automation documentation"
echo ""

exit 0
