# LogLineOS Automation Quick Reference

## 🚀 One-Command Setup

```bash
./complete-setup.sh
```

## 🔄 Automated Workflows

### CI/CD Pipeline

| Event | Workflow | Action |
|-------|----------|--------|
| Pull Request | `ci.yml` | Lint, test, security scan |
| Push to `main` | `deploy.yml` | Deploy to dev |
| Create tag `v*` | `deploy.yml` | Deploy to staging |
| Manual trigger | `deploy.yml` | Deploy to production (with approval) |

### Maintenance Tasks

| Schedule | Workflow | Tasks |
|----------|----------|-------|
| Daily 6 AM UTC | `maintenance.yml` | Health checks, backups, cost monitoring |
| Weekly Mon 2 AM | `maintenance.yml` | Security scans, dependency updates |
| After deployment | `auto-rollback.yml` | Check health, rollback if needed |
| Weekly Mon 2 AM | Dependabot | Create PRs for dependency updates |

## 📋 Common Commands

### Trigger Deployments

```bash
# Deploy to dev (automatic)
git push origin main

# Deploy to staging (automatic)
git tag -a v1.0.0 -m "Release v1.0.0"
git push origin v1.0.0

# Deploy to production (manual approval)
# Go to GitHub Actions → "CD - Deploy to AWS" → Run workflow
```

### Manual Maintenance

```bash
# Via GitHub Actions UI:
# Actions → "Automated Maintenance" → Run workflow
# Select: health-check, backup, security-scan, dependency-update, or all
```

### Verify Automation Setup

```bash
./verify-automation.sh
```

## 🔐 Required Secrets

| Secret Name | Used For |
|-------------|----------|
| `AWS_ACCESS_KEY_ID_DEV` | Dev deployments |
| `AWS_SECRET_ACCESS_KEY_DEV` | Dev deployments |
| `AWS_ACCESS_KEY_ID_STAGING` | Staging deployments |
| `AWS_SECRET_ACCESS_KEY_STAGING` | Staging deployments |
| `AWS_ACCESS_KEY_ID_PROD` | Production deployments |
| `AWS_SECRET_ACCESS_KEY_PROD` | Production deployments |

See `.github/SECRETS_SETUP.md` for setup instructions.

## 📊 Monitoring

### View Workflow Status

```bash
# Via GitHub CLI
gh run list
gh run view <run-id>

# Via web
https://github.com/danvoulez/plano-aws/actions
```

### Check System Health

Automated daily at 6 AM UTC. Results posted as GitHub issues if problems detected.

## 🔧 Customization

### Change Schedules

Edit `.github/workflows/maintenance.yml`:

```yaml
on:
  schedule:
    - cron: '0 6 * * *'  # Daily at 6 AM UTC
    - cron: '0 2 * * 1'  # Weekly Monday at 2 AM UTC
```

### Adjust Error Thresholds

Edit `.github/workflows/auto-rollback.yml`:

```yaml
if [ $(echo "$ERRORS > 10" | bc -l) -eq 1 ]; then
  # Change threshold as needed
```

### Update Dependencies

Dependabot runs weekly. To run manually:

```bash
# Via GitHub Actions UI:
# Actions → "Automated Maintenance" → Run workflow
# Select: dependency-update
```

## 🆘 Troubleshooting

### Workflow Fails with Auth Error

1. Check GitHub Secrets are set correctly
2. Verify AWS credentials are valid:
   ```bash
   aws sts get-caller-identity
   ```
3. Check IAM permissions

### Deployment Stuck

1. Check workflow logs in GitHub Actions
2. Check AWS CloudFormation/Terraform state
3. Manual intervention may be needed

### Auto-Rollback Triggered

1. Check the created GitHub issue for details
2. Review deployment logs
3. Investigate error patterns
4. Fix and redeploy

## 📚 Documentation

- **[AUTOMATION.md](AUTOMATION.md)** - Complete automation guide
- **[.github/SECRETS_SETUP.md](.github/SECRETS_SETUP.md)** - GitHub Secrets setup
- **[RUNBOOK.md](RUNBOOK.md)** - Operations runbook
- **[README.md](README.md)** - Project overview

## 🎯 Automation Checklist

Before enabling full automation:

- [ ] Configure GitHub Secrets (AWS credentials)
- [ ] Set up production environment protection
- [ ] Enable Dependabot alerts
- [ ] Test dev deployment
- [ ] Test staging deployment
- [ ] Review CloudWatch alarms
- [ ] Configure notification channels

## ⚡ Quick Start Checklist

- [ ] Run `./complete-setup.sh` for local setup
- [ ] Configure GitHub Secrets
- [ ] Push to main → verify dev deployment works
- [ ] Create tag → verify staging deployment works
- [ ] Set up production environment protection
- [ ] Enable all automation workflows

---

**For detailed information, see [AUTOMATION.md](AUTOMATION.md)**
