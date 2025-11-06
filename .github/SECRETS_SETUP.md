# GitHub Secrets Setup Guide

This guide explains how to configure GitHub Secrets for full CI/CD automation.

## Prerequisites

- GitHub repository admin access
- AWS Account(s) for dev, staging, and/or production
- AWS IAM credentials with appropriate permissions

## Required Secrets

### Development Environment

| Secret Name | Description | Required |
|-------------|-------------|----------|
| `AWS_ACCESS_KEY_ID_DEV` | AWS access key for dev environment | ✅ Yes |
| `AWS_SECRET_ACCESS_KEY_DEV` | AWS secret key for dev environment | ✅ Yes |

### Staging Environment (Optional)

| Secret Name | Description | Required |
|-------------|-------------|----------|
| `AWS_ACCESS_KEY_ID_STAGING` | AWS access key for staging environment | For staging deploys |
| `AWS_SECRET_ACCESS_KEY_STAGING` | AWS secret key for staging environment | For staging deploys |

### Production Environment (Optional)

| Secret Name | Description | Required |
|-------------|-------------|----------|
| `AWS_ACCESS_KEY_ID_PROD` | AWS access key for production environment | For production deploys |
| `AWS_SECRET_ACCESS_KEY_PROD` | AWS secret key for production environment | For production deploys |

## Step-by-Step Setup

### 1. Create AWS IAM Users

For each environment (dev, staging, production), create an IAM user with programmatic access:

```bash
# Example for dev environment
aws iam create-user --user-name loglineos-ci-dev

# Create access key
aws iam create-access-key --user-name loglineos-ci-dev
```

**Save the Access Key ID and Secret Access Key** - you won't be able to retrieve the secret key again.

### 2. Attach IAM Policies

Attach the necessary permissions to each IAM user. For full deployment capabilities:

```bash
# Attach AdministratorAccess (for initial setup)
aws iam attach-user-policy \
  --user-name loglineos-ci-dev \
  --policy-arn arn:aws:iam::aws:policy/AdministratorAccess
```

