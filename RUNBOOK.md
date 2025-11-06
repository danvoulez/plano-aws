# LogLineOS Operational Runbook

This runbook provides step-by-step procedures for common operational tasks and incident response.

## Table of Contents
- [Health Checks](#health-checks)
- [Deployment](#deployment)
- [Incident Response](#incident-response)
- [Database Operations](#database-operations)
- [Rollback Procedures](#rollback-procedures)
- [Scaling](#scaling)
- [Monitoring](#monitoring)

## Health Checks

### System Health Check

```bash
# Check API Gateway health
curl https://your-api-gateway-url/health

# Expected response:
# {
#   "status": "healthy",
#   "timestamp": "2024-01-15T10:30:00.000Z",
#   "database": "connected",
#   "duration_ms": 45,
#   "environment": "production"
# }
```

### Lambda Function Health

```bash
# Check Lambda function status
aws lambda get-function --function-name loglineos-stage0-loader-production

# Check recent invocations
aws cloudwatch get-metric-statistics \
  --namespace AWS/Lambda \
  --metric-name Invocations \
  --dimensions Name=FunctionName,Value=loglineos-stage0-loader-production \
  --statistics Sum \
  --start-time $(date -u -d '1 hour ago' +%Y-%m-%dT%H:%M:%S) \
  --end-time $(date -u +%Y-%m-%dT%H:%M:%S) \
  --period 300
```

### Database Health

```bash
# Check RDS instance status
aws rds describe-db-instances \
  --db-instance-identifier loglineos-ledger-production

# Check database connections
aws cloudwatch get-metric-statistics \
  --namespace AWS/RDS \
  --metric-name DatabaseConnections \
  --dimensions Name=DBInstanceIdentifier,Value=loglineos-ledger-production \
  --statistics Average \
  --start-time $(date -u -d '15 minutes ago' +%Y-%m-%dT%H:%M:%S) \
  --end-time $(date -u +%Y-%m-%dT%H:%M:%S) \
  --period 300
```

## Deployment

### Standard Deployment Procedure

1. **Pre-deployment Checks**
   ```bash
   # Verify current environment
   cd infrastructure/terraform/environments/production
   terraform plan
   
   # Check for drift
   terraform plan -detailed-exitcode
   ```

2. **Deploy Infrastructure**
   ```bash
   # Apply Terraform changes
   terraform apply
   
   # Wait for completion
   # Note the outputs (API Gateway URL, Lambda ARNs, etc.)
   ```

3. **Run Database Migrations**
   ```bash
   # Invoke migration Lambda
   aws lambda invoke \
     --function-name loglineos-db-migration-production \
     --invocation-type RequestResponse \
     --payload '{}' \
     /tmp/migration-result.json
   
   # Check result
   cat /tmp/migration-result.json
   ```

4. **Post-deployment Verification**
   ```bash
   # Test health endpoint
   curl https://your-api-gateway-url/health
   
   # Create a test span
   curl -X POST https://your-api-gateway-url/spans \
     -H "Content-Type: application/json" \
     -H "X-User-Id: test-user" \
     -d '{
       "entity_type": "test",
       "who": "deployment-test",
       "this": "health-check",
       "name": "Deployment Test"
     }'
   
   # Verify span was created
   curl https://your-api-gateway-url/spans?entity_type=test&limit=1
   ```

5. **Monitor for Issues**
   ```bash
   # Watch CloudWatch Logs
   aws logs tail /aws/lambda/loglineos-stage0-loader-production --follow
   
   # Check for errors in the last 5 minutes
   aws logs filter-log-events \
     --log-group-name /aws/lambda/loglineos-stage0-loader-production \
     --start-time $(($(date +%s) - 300))000 \
     --filter-pattern "ERROR"
   ```

## Incident Response

### High Error Rate

**Symptoms:**
- CloudWatch alarm: `loglineos-stage0-errors`
- Increased 5XX responses from API Gateway

**Diagnosis:**
```bash
# Check recent errors
aws logs filter-log-events \
  --log-group-name /aws/lambda/loglineos-stage0-loader-production \
  --start-time $(($(date +%s) - 3600))000 \
  --filter-pattern "ERROR" \
  --limit 50

# Check Lambda metrics
aws cloudwatch get-metric-statistics \
  --namespace AWS/Lambda \
  --metric-name Errors \
  --dimensions Name=FunctionName,Value=loglineos-stage0-loader-production \
  --statistics Sum \
  --start-time $(date -u -d '1 hour ago' +%Y-%m-%dT%H:%M:%S) \
  --end-time $(date -u +%Y-%m-%dT%H:%M:%S) \
  --period 60
```

**Resolution Steps:**
1. Check for common error patterns (database connection, timeout, validation)
2. If database-related: Check RDS status and connections
3. If validation-related: Check for malformed requests
4. If timeout-related: Check Lambda timeout configuration and database query performance
5. Consider rollback if errors persist (see [Rollback Procedures](#rollback-procedures))

### Database Connection Issues

**Symptoms:**
- Error messages: "Database connection failed"
- Timeouts in Lambda execution

**Diagnosis:**
```bash
# Check RDS status
aws rds describe-db-instances \
  --db-instance-identifier loglineos-ledger-production \
  --query 'DBInstances[0].DBInstanceStatus'

# Check connection count
aws cloudwatch get-metric-statistics \
  --namespace AWS/RDS \
  --metric-name DatabaseConnections \
  --dimensions Name=DBInstanceIdentifier,Value=loglineos-ledger-production \
  --statistics Maximum,Average \
  --start-time $(date -u -d '1 hour ago' +%Y-%m-%dT%H:%M:%S) \
  --end-time $(date -u +%Y-%m-%dT%H:%M:%S) \
  --period 300

# Check CPU utilization
aws cloudwatch get-metric-statistics \
  --namespace AWS/RDS \
  --metric-name CPUUtilization \
  --dimensions Name=DBInstanceIdentifier,Value=loglineos-ledger-production \
  --statistics Maximum,Average \
  --start-time $(date -u -d '1 hour ago' +%Y-%m-%dT%H:%M:%S) \
  --end-time $(date -u +%Y-%m-%dT%H:%M:%S) \
  --period 300
```

**Resolution Steps:**
1. If connections are maxed out: Scale up RDS instance or implement connection pooling
2. If CPU is high: Optimize queries or scale up instance
3. If RDS is unavailable: Check for maintenance window or initiate failover
4. Temporary fix: Increase Lambda timeout (max 15 minutes)

### High Latency

**Symptoms:**
- CloudWatch alarm: `loglineos-stage0-duration`
- Slow API responses

**Diagnosis:**
```bash
# Check Lambda duration
aws cloudwatch get-metric-statistics \
  --namespace AWS/Lambda \
  --metric-name Duration \
  --dimensions Name=FunctionName,Value=loglineos-stage0-loader-production \
  --statistics Average,Maximum \
  --start-time $(date -u -d '1 hour ago' +%Y-%m-%dT%H:%M:%S) \
  --end-time $(date -u +%Y-%m-%dT%H:%M:%S) \
  --period 300

# Check database query latency
aws cloudwatch get-metric-statistics \
  --namespace AWS/RDS \
  --metric-name ReadLatency \
  --dimensions Name=DBInstanceIdentifier,Value=loglineos-ledger-production \
  --statistics Average,Maximum \
  --start-time $(date -u -d '1 hour ago' +%Y-%m-%dT%H:%M:%S) \
  --end-time $(date -u +%Y-%m-%dT%H:%M:%S) \
  --period 300
```

**Resolution Steps:**
1. Check database query plans for slow queries
2. Review and optimize indexes
3. Consider adding read replicas for read-heavy workloads
4. Enable ElastiCache for frequently accessed data
5. Review Lambda memory allocation (more memory = more CPU)

## Database Operations

### Manual Database Access

```bash
# Get database credentials
DB_SECRET=$(aws secretsmanager get-secret-value \
  --secret-id loglineos-db-production \
  --query SecretString --output text)

DB_HOST=$(echo $DB_SECRET | jq -r .host)
DB_USER=$(echo $DB_SECRET | jq -r .username)
DB_PASS=$(echo $DB_SECRET | jq -r .password)
DB_NAME=$(echo $DB_SECRET | jq -r .database)

# Connect via psql
PGPASSWORD=$DB_PASS psql -h $DB_HOST -U $DB_USER -d $DB_NAME
```

### Common Queries

```sql
-- Check span count by type
SELECT entity_type, COUNT(*) as count
FROM ledger.universal_registry
WHERE is_deleted = false
GROUP BY entity_type
ORDER BY count DESC;

-- Check recent activity
SELECT entity_type, who, did, status, at
FROM ledger.visible_timeline
ORDER BY at DESC
LIMIT 20;

-- Check failed executions
SELECT id, who, error, at
FROM ledger.visible_timeline
WHERE entity_type = 'execution'
  AND status = 'error'
ORDER BY at DESC
LIMIT 10;

-- Check quota usage by tenant
SELECT tenant_id, COUNT(*) as executions_today
FROM ledger.visible_timeline
WHERE entity_type = 'execution'
  AND at::date = CURRENT_DATE
GROUP BY tenant_id
ORDER BY executions_today DESC;
```

### Database Backup and Restore

```bash
# Create manual snapshot
aws rds create-db-snapshot \
  --db-instance-identifier loglineos-ledger-production \
  --db-snapshot-identifier loglineos-manual-snapshot-$(date +%Y%m%d-%H%M%S)

# List available snapshots
aws rds describe-db-snapshots \
  --db-instance-identifier loglineos-ledger-production

# Restore from snapshot (creates new instance)
aws rds restore-db-instance-from-db-snapshot \
  --db-instance-identifier loglineos-ledger-restored \
  --db-snapshot-identifier <snapshot-identifier>
```

## Rollback Procedures

### Lambda Function Rollback

```bash
# List function versions
aws lambda list-versions-by-function \
  --function-name loglineos-stage0-loader-production

# Rollback to previous version
PREVIOUS_VERSION=5  # Replace with actual version number
aws lambda update-alias \
  --function-name loglineos-stage0-loader-production \
  --name production \
  --function-version $PREVIOUS_VERSION

# Verify rollback
aws lambda get-alias \
  --function-name loglineos-stage0-loader-production \
  --name production
```

### Infrastructure Rollback

```bash
# Rollback Terraform to previous state
cd infrastructure/terraform/environments/production

# Review state history
terraform state list

# Rollback (careful - destructive)
# Option 1: Use version control
git log --oneline
git checkout <previous-commit-hash>
terraform apply

# Option 2: Use Terraform state
terraform state pull > backup.tfstate
# Edit state or restore from backup
terraform state push backup.tfstate
terraform apply
```

### Database Schema Rollback

⚠️ **WARNING**: Database rollbacks are complex due to append-only architecture.

```bash
# For critical issues, contact DBA or follow these steps:

# 1. Create a backup first
aws rds create-db-snapshot \
  --db-instance-identifier loglineos-ledger-production \
  --db-snapshot-identifier emergency-rollback-$(date +%Y%m%d-%H%M%S)

# 2. Mark problematic spans as deleted (soft delete)
# Connect to database and run:
# UPDATE ledger.universal_registry SET is_deleted = true WHERE id IN (...);

# 3. If full rollback needed, restore from snapshot
# (This creates a new instance, requires DNS/connection updates)
```

## Scaling

### Vertical Scaling (RDS)

```bash
# Modify RDS instance class
aws rds modify-db-instance \
  --db-instance-identifier loglineos-ledger-production \
  --db-instance-class db.r6g.2xlarge \
  --apply-immediately  # Or use during maintenance window
```

### Horizontal Scaling (Read Replicas)

```bash
# Create read replica
aws rds create-db-instance-read-replica \
  --db-instance-identifier loglineos-ledger-read-replica-1 \
  --source-db-instance-identifier loglineos-ledger-production \
  --db-instance-class db.r6g.xlarge \
  --availability-zone us-east-1b
```

### Lambda Scaling

Lambda scales automatically, but you can adjust:

```bash
# Increase reserved concurrency
aws lambda put-function-concurrency \
  --function-name loglineos-stage0-loader-production \
  --reserved-concurrent-executions 100

# Increase memory (also increases CPU)
aws lambda update-function-configuration \
  --function-name loglineos-stage0-loader-production \
  --memory-size 2048
```

## Monitoring

### View CloudWatch Dashboard

```bash
# Open dashboard in browser
echo "https://console.aws.amazon.com/cloudwatch/home?region=us-east-1#dashboards:name=loglineos-production-dashboard"

# Or use AWS CLI to get dashboard widgets
aws cloudwatch get-dashboard \
  --dashboard-name loglineos-production-dashboard
```

### Check Alarms

```bash
# List all alarms
aws cloudwatch describe-alarms \
  --alarm-name-prefix loglineos-production

# Check alarm state
aws cloudwatch describe-alarms \
  --state-value ALARM
```

### Custom Metrics

```bash
# Publish custom metric
aws cloudwatch put-metric-data \
  --namespace LogLineOS/Production \
  --metric-name CustomMetric \
  --value 1.0 \
  --timestamp $(date -u +%Y-%m-%dT%H:%M:%S)
```

## Emergency Contacts

- **On-Call Engineer**: [Contact info]
- **Database Administrator**: [Contact info]
- **AWS Support**: [Support plan level and contact method]
- **Incident Commander**: [Contact info]

## Additional Resources

- [Production Readiness Checklist](PRODUCTION_READINESS.md)
- [Deployment Checklist](DEPLOYMENT_CHECKLIST.md)
- [Blueprint4 Specification](Blueprint4.md)
- [AWS Architecture](plano-aws.md)
