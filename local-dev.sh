#!/bin/bash
# local-dev.sh - Interactive helper for local development
# This script provides a menu-driven interface for common tasks

set -e

# Colors
GREEN='\033[0;32m'
BLUE='\033[0;34m'
YELLOW='\033[1;33m'
NC='\033[0m'

clear
echo -e "${BLUE}╔════════════════════════════════════════╗${NC}"
echo -e "${BLUE}║   LogLineOS Local Development Helper  ║${NC}"
echo -e "${BLUE}╔════════════════════════════════════════╝${NC}"
echo ""

# Check if Docker is running
if ! docker info &> /dev/null; then
    echo -e "${YELLOW}⚠️  Docker is not running!${NC}"
    echo "Please start Docker Desktop and try again."
    exit 1
fi

while true; do
    echo -e "${GREEN}Available Actions:${NC}"
    echo ""
    echo "  1) 🚀 Start local infrastructure"
    echo "  2) 🗄️  Initialize database"
    echo "  3) 📊 Show service status"
    echo "  4) 🔍 View logs"
    echo "  5) 💻 Connect to database shell"
    echo "  6) 🔄 Reset database (clean + init)"
    echo "  7) 📦 Install dependencies"
    echo "  8) 🧪 Run tests"
    echo "  9) 🛑 Stop services"
    echo " 10) 🧹 Clean build artifacts"
    echo " 11) ❓ Show help"
    echo "  0) 👋 Exit"
    echo ""
    read -p "Select an option: " choice

    case $choice in
        1)
            echo ""
            echo "Starting local infrastructure..."
            make local-up
            ;;
        2)
            echo ""
            echo "Initializing database..."
            make local-db-init
            ;;
        3)
            echo ""
            make local-ps
            ;;
        4)
            echo ""
            echo "Viewing logs (Ctrl+C to exit)..."
            make local-logs
            ;;
        5)
            echo ""
            echo "Connecting to database shell..."
            echo "Type '\q' to exit the psql shell"
            make local-db-shell
            ;;
        6)
            echo ""
            read -p "⚠️  This will DELETE all data. Continue? (y/n) " -n 1 -r
            echo
            if [[ $REPLY =~ ^[Yy]$ ]]; then
                make local-db-reset
            else
                echo "Cancelled."
            fi
            ;;
        7)
            echo ""
            echo "Installing dependencies..."
            make install
            ;;
        8)
            echo ""
            echo "Running tests..."
            ./test-local-setup.sh
            ;;
        9)
            echo ""
            echo "Stopping services..."
            make local-down
            ;;
        10)
            echo ""
            echo "Cleaning build artifacts..."
            make clean
            ;;
        11)
            echo ""
            make help
            ;;
        0)
            echo ""
            echo "Goodbye! 👋"
            exit 0
            ;;
        *)
            echo ""
            echo -e "${YELLOW}Invalid option. Please try again.${NC}"
            ;;
    esac
    
    echo ""
    read -p "Press Enter to continue..."
    clear
done