**⚠️ Security Note:** For production, use least-privilege policies. See [Recommended IAM Policies](#recommended-iam-policies) below.

### 3. Add Secrets to GitHub

#### Via GitHub Web UI

1. Go to your repository on GitHub
2. Click **Settings** → **Secrets and variables** → **Actions**
3. Click **New repository secret**
4. For each secret:
   - **Name:** Enter the exact secret name (e.g., `AWS_ACCESS_KEY_ID_DEV`)
   - **Value:** Paste the corresponding AWS credential
   - Click **Add secret**

#### Via GitHub CLI

```bash
# Install GitHub CLI if not already installed
# macOS: brew install gh
# Linux: see https://github.com/cli/cli#installation

# Authenticate
gh auth login

# Add secrets
gh secret set AWS_ACCESS_KEY_ID_DEV
# Paste the access key when prompted

gh secret set AWS_SECRET_ACCESS_KEY_DEV
# Paste the secret key when prompted

# Repeat for staging and production
gh secret set AWS_ACCESS_KEY_ID_STAGING
gh secret set AWS_SECRET_ACCESS_KEY_STAGING

gh secret set AWS_ACCESS_KEY_ID_PROD
gh secret set AWS_SECRET_ACCESS_KEY_PROD
```

### 4. Verify Secrets

Check that secrets are configured:

```bash
gh secret list
```

Expected output:
```
AWS_ACCESS_KEY_ID_DEV         Updated 2024-XX-XX
AWS_SECRET_ACCESS_KEY_DEV     Updated 2024-XX-XX
AWS_ACCESS_KEY_ID_STAGING     Updated 2024-XX-XX
AWS_SECRET_ACCESS_KEY_STAGING Updated 2024-XX-XX
AWS_ACCESS_KEY_ID_PROD        Updated 2024-XX-XX
AWS_SECRET_ACCESS_KEY_PROD    Updated 2024-XX-XX
```

## Recommended IAM Policies

For production environments, use least-privilege policies instead of AdministratorAccess.

### Minimum Required Permissions

```json
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Effect": "Allow",
      "Action": [
        "s3:*",
        "dynamodb:*",
        "lambda:*",
        "apigateway:*",
        "rds:*",
        "ec2:*",
        "iam:*",
        "logs:*",
        "cloudwatch:*",
        "events:*",
        "secretsmanager:*",
        "kms:*",
        "states:*"
      ],
      "Resource": "*"
    }
  ]
}
```

### Terraform State Management Permissions

```json
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Effect": "Allow",
      "Action": [
        "s3:ListBucket",
        "s3:GetBucketVersioning"
      ],
      "Resource": "arn:aws:s3:::loglineos-terraform-state-*"
    },
    {
      "Effect": "Allow",
      "Action": [
        "s3:GetObject",
        "s3:PutObject"
      ],
      "Resource": "arn:aws:s3:::loglineos-terraform-state-*/*"
    },
    {
      "Effect": "Allow",
      "Action": [
        "dynamodb:GetItem",
        "dynamodb:PutItem",
        "dynamodb:DeleteItem"
      ],
      "Resource": "arn:aws:dynamodb:*:*:table/terraform-locks"
    }
  ]
}
```

## Environment Protection Rules

### Configure GitHub Environments

For production deployments, set up environment protection:

1. Go to **Settings** → **Environments**
2. Click **New environment**
3. Name it `production`
4. Configure protection rules:
   - ✅ **Required reviewers**: Add team members who must approve
   - ✅ **Wait timer**: Optional delay before deployment
   - ✅ **Deployment branches**: Limit to specific branches/tags

### Example Configuration

```yaml
# production environment
Required reviewers: @tech-lead, @devops-team
Wait timer: 0 minutes
Deployment branches: Only protected branches and tags
```

## Testing the Setup

After configuring secrets, test the automation:

### 1. Test CI Workflow

```bash
# Create a test branch
git checkout -b test/ci-setup

# Make a small change
echo "# Test" >> README.md
git add README.md
git commit -m "test: CI workflow"

# Push and create PR
git push origin test/ci-setup
# Create PR on GitHub
```

The CI workflow should run automatically and show:
- ✅ Lint and test checks
- ✅ Security scans
- ✅ Terraform validation

### 2. Test Dev Deployment

```bash
# Merge to main or push directly
git checkout main
git pull
echo "# Test deployment" >> README.md
git add README.md
git commit -m "test: dev deployment"
git push origin main
```

Check GitHub Actions for:
- ✅ Deployment workflow triggered
- ✅ AWS credentials working
- ✅ Terraform applying successfully

### 3. Test Staging Deployment

```bash
# Create and push a tag
git tag -a v0.0.1-test -m "Test staging deployment"
git push origin v0.0.1-test
```

Check GitHub Actions for staging deployment.

### 4. Test Production Deployment

1. Go to **Actions** → **CD - Deploy to AWS**
2. Click **Run workflow**
3. Select `production` environment
4. Click **Run workflow**
5. Approve the deployment when prompted

## Troubleshooting

### Secret Not Found Error

```
Error: The secret `AWS_ACCESS_KEY_ID_DEV` was not found
```

**Solution:** Verify secret name exactly matches (case-sensitive):
```bash
gh secret list
```

### AWS Authentication Failed

```
Error: Unable to locate credentials
```

**Solutions:**
1. Verify AWS credentials are valid:
   ```bash
   # Locally test credentials
   AWS_ACCESS_KEY_ID=xxx AWS_SECRET_ACCESS_KEY=yyy aws sts get-caller-identity
   ```
2. Check IAM user has necessary permissions
3. Verify secrets are set in the correct environment

### Permission Denied Errors

```
Error: User: arn:aws:iam::xxx:user/loglineos-ci-dev is not authorized to perform: xxx
```

**Solution:** Update IAM policies to include the missing permissions.

## Security Best Practices

### 1. Rotate Credentials Regularly

```bash
# Create new access key
aws iam create-access-key --user-name loglineos-ci-dev

# Update GitHub secret with new key
gh secret set AWS_ACCESS_KEY_ID_DEV

# Delete old access key (after verifying new one works)
aws iam delete-access-key \
  --user-name loglineos-ci-dev \
  --access-key-id OLD_ACCESS_KEY_ID
```

### 2. Use Different AWS Accounts

For maximum isolation:
- Dev environment → AWS Account A
- Staging environment → AWS Account B  
- Production environment → AWS Account C

### 3. Enable MFA for Production

For production IAM users:
```bash
aws iam enable-mfa-device \
  --user-name loglineos-ci-prod \
  --serial-number arn:aws:iam::ACCOUNT:mfa/loglineos-ci-prod \
  --authentication-code1 123456 \
  --authentication-code2 789012
```

### 4. Audit Access

Regularly review:
```bash
# List access keys
aws iam list-access-keys --user-name loglineos-ci-dev

# Check last usage
aws iam get-access-key-last-used --access-key-id ACCESS_KEY_ID

# Review CloudTrail logs
aws cloudtrail lookup-events \
  --lookup-attributes AttributeKey=Username,AttributeValue=loglineos-ci-dev
```

## Additional Resources

- [GitHub Actions Secrets Documentation](https://docs.github.com/en/actions/security-guides/encrypted-secrets)
- [AWS IAM Best Practices](https://docs.aws.amazon.com/IAM/latest/UserGuide/best-practices.html)
- [GitHub Environments Documentation](https://docs.github.com/en/actions/deployment/targeting-different-environments/using-environments-for-deployment)

## Quick Reference

```bash
# List secrets
gh secret list

# Add a secret
gh secret set SECRET_NAME

# Delete a secret
gh secret delete SECRET_NAME

# View workflow runs
gh run list

# View specific workflow run
gh run view RUN_ID
```

## Support

For issues:
1. Check GitHub Actions logs
2. Review AWS CloudTrail for permission issues
3. Verify secrets are correctly configured
4. Open an issue in the repository

---

**Last Updated:** 2024  
**Version:** 1.0.0
