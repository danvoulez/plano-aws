# LogLineOS Local Development - Quick Reference

## 🚀 Getting Started

```bash
# First time setup (Mac mini with no dependencies)
./setup-macos.sh         # Install all dependencies
make dev                 # Start environment + install packages
make local-db-init       # Initialize database schema
```

## 📦 Daily Development

```bash
# Start work
make local-up            # Start PostgreSQL + Redis
make local-ps            # Check services are running
make local-db-shell      # Connect to database

# Stop work
make local-down          # Stop services (keeps data)
```

## 🗄️ Database Operations

```bash
make local-db-init       # Initialize schema (first time)
make local-db-migrate    # Run migrations
make local-db-reset      # Nuclear option: clean + init
make local-db-shell      # PostgreSQL prompt
```

## 🔍 Debugging

```bash
make local-logs          # All service logs
make local-logs-postgres # Just PostgreSQL
make local-ps            # Service status
```

## 🧪 Testing Lambda Functions

```bash
# Node.js functions
cd infrastructure/lambda/stage0_loader
npm install
node index.js

# Python functions
cd infrastructure/lambda/db_migration
pip3 install -r requirements.txt
python3 handler.py
```

## 🔧 Common Tasks

```bash
make help                # List all commands
make check-deps          # Verify prerequisites
make install             # Install all dependencies
make clean               # Remove build artifacts
```

## 📊 Database Access

| **Property** | **Value** |
|-------------|----------|
| Host | localhost |
| Port | 5432 |
| Database | loglineos |
| Username | loglineos |
| Password | loglineos_dev_password |

## 🌐 Service URLs

| **Service** | **URL** |
|------------|---------|
| PostgreSQL | `postgresql://loglineos:loglineos_dev_password@localhost:5432/loglineos` |
| Redis | `redis://localhost:6379` |
| pgAdmin | `http://localhost:5050` (with `make local-up-all`) |

## 🆘 Troubleshooting

**Problem:** Docker won't start  
**Fix:** Open Docker Desktop app, wait for whale icon

**Problem:** Port 5432 in use  
**Fix:** `brew services stop postgresql`

**Problem:** Database won't initialize  
**Fix:** `make local-down-clean && make local-up && make local-db-init`

**Problem:** Permission denied  
**Fix:** `chmod +x setup-macos.sh`

## 📚 Documentation

- [LOCAL_SETUP.md](LOCAL_SETUP.md) - Complete setup guide
- [README.md](README.md) - Project overview
- [QUICKSTART.md](QUICKSTART.md) - AWS deployment

## ☁️ Deploy to AWS

```bash
# Configure AWS credentials first
aws configure

# Deploy to dev
cd infrastructure
make apply ENVIRONMENT=dev
```

---

**Need help?** Check [LOCAL_SETUP.md](LOCAL_SETUP.md) for detailed instructions.
