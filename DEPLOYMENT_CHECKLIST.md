# Mac Mini Deployment Checklist

This checklist guides you through deploying LogLineOS on a Mac mini with no dependencies installed.

## ✅ Pre-Deployment Checklist

### System Requirements
- [ ] macOS 11.0+ (Big Sur or later)
- [ ] ~10 GB free disk space
- [ ] Administrator access
- [ ] Internet connection

### Optional (for AWS deployment)
- [ ] AWS Account with admin access
- [ ] AWS credentials ready

---

## 🚀 Installation Steps

### Step 1: Clone Repository
```bash
git clone https://github.com/danvoulez/plano-aws.git
cd plano-aws
```
- [ ] Repository cloned successfully
- [ ] Changed to project directory

### Step 2: Run Setup Script
```bash
chmod +x setup-macos.sh
./setup-macos.sh
```

**Expected installations:**
- [ ] Homebrew installed
- [ ] Docker Desktop installed
- [ ] Node.js 18+ installed
- [ ] Python 3.11+ installed
- [ ] AWS CLI installed
- [ ] Terraform installed
- [ ] PostgreSQL client installed
- [ ] jq installed

**Time required:** ~15-30 minutes

### Step 3: Verify Docker
```bash
docker --version
docker info
```
- [ ] Docker version displayed
- [ ] Docker daemon is running
- [ ] Docker Desktop app is running (check menu bar)

### Step 4: Start Local Infrastructure
```bash
make local-up
```

**This starts:**
- [ ] PostgreSQL container on port 5432
- [ ] Redis container on port 6379

**Verify:**
```bash
make local-ps
```
Expected: Both services show "Up (healthy)" status

### Step 5: Initialize Database
```bash
make local-db-init
```

**This creates:**
- [ ] `app` and `ledger` schemas
- [ ] `universal_registry` table
- [ ] `memory_embeddings` table
- [ ] pgvector extension
- [ ] RLS policies

**Verify:**
```bash
make local-db-shell
# In psql:
\dn        # List schemas (should see app, ledger)
\dt ledger.*   # List tables
\q         # Quit
```

### Step 6: Install Project Dependencies
```bash
make install
```

**This installs:**
- [ ] Node.js dependencies for all Lambda functions
- [ ] Python dependencies for all Lambda functions

### Step 7: Run Tests
```bash
./test-local-setup.sh
```

**Expected results:**
- [ ] ✓ Docker is running
- [ ] ✓ PostgreSQL container is running
- [ ] ✓ Redis container is running
- [ ] ✓ PostgreSQL is accessible
- [ ] ✓ pgvector extension is installed
- [ ] ✓ Database schemas exist
- [ ] ✓ universal_registry table exists
- [ ] ✓ Redis is accessible
- [ ] ✓ Node.js dependencies installed
- [ ] ✓ All required commands available

---

## 🎯 Post-Installation Verification

### Check Services
```bash
make local-ps
```
Expected output: All services "Up" with healthy status

### Test Database Connection
```bash
docker compose exec postgres psql -U loglineos -d loglineos -c "SELECT version();"
```
Expected: PostgreSQL version info displayed

### Test Redis Connection
```bash
docker compose exec redis redis-cli ping
```
Expected: "PONG"

### View Service Logs
```bash
make local-logs
```
Expected: Logs from PostgreSQL and Redis (no errors)

---

## 📋 Daily Development Workflow

### Starting Work
```bash
# Option 1: Quick start
make dev

# Option 2: Interactive menu
./local-dev.sh

# Option 3: Manual
make local-up
make local-ps  # Verify running
```

### During Development
```bash
# View logs
make local-logs

# Connect to database
make local-db-shell

# Check service status
make local-ps
```

### Ending Work
```bash
# Stop services (keeps data)
make local-down

# OR stop and delete all data
make local-down-clean
```

---

## 🔧 Common Commands Quick Reference

| Task | Command |
|------|---------|
| Start services | `make local-up` |
| Stop services | `make local-down` |
| Initialize DB | `make local-db-init` |
| Reset DB | `make local-db-reset` |
| DB shell | `make local-db-shell` |
| View logs | `make local-logs` |
| Service status | `make local-ps` |
| Run tests | `./test-local-setup.sh` |
| Interactive menu | `./local-dev.sh` |
| Help | `make help` |

---

## 🐛 Troubleshooting

### Issue: Docker won't start
**Solution:**
1. Open Docker Desktop from Applications
2. Wait for whale icon in menu bar
3. Check: `docker info`

### Issue: Port 5432 already in use
**Solution:**
```bash
# Stop system PostgreSQL
brew services stop postgresql

# Or edit docker-compose.yml to use different port
```

### Issue: Database initialization fails
**Solution:**
```bash
make local-down-clean
make local-up
sleep 10  # Wait for PostgreSQL to be ready
make local-db-init
```

### Issue: Permission denied on scripts
**Solution:**
```bash
chmod +x setup-macos.sh
chmod +x local-dev.sh
chmod +x test-local-setup.sh
```

### Issue: Node/Python version issues
**Solution:**
```bash
# Update Node.js
brew upgrade node@18

# Update Python
brew upgrade python@3.11
```

---

## 📚 Additional Resources

- **Complete Setup Guide:** [LOCAL_SETUP.md](LOCAL_SETUP.md)
- **Quick Reference:** [QUICKREF.md](QUICKREF.md)
- **Project Overview:** [README.md](README.md)
- **AWS Deployment:** [QUICKSTART.md](QUICKSTART.md)

---

## ☁️ Optional: AWS Deployment

Once local development is working, deploy to AWS:

### Prerequisites
- [ ] AWS account configured
- [ ] AWS CLI configured (`aws configure`)
- [ ] Terraform installed (done in setup)

### Deploy to AWS Dev Environment
```bash
cd infrastructure
make apply ENVIRONMENT=dev
```

See [QUICKSTART.md](QUICKSTART.md) for detailed AWS deployment instructions.

---

## ✅ Success Criteria

Your Mac mini is ready for LogLineOS development when:

- [x] All tests in `./test-local-setup.sh` pass
- [x] Can connect to PostgreSQL: `make local-db-shell`
- [x] Can view logs: `make local-logs`
- [x] Services show "Up (healthy)": `make local-ps`
- [x] Can access pgAdmin (optional): http://localhost:5050

**🎉 Congratulations! Your Mac mini is ready for LogLineOS development!**

---

## 📞 Support

Having issues? Check these resources:

1. Run diagnostics: `./test-local-setup.sh`
2. View logs: `make local-logs`
3. Check [LOCAL_SETUP.md](LOCAL_SETUP.md) troubleshooting section
4. Open an issue on GitHub

---

**Last Updated:** 2024  
**Version:** 1.0.0
