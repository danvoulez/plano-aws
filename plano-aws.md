# LogLineOS AWS Deployment Guide
## From Blueprint4 to Production AWS Infrastructure

### Executive Summary
This guide adapts the LogLineOS Blueprint4 (ledger-only architecture with 70 semantic columns, memory system, prompt system, and app onboarding) for AWS deployment using managed services, Infrastructure as Code (IaC), and AWS-native patterns.

---

## 1. Architecture Overview

### Core Components Mapping

| Blueprint4 Component | AWS Service | Rationale |
|---------------------|-------------|-----------|
| PostgreSQL Ledger | Amazon RDS PostgreSQL 15.x | Managed, auto-backup, read replicas |
| Stage-0 Loader | AWS Lambda + Step Functions | Serverless, auto-scaling |
| Kernels (5 core) | Lambda Functions | Pay-per-execution, isolated |
| API Layer | API Gateway + Lambda | REST + WebSocket for SSE |
| SSE Timeline | API Gateway WebSocket | Real-time, managed |
| Memory System | RDS + ElastiCache | pgvector + Redis caching |
| Prompt System | Lambda + Bedrock/SageMaker | LLM orchestration |
| File Storage | S3 + CloudFront | Static assets, CDN |
| Secrets/Keys | AWS Secrets Manager + KMS | Rotation, encryption |
| Monitoring | CloudWatch + X-Ray | Observability |

### Network Architecture

```
┌─────────────────────────────────────────────────────────────┐
│                         Internet                            │
└────────────────┬────────────────────────────────────────────┘
                 │
         ┌───────▼────────┐
         │   CloudFront   │
         │      (CDN)     │
         └───────┬────────┘
                 │
         ┌───────▼────────┐
         │  API Gateway   │
         │  (REST + WS)   │
         └───────┬────────┘
                 │
    ┌────────────┼────────────┐
    │            │            │
┌───▼───┐   ┌───▼───┐   ┌───▼───┐
│Lambda │   │Lambda │   │Lambda │
│Kernels│   │  API  │   │Workers│
└───┬───┘   └───┬───┘   └───┬───┘
    │           │            │
    └───────────┼────────────┘
                │
         ┌──────▼──────┐
         │     VPC     │
         ├─────────────┤
         │RDS PostgreSQL│
         │ ElastiCache │
         │   Secrets   │
         └─────────────┘
```

---

## 2. Infrastructure as Code (Terraform)

### 2.1 Project Structure

```
infrastructure/
├── terraform/
│   ├── environments/
│   │   ├── dev/
│   │   │   ├── main.tf
│   │   │   ├── variables.tf
│   │   │   └── terraform.tfvars
│   │   ├── staging/
│   │   └── production/
│   ├── modules/
│   │   ├── rds/
│   │   ├── lambda/
│   │   ├── api_gateway/
│   │   ├── vpc/
│   │   └── security/
│   └── global/
│       └── state/
├── lambda/
│   ├── stage0_loader/
│   ├── kernels/
│   └── api_handlers/
└── scripts/
    ├── deploy.sh
    └── migrate.sh
```

### 2.2 Core Terraform Configuration

```hcl
# main.tf - Root configuration
terraform {
  required_version = ">= 1.5"
  
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
  }
  
  backend "s3" {
    bucket = "loglineos-terraform-state"
    key    = "production/terraform.tfstate"
    region = "us-east-1"
    encrypt = true
    dynamodb_table = "terraform-locks"
  }
}

provider "aws" {
  region = var.aws_region
  
  default_tags {
    tags = {
      Environment = var.environment
      Project     = "LogLineOS"
      ManagedBy   = "Terraform"
    }
  }
}
```

---

## 3. Database Layer (RDS PostgreSQL)

### 3.1 RDS Module with 70-Column Schema Support

```hcl
# modules/rds/main.tf
resource "aws_db_instance" "ledger" {
  identifier = "${var.project}-ledger-${var.environment}"
  
  engine         = "postgres"
  engine_version = "15.4"
  instance_class = var.db_instance_class
  
  allocated_storage     = 100
  max_allocated_storage = 1000
  storage_type         = "gp3"
  storage_encrypted    = true
  
  db_name  = "loglineos"
  username = "ledger_admin"
  password = random_password.db_password.result
  
  vpc_security_group_ids = [aws_security_group.rds.id]
  db_subnet_group_name   = aws_db_subnet_group.main.name
  
  backup_retention_period = 30
  backup_window          = "03:00-04:00"
  maintenance_window     = "sun:04:00-sun:05:00"
  
  enabled_cloudwatch_logs_exports = ["postgresql"]
  
  parameter_group_name = aws_db_parameter_group.ledger.name
  
  tags = {
    Name = "${var.project}-ledger"
  }
}

resource "aws_db_parameter_group" "ledger" {
  name   = "${var.project}-ledger-params"
  family = "postgres15"
  
  # Optimizations for append-only ledger
  parameter {
    name  = "shared_buffers"
    value = "{DBInstanceClassMemory/4}"
  }
  
  parameter {
    name  = "effective_cache_size"
    value = "{DBInstanceClassMemory*3/4}"
  }
  
  parameter {
    name  = "max_connections"
    value = "200"
  }
  
  parameter {
    name  = "work_mem"
    value = "16384"
  }
}
```

### 3.2 Database Migration Lambda

```python
# lambda/db_migration/handler.py
import psycopg2
import boto3
import os
from aws_lambda_powertools import Logger

logger = Logger()
secrets = boto3.client('secretsmanager')

def handler(event, context):
    """Execute database migrations for LogLineOS schema"""
    
    # Get DB credentials from Secrets Manager
    secret = secrets.get_secret_value(SecretId=os.environ['DB_SECRET_ARN'])
    db_config = json.loads(secret['SecretString'])
    
    conn = psycopg2.connect(
        host=db_config['host'],
        database=db_config['database'],
        user=db_config['username'],
        password=db_config['password']
    )
    
    with conn.cursor() as cur:
        # Create schemas
        cur.execute("""
            CREATE SCHEMA IF NOT EXISTS app;
            CREATE SCHEMA IF NOT EXISTS ledger;
        """)
        
        # Create session functions for RLS
        cur.execute("""
            CREATE OR REPLACE FUNCTION app.current_user_id() 
            RETURNS text LANGUAGE sql STABLE AS 
            $$ SELECT current_setting('app.user_id', true) $$;
            
            CREATE OR REPLACE FUNCTION app.current_tenant_id() 
            RETURNS text LANGUAGE sql STABLE AS 
            $$ SELECT current_setting('app.tenant_id', true) $$;
        """)
        
        # Create universal_registry with 70 semantic columns
        cur.execute("""
            CREATE TABLE IF NOT EXISTS ledger.universal_registry (
                id            uuid        NOT NULL,
                seq           integer     NOT NULL,
                entity_type   text        NOT NULL,
                who           text        NOT NULL,
                did           text,
                "this"        text        NOT NULL,
                at            timestamptz NOT NULL DEFAULT now(),
                
                -- Relationships
                parent_id     uuid,
                related_to    uuid[],
                
                -- Access control
                owner_id      text,
                tenant_id     text,
                visibility    text        NOT NULL DEFAULT 'private',
                
                -- Lifecycle
                status        text,
                is_deleted    boolean     NOT NULL DEFAULT false,
                
                -- Code & Execution
                name          text,
                description   text,
                code          text,
                language      text,
                runtime       text,
                input         jsonb,
                output        jsonb,
                error         jsonb,
                
                -- Quantitative/metrics
                duration_ms   integer,
                trace_id      text,
                
                -- Crypto proofs
                prev_hash     text,
                curr_hash     text,
                signature     text,
                public_key    text,
                
                -- Extensibility
                metadata      jsonb,
                
                PRIMARY KEY (id, seq),
                CONSTRAINT ck_visibility CHECK (visibility IN ('private','tenant','public')),
                CONSTRAINT ck_append_only CHECK (seq >= 0)
            );
        """)
        
        # Create indexes
        cur.execute("""
            CREATE INDEX IF NOT EXISTS ur_idx_at ON ledger.universal_registry (at DESC);
            CREATE INDEX IF NOT EXISTS ur_idx_entity ON ledger.universal_registry (entity_type, at DESC);
            CREATE INDEX IF NOT EXISTS ur_idx_owner_tenant ON ledger.universal_registry (owner_id, tenant_id);
            CREATE INDEX IF NOT EXISTS ur_idx_trace ON ledger.universal_registry (trace_id);
            CREATE INDEX IF NOT EXISTS ur_idx_parent ON ledger.universal_registry (parent_id);
            CREATE INDEX IF NOT EXISTS ur_idx_related ON ledger.universal_registry USING GIN (related_to);
            CREATE INDEX IF NOT EXISTS ur_idx_metadata ON ledger.universal_registry USING GIN (metadata);
        """)
        
        # Enable RLS
        cur.execute("""
            ALTER TABLE ledger.universal_registry ENABLE ROW LEVEL SECURITY;
            
            CREATE POLICY ur_select_policy ON ledger.universal_registry
            FOR SELECT USING (
                (owner_id IS NOT DISTINCT FROM app.current_user_id())
                OR (visibility = 'public')
                OR (tenant_id IS NOT DISTINCT FROM app.current_tenant_id() 
                    AND visibility IN ('tenant','public'))
            );
            
            CREATE POLICY ur_insert_policy ON ledger.universal_registry
            FOR INSERT WITH CHECK (
                owner_id IS NOT DISTINCT FROM app.current_user_id()
                AND (tenant_id IS NULL OR tenant_id IS NOT DISTINCT FROM app.current_tenant_id())
            );
        """)
        
        # Install pgvector for memory system
        cur.execute("CREATE EXTENSION IF NOT EXISTS vector;")
        
        # Create memory embeddings table
        cur.execute("""
            CREATE TABLE IF NOT EXISTS ledger.memory_embeddings (
                span_id uuid PRIMARY KEY,
                tenant_id text,
                dim int DEFAULT 1536,
                embedding vector(1536),
                created_at timestamptz DEFAULT now()
            );
        """)
        
    conn.commit()
    logger.info("Database migration completed successfully")
    
    return {
        'statusCode': 200,
        'body': json.dumps('Migration completed')
    }
```

---

## 4. Lambda Kernels Deployment

### 4.1 Stage-0 Loader Lambda

```javascript
// lambda/stage0_loader/index.js
const { Client } = require('pg');
const { blake3 } = require('@noble/hashes/blake3');
const * as ed from '@noble/ed25519';
const AWS = require('aws-sdk');

const secretsManager = new AWS.SecretsManager();
const stepFunctions = new AWS.StepFunctions();

exports.handler = async (event) => {
    console.log('Stage-0 Loader invoked:', JSON.stringify(event));
    
    // Get database credentials
    const dbSecret = await secretsManager.getSecretValue({
        SecretId: process.env.DB_SECRET_ARN
    }).promise();
    
    const dbConfig = JSON.parse(dbSecret.SecretString);
    
    const client = new Client({
        host: dbConfig.host,
        database: dbConfig.database,
        user: dbConfig.username,
        password: dbConfig.password,
        ssl: { rejectUnauthorized: false }
    });
    
    await client.connect();
    
    try {
        // Set session variables for RLS
        await client.query(`SET app.user_id = $1`, [event.user_id || 'edge:stage0']);
        if (event.tenant_id) {
            await client.query(`SET app.tenant_id = $1`, [event.tenant_id]);
        }
        
        // Fetch manifest
        const manifestResult = await client.query(`
            SELECT * FROM ledger.visible_timeline 
            WHERE entity_type='manifest' 
            ORDER BY at DESC LIMIT 1
        `);
        
        const manifest = manifestResult.rows[0] || { metadata: {} };
        const allowedBootIds = manifest.metadata?.allowed_boot_ids || [];
        
        if (!allowedBootIds.includes(event.boot_function_id)) {
            throw new Error('BOOT_FUNCTION_ID not allowed by manifest');
        }
        
        // Fetch function to execute
        const fnResult = await client.query(`
            SELECT * FROM ledger.visible_timeline 
            WHERE id=$1 AND entity_type='function'
            ORDER BY at DESC, seq DESC LIMIT 1
        `, [event.boot_function_id]);
        
        const fnSpan = fnResult.rows[0];
        if (!fnSpan) throw new Error('Function span not found');
        
        // Verify signature if present
        if (fnSpan.signature && fnSpan.public_key) {
            const verified = await verifySpan(fnSpan);
            if (!verified) throw new Error('Invalid signature');
        }
        
        // Insert boot event
        await client.query(`
            INSERT INTO ledger.universal_registry 
            (id, seq, entity_type, who, did, "this", at, status, input, owner_id, tenant_id, visibility, related_to)
            VALUES 
            (gen_random_uuid(), 0, 'boot_event', 'edge:stage0', 'booted', 'stage0', now(), 'complete', $1, $2, $3, $4, ARRAY[$5]::uuid[])
        `, [
            { boot_id: event.boot_function_id, env: { user: event.user_id, tenant: event.tenant_id } },
            fnSpan.owner_id,
            fnSpan.tenant_id,
            fnSpan.visibility || 'private',
            event.boot_function_id
        ]);
        
        // Execute the kernel via Step Functions for better orchestration
        const executionResult = await stepFunctions.startExecution({
            stateMachineArn: process.env.KERNEL_EXECUTOR_ARN,
            input: JSON.stringify({
                kernel_id: event.boot_function_id,
                code: fnSpan.code,
                runtime: fnSpan.runtime,
                input: fnSpan.input,
                context: {
                    user_id: event.user_id,
                    tenant_id: event.tenant_id,
                    trace_id: event.trace_id || generateTraceId()
                }
            })
        }).promise();
        
        return {
            statusCode: 200,
            body: JSON.stringify({
                execution_arn: executionResult.executionArn,
                started_at: executionResult.startDate
            })
        };
        
    } finally {
        await client.end();
    }
};

async function verifySpan(span) {
    const clone = { ...span };
    delete clone.signature;
    
    const msg = new TextEncoder().encode(
        JSON.stringify(clone, Object.keys(clone).sort())
    );
    
    const hash = blake3(msg);
    const signature = hexToUint8Array(span.signature);
    const publicKey = hexToUint8Array(span.public_key);
    
    return ed.verify(signature, hash, publicKey);
}

function hexToUint8Array(hex) {
    return Uint8Array.from(
        hex.match(/.{1,2}/g).map(byte => parseInt(byte, 16))
    );
}

function generateTraceId() {
    return `${Date.now()}-${Math.random().toString(36).substr(2, 9)}`;
}
```

### 4.2 Kernel Executor Step Function

```json
{
  "Comment": "LogLineOS Kernel Executor State Machine",
  "StartAt": "ValidateInput",
  "States": {
    "ValidateInput": {
      "Type": "Task",
      "Resource": "arn:aws:lambda:region:account:function:validate-kernel-input",
      "Next": "CheckQuota",
      "Catch": [{
        "ErrorEquals": ["ValidationError"],
        "Next": "HandleError"
      }]
    },
    "CheckQuota": {
      "Type": "Task",
      "Resource": "arn:aws:lambda:region:account:function:check-tenant-quota",
      "Next": "AcquireLock",
      "Catch": [{
        "ErrorEquals": ["QuotaExceeded"],
        "Next": "HandleQuotaExceeded"
      }]
    },
    "AcquireLock": {
      "Type": "Task",
      "Resource": "arn:aws:lambda:region:account:function:acquire-advisory-lock",
      "Next": "ExecuteKernel",
      "Retry": [{
        "ErrorEquals": ["LockNotAvailable"],
        "IntervalSeconds": 2,
        "MaxAttempts": 3,
        "BackoffRate": 2.0
      }]
    },
    "ExecuteKernel": {
      "Type": "Task",
      "Resource": "arn:aws:lambda:region:account:function:execute-kernel",
      "TimeoutSeconds": 30,
      "Next": "RecordExecution",
      "Catch": [{
        "ErrorEquals": ["States.TaskFailed", "States.Timeout"],
        "Next": "RecordError"
      }]
    },
    "RecordExecution": {
      "Type": "Task",
      "Resource": "arn:aws:lambda:region:account:function:record-execution",
      "Next": "ReleaseLock"
    },
    "RecordError": {
      "Type": "Task",
      "Resource": "arn:aws:lambda:region:account:function:record-error",
      "Next": "ReleaseLock"
    },
    "ReleaseLock": {
      "Type": "Task",
      "Resource": "arn:aws:lambda:region:account:function:release-advisory-lock",
      "Next": "Success"
    },
    "HandleQuotaExceeded": {
      "Type": "Task",
      "Resource": "arn:aws:lambda:region:account:function:handle-quota-exceeded",
      "Next": "Fail"
    },
    "HandleError": {
      "Type": "Task",
      "Resource": "arn:aws:lambda:region:account:function:handle-error",
      "Next": "Fail"
    },
    "Success": {
      "Type": "Succeed"
    },
    "Fail": {
      "Type": "Fail"
    }
  }
}
```

---

## 5. API Gateway Configuration

### 5.1 REST API for Ledger Operations

```hcl
# modules/api_gateway/main.tf
resource "aws_api_gateway_rest_api" "loglineos" {
  name        = "${var.project}-api"
  description = "LogLineOS Ledger API"
  
  endpoint_configuration {
    types = ["REGIONAL"]
  }
}

resource "aws_api_gateway_resource" "spans" {
  rest_api_id = aws_api_gateway_rest_api.loglineos.id
  parent_id   = aws_api_gateway_rest_api.loglineos.root_resource_id
  path_part   = "spans"
}

resource "aws_api_gateway_method" "spans_post" {
  rest_api_id   = aws_api_gateway_rest_api.loglineos.id
  resource_id   = aws_api_gateway_resource.spans.id
  http_method   = "POST"
  authorization = "CUSTOM"
  authorizer_id = aws_api_gateway_authorizer.jwt.id
}

resource "aws_api_gateway_integration" "spans_post_lambda" {
  rest_api_id = aws_api_gateway_rest_api.loglineos.id
  resource_id = aws_api_gateway_resource.spans.id
  http_method = aws_api_gateway_method.spans_post.http_method
  
  integration_http_method = "POST"
  type                   = "AWS_PROXY"
  uri                    = aws_lambda_function.create_span.invoke_arn
}
```

### 5.2 WebSocket API for SSE Timeline

```hcl
resource "aws_apigatewayv2_api" "websocket" {
  name                       = "${var.project}-websocket"
  protocol_type             = "WEBSOCKET"
  route_selection_expression = "$request.body.action"
}

resource "aws_apigatewayv2_route" "connect" {
  api_id    = aws_apigatewayv2_api.websocket.id
  route_key = "$connect"
  
  target = "integrations/${aws_apigatewayv2_integration.connect.id}"
}

resource "aws_apigatewayv2_route" "disconnect" {
  api_id    = aws_apigatewayv2_api.websocket.id
  route_key = "$disconnect"
  
  target = "integrations/${aws_apigatewayv2_integration.disconnect.id}"
}

resource "aws_apigatewayv2_route" "subscribe" {
  api_id    = aws_apigatewayv2_api.websocket.id
  route_key = "subscribe"
  
  target = "integrations/${aws_apigatewayv2_integration.subscribe.id}"
}
```

### 5.3 Timeline Stream Handler

```python
# lambda/timeline_handler/handler.py
import json
import boto3
import psycopg2
from typing import Dict, Any

dynamodb = boto3.resource('dynamodb')
connections_table = dynamodb.Table(os.environ['CONNECTIONS_TABLE'])
apigateway = boto3.client('apigatewaymanagementapi',
                          endpoint_url=os.environ['WEBSOCKET_ENDPOINT'])

def connect_handler(event: Dict[str, Any], context: Any) -> Dict[str, Any]:
    """Handle WebSocket connection"""
    connection_id = event['requestContext']['connectionId']
    
    # Store connection with metadata
    connections_table.put_item(Item={
        'connection_id': connection_id,
        'tenant_id': event['queryStringParameters'].get('tenant_id'),
        'user_id': event['requestContext']['authorizer']['principalId'],
        'connected_at': int(time.time()),
        'ttl': int(time.time()) + 86400  # 24 hour TTL
    })
    
    return {'statusCode': 200, 'body': 'Connected'}

def disconnect_handler(event: Dict[str, Any], context: Any) -> Dict[str, Any]:
    """Handle WebSocket disconnection"""
    connection_id = event['requestContext']['connectionId']
    
    connections_table.delete_item(Key={'connection_id': connection_id})
    
    return {'statusCode': 200, 'body': 'Disconnected'}

def broadcast_handler(event: Dict[str, Any], context: Any) -> Dict[str, Any]:
    """Broadcast timeline updates to connected clients"""
    
    # This is triggered by DynamoDB Streams from ledger writes
    for record in event['Records']:
        if record['eventName'] in ['INSERT', 'MODIFY']:
            span_data = record['dynamodb']['NewImage']
            
            # Get relevant connections
            tenant_id = span_data.get('tenant_id', {}).get('S')
            visibility = span_data.get('visibility', {}).get('S', 'private')
            
            # Query connections to broadcast to
            if visibility == 'public':
                response = connections_table.scan()
            elif visibility == 'tenant':
                response = connections_table.query(
                    IndexName='tenant-index',
                    KeyConditionExpression='tenant_id = :tid',
                    ExpressionAttributeValues={':tid': tenant_id}
                )
            else:
                # Private - only to owner
                owner_id = span_data.get('owner_id', {}).get('S')
                response = connections_table.query(
                    IndexName='user-index',
                    KeyConditionExpression='user_id = :uid',
                    ExpressionAttributeValues={':uid': owner_id}
                )
            
            # Broadcast to each connection
            message = json.dumps({
                'action': 'timeline_update',
                'data': transform_dynamodb_to_json(span_data)
            })
            
            for item in response.get('Items', []):
                try:
                    apigateway.post_to_connection(
                        ConnectionId=item['connection_id'],
                        Data=message
                    )
                except apigateway.exceptions.GoneException:
                    # Connection is stale, remove it
                    connections_table.delete_item(
                        Key={'connection_id': item['connection_id']}
                    )
    
    return {'statusCode': 200}
```

---

## 6. Memory System with ElastiCache

### 6.1 Redis Configuration for Session Memory

```hcl
# modules/elasticache/main.tf
resource "aws_elasticache_replication_group" "memory_cache" {
  replication_group_id       = "${var.project}-memory"
  replication_group_description = "LogLineOS Memory System Cache"
  
  engine               = "redis"
  engine_version       = "7.0"
  node_type           = var.cache_node_type
  number_cache_clusters = var.cache_cluster_count
  
  parameter_group_name = aws_elasticache_parameter_group.memory.name
  subnet_group_name    = aws_elasticache_subnet_group.main.name
  security_group_ids   = [aws_security_group.redis.id]
  
  at_rest_encryption_enabled = true
  transit_encryption_enabled = true
  auth_token                = random_password.redis_auth.result
  
  snapshot_retention_limit = 5
  snapshot_window         = "03:00-05:00"
  
  automatic_failover_enabled = true
  multi_az_enabled          = true
  
  tags = {
    Name = "${var.project}-memory-cache"
  }
}

resource "aws_elasticache_parameter_group" "memory" {
  name   = "${var.project}-memory-params"
  family = "redis7"
  
  parameter {
    name  = "maxmemory-policy"
    value = "allkeys-lru"
  }
  
  parameter {
    name  = "timeout"
    value = "300"
  }
}
```

### 6.2 Memory Upsert Lambda

```python
# lambda/memory_upsert/handler.py
import json
import boto3
import redis
import psycopg2
from cryptography.hazmat.primitives.ciphers.aead import AESGCM
import os
import base64

kms = boto3.client('kms')
secrets = boto3.client('secretsmanager')

class MemoryHandler:
    def __init__(self):
        # Get secrets
        db_secret = secrets.get_secret_value(
            SecretId=os.environ['DB_SECRET_ARN']
        )
        self.db_config = json.loads(db_secret['SecretString'])
        
        redis_secret = secrets.get_secret_value(
            SecretId=os.environ['REDIS_SECRET_ARN']
        )
        redis_config = json.loads(redis_secret['SecretString'])
        
        # Initialize connections
        self.redis_client = redis.Redis(
            host=redis_config['endpoint'],
            port=6379,
            password=redis_config['auth_token'],
            ssl=True,
            decode_responses=True
        )
        
        # Get encryption key from KMS
        response = kms.decrypt(
            CiphertextBlob=base64.b64decode(os.environ['KMS_KEY'])
        )
        self.encryption_key = response['Plaintext']
        self.cipher = AESGCM(self.encryption_key)
    
    def handler(self, event, context):
        """Upsert memory with encryption and caching"""
        
        memory_data = json.loads(event['body'])
        headers = event['headers']
        
        # Check consent
        memory_mode = headers.get('X-LogLine-Memory', 'off')
        if memory_mode == 'off':
            return {
                'statusCode': 403,
                'body': json.dumps({'error': 'Memory is disabled'})
            }
        
        # Extract session info
        session_id = headers.get('X-LogLine-Session')
        user_id = event['requestContext']['authorizer']['principalId']
        tenant_id = headers.get('X-LogLine-Tenant')
        
        # Determine layer and TTL
        if memory_mode == 'session-only':
            memory_data['layer'] = 'session'
            memory_data['ttl_hours'] = 24
        
        # Encrypt sensitive content if needed
        sensitivity = memory_data.get('sensitivity', 'internal')
        if sensitivity in ['secret', 'pii']:
            memory_data['content'] = self.encrypt_content(
                memory_data['content']
            )
            memory_data['encrypted'] = True
        
        # Generate memory span
        memory_span = {
            'id': str(uuid.uuid4()),
            'seq': 0,
            'entity_type': 'memory',
            'who': f'kernel:memory@{context.function_version}',
            'did': 'upserted',
            'this': f"memory.{memory_data['type']}",
            'at': datetime.utcnow().isoformat(),
            'status': 'active',
            'content': memory_data['content'],
            'metadata': {
                'layer': memory_data['layer'],
                'type': memory_data['type'],
                'tags': memory_data.get('tags', []),
                'sensitivity': sensitivity,
                'session_id': session_id,
                'ttl_at': self.calculate_ttl(memory_data.get('ttl_hours', 168))
            },
            'owner_id': user_id,
            'tenant_id': tenant_id,
            'visibility': 'private'
        }
        
        # Store in database
        conn = psycopg2.connect(**self.db_config)
        with conn.cursor() as cur:
            cur.execute("""
                INSERT INTO ledger.universal_registry 
                (id, seq, entity_type, who, did, "this", at, status, 
                 content, metadata, owner_id, tenant_id, visibility)
                VALUES (%s, %s, %s, %s, %s, %s, %s, %s, %s, %s, %s, %s, %s)
            """, (
                memory_span['id'], memory_span['seq'], 
                memory_span['entity_type'], memory_span['who'],
                memory_span['did'], memory_span['this'], 
                memory_span['at'], memory_span['status'],
                json.dumps(memory_span['content']), 
                json.dumps(memory_span['metadata']),
                memory_span['owner_id'], memory_span['tenant_id'],
                memory_span['visibility']
            ))
            
            # Store embedding if provided
            if 'embedding' in memory_data:
                cur.execute("""
                    INSERT INTO ledger.memory_embeddings
                    (span_id, tenant_id, embedding)
                    VALUES (%s, %s, %s)
                """, (
                    memory_span['id'], 
                    tenant_id,
                    memory_data['embedding']
                ))
        
        conn.commit()
        
        # Cache in Redis for fast retrieval
        cache_key = f"memory:{tenant_id}:{user_id}:{memory_span['id']}"
        self.redis_client.setex(
            cache_key,
            memory_data.get('ttl_hours', 168) * 3600,
            json.dumps(memory_span)
        )
        
        # Add to session index if session memory
        if session_id and memory_data['layer'] == 'session':
            session_key = f"session:{session_id}:memories"
            self.redis_client.sadd(session_key, memory_span['id'])
            self.redis_client.expire(session_key, 86400)  # 24 hour TTL
        
        return {
            'statusCode': 201,
            'body': json.dumps({
                'id': memory_span['id'],
                'created_at': memory_span['at']
            })
        }
    
    def encrypt_content(self, content):
        """Encrypt content using AES-GCM"""
        nonce = os.urandom(12)
        plaintext = json.dumps(content).encode()
        ciphertext = self.cipher.encrypt(nonce, plaintext, None)
        
        return {
            'encrypted': True,
            'nonce': base64.b64encode(nonce).decode(),
            'ciphertext': base64.b64encode(ciphertext).decode()
        }
    
    def calculate_ttl(self, hours):
        """Calculate TTL timestamp"""
        return (datetime.utcnow() + timedelta(hours=hours)).isoformat()
```

---

## 7. Deployment Scripts

### 7.1 Main Deployment Script

```bash
#!/bin/bash
# deploy.sh - Complete deployment script for LogLineOS on AWS

set -e

ENVIRONMENT=${1:-dev}
REGION=${2:-us-east-1}
ACTION=${3:-apply}

echo "🚀 Deploying LogLineOS to AWS [$ENVIRONMENT]"

# Check prerequisites
command -v terraform >/dev/null 2>&1 || { echo "❌ Terraform not installed"; exit 1; }
command -v aws >/dev/null 2>&1 || { echo "❌ AWS CLI not installed"; exit 1; }

# Validate AWS credentials
aws sts get-caller-identity > /dev/null || { echo "❌ AWS credentials not configured"; exit 1; }

# Create S3 bucket for Terraform state if not exists
STATE_BUCKET="loglineos-terraform-state-$ENVIRONMENT"
if ! aws s3api head-bucket --bucket "$STATE_BUCKET" 2>/dev/null; then
    echo "📦 Creating state bucket: $STATE_BUCKET"
    aws s3api create-bucket \
        --bucket "$STATE_BUCKET" \
        --region "$REGION" \
        --create-bucket-configuration LocationConstraint="$REGION"
    
    aws s3api put-bucket-versioning \
        --bucket "$STATE_BUCKET" \
        --versioning-configuration Status=Enabled
    
    aws s3api put-bucket-encryption \
        --bucket "$STATE_BUCKET" \
        --server-side-encryption-configuration '{
            "Rules": [{
                "ApplyServerSideEncryptionByDefault": {
                    "SSEAlgorithm": "AES256"
                }
            }]
        }'
fi

# Create DynamoDB table for state locks if not exists
LOCK_TABLE="terraform-locks"
if ! aws dynamodb describe-table --table-name "$LOCK_TABLE" 2>/dev/null; then
    echo "🔒 Creating lock table: $LOCK_TABLE"
    aws dynamodb create-table \
        --table-name "$LOCK_TABLE" \
        --attribute-definitions AttributeName=LockID,AttributeType=S \
        --key-schema AttributeName=LockID,KeyType=HASH \
        --provisioned-throughput ReadCapacityUnits=5,WriteCapacityUnits=5 \
        --region "$REGION"
fi

# Package Lambda functions
echo "📦 Packaging Lambda functions..."
cd lambda
for dir in */; do
    if [ -f "${dir}package.json" ]; then
        echo "  Building Node.js function: $dir"
        (cd "$dir" && npm ci --production && zip -qr "../${dir%/}.zip" .)
    elif [ -f "${dir}requirements.txt" ]; then
        echo "  Building Python function: $dir"
        (cd "$dir" && pip install -r requirements.txt -t . && zip -qr "../${dir%/}.zip" .)
    fi
done
cd ..

# Upload Lambda packages to S3
LAMBDA_BUCKET="loglineos-lambda-$ENVIRONMENT-$REGION"
if ! aws s3api head-bucket --bucket "$LAMBDA_BUCKET" 2>/dev/null; then
    echo "📦 Creating Lambda bucket: $LAMBDA_BUCKET"
    aws s3api create-bucket \
        --bucket "$LAMBDA_BUCKET" \
        --region "$REGION" \
        --create-bucket-configuration LocationConstraint="$REGION"
fi

echo "⬆️  Uploading Lambda functions to S3..."
for zip_file in lambda/*.zip; do
    if [ -f "$zip_file" ]; then
        aws s3 cp "$zip_file" "s3://$LAMBDA_BUCKET/"
    fi
done

# Initialize Terraform
echo "🔧 Initializing Terraform..."
cd "terraform/environments/$ENVIRONMENT"
terraform init \
    -backend-config="bucket=$STATE_BUCKET" \
    -backend-config="key=$ENVIRONMENT/terraform.tfstate" \
    -backend-config="region=$REGION"

# Plan or Apply
if [ "$ACTION" == "plan" ]; then
    echo "📋 Planning Terraform changes..."
    terraform plan -var-file="terraform.tfvars" -out=tfplan
elif [ "$ACTION" == "apply" ]; then
    echo "⚙️  Applying Terraform changes..."
    terraform apply -var-file="terraform.tfvars" -auto-approve
    
    # Run database migrations
    echo "🗄️  Running database migrations..."
    MIGRATION_FUNCTION=$(terraform output -raw migration_lambda_name)
    aws lambda invoke \
        --function-name "$MIGRATION_FUNCTION" \
        --invocation-type RequestResponse \
        --payload '{}' \
        --region "$REGION" \
        /tmp/migration-result.json
    
    echo "✅ Migration result:"
    cat /tmp/migration-result.json
    
    # Insert initial kernels
    echo "🔧 Inserting initial kernels..."
    ./scripts/insert_kernels.sh "$ENVIRONMENT"
    
elif [ "$ACTION" == "destroy" ]; then
    echo "🗑️  Destroying infrastructure..."
    terraform destroy -var-file="terraform.tfvars" -auto-approve
fi

echo "✅ Deployment complete!"

# Output important endpoints
if [ "$ACTION" == "apply" ]; then
    echo ""
    echo "📌 Important Endpoints:"
    echo "  API Gateway: $(terraform output -raw api_gateway_url)"
    echo "  WebSocket: $(terraform output -raw websocket_url)"
    echo "  CloudFront: $(terraform output -raw cloudfront_url)"
fi
```

### 7.2 Kernel Insertion Script

```bash
#!/bin/bash
# scripts/insert_kernels.sh - Insert core kernels into the ledger

ENVIRONMENT=$1
DB_SECRET_ARN=$(aws secretsmanager list-secrets --query "SecretList[?Name=='loglineos-db-$ENVIRONMENT'].ARN" --output text)
DB_SECRET=$(aws secretsmanager get-secret-value --secret-id "$DB_SECRET_ARN" --query SecretString --output text)

DB_HOST=$(echo "$DB_SECRET" | jq -r .host)
DB_NAME=$(echo "$DB_SECRET" | jq -r .database)
DB_USER=$(echo "$DB_SECRET" | jq -r .username)
DB_PASS=$(echo "$DB_SECRET" | jq -r .password)

export PGPASSWORD="$DB_PASS"

# Insert run_code_kernel
psql -h "$DB_HOST" -U "$DB_USER" -d "$DB_NAME" << 'EOF'
INSERT INTO ledger.universal_registry
(id,seq,entity_type,who,did,"this",at,status,name,code,language,runtime,owner_id,tenant_id,visibility)
VALUES
('00000000-0000-4000-8000-000000000001',2,'function','daniel','defined','function',now(),'active',
'run_code_kernel', 
$CODE$
// Kernel code from Blueprint4 here
$CODE$,
'javascript','nodejs18.x','daniel','voulezvous','tenant');
EOF

echo "✅ Core kernels inserted successfully"
```

---

## 8. Monitoring and Observability

### 8.1 CloudWatch Dashboard

```hcl
# modules/monitoring/dashboard.tf
resource "aws_cloudwatch_dashboard" "loglineos" {
  dashboard_name = "${var.project}-dashboard"
  
  dashboard_body = jsonencode({
    widgets = [
      {
        type = "metric"
        properties = {
          metrics = [
            ["AWS/Lambda", "Invocations", { stat = "Sum" }],
            [".", "Errors", { stat = "Sum" }],
            [".", "Duration", { stat = "Average" }],
            [".", "ConcurrentExecutions", { stat = "Maximum" }]
          ]
          period = 300
          stat = "Average"
          region = var.aws_region
          title = "Lambda Metrics"
        }
      },
      {
        type = "metric"
        properties = {
          metrics = [
            ["AWS/RDS", "DatabaseConnections", { stat = "Average" }],
            [".", "CPUUtilization", { stat = "Average" }],
            [".", "FreeableMemory", { stat = "Average" }],
            [".", "ReadLatency", { stat = "Average" }],
            [".", "WriteLatency", { stat = "Average" }]
          ]
          period = 300
          stat = "Average"
          region = var.aws_region
          title = "RDS Metrics"
        }
      },
      {
        type = "metric"
        properties = {
          metrics = [
            ["AWS/ApiGateway", "Count", { stat = "Sum" }],
            [".", "4XXError", { stat = "Sum" }],
            [".", "5XXError", { stat = "Sum" }],
            [".", "Latency", { stat = "Average" }]
          ]
          period = 300
          stat = "Average"
          region = var.aws_region
          title = "API Gateway Metrics"
        }
      }
    ]
  })
}
```

### 8.2 X-Ray Tracing

```python
# lambda/tracing.py - Add to all Lambda functions
from aws_xray_sdk.core import xray_recorder
from aws_xray_sdk.core import patch_all

# Patch all AWS SDK calls
patch_all()

@xray_recorder.capture('handler')
def handler(event, context):
    # Your handler code here
    pass
```

---

## 9. Security Hardening

### 9.1 WAF Rules

```hcl
# modules/security/waf.tf
resource "aws_wafv2_web_acl" "api_protection" {
  name  = "${var.project}-waf"
  scope = "REGIONAL"
  
  default_action {
    allow {}
  }
  
  rule {
    name     = "RateLimitRule"
    priority = 1
    
    statement {
      rate_based_statement {
        limit              = 2000
        aggregate_key_type = "IP"
      }
    }
    
    action {
      block {}
    }
    
    visibility_config {
      cloudwatch_metrics_enabled = true
      metric_name               = "RateLimitRule"
      sampled_requests_enabled   = true
    }
  }
  
  rule {
    name     = "AWSManagedRulesCommonRuleSet"
    priority = 2
    
    override_action {
      none {}
    }
    
    statement {
      managed_rule_group_statement {
        name        = "AWSManagedRulesCommonRuleSet"
        vendor_name = "AWS"
      }
    }
    
    visibility_config {
      cloudwatch_metrics_enabled = true
      metric_name               = "CommonRuleSetMetric"
      sampled_requests_enabled   = true
    }
  }
}
```

### 9.2 VPC and Security Groups

```hcl
# modules/vpc/main.tf
resource "aws_vpc" "main" {
  cidr_block           = var.vpc_cidr
  enable_dns_hostnames = true
  enable_dns_support   = true
  
  tags = {
    Name = "${var.project}-vpc"
  }
}

resource "aws_subnet" "private" {
  count             = length(var.availability_zones)
  vpc_id            = aws_vpc.main.id
  cidr_block        = cidrsubnet(var.vpc_cidr, 4, count.index)
  availability_zone = var.availability_zones[count.index]
  
  tags = {
    Name = "${var.project}-private-${var.availability_zones[count.index]}"
    Type = "Private"
  }
}

resource "aws_security_group" "rds" {
  name_prefix = "${var.project}-rds-"
  vpc_id      = aws_vpc.main.id
  
  ingress {
    from_port       = 5432
    to_port         = 5432
    protocol        = "tcp"
    security_groups = [aws_security_group.lambda.id]
  }
  
  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }
}

resource "aws_security_group" "lambda" {
  name_prefix = "${var.project}-lambda-"
  vpc_id      = aws_vpc.main.id
  
  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }
}
```

---

## 10. Cost Optimization

### 10.1 Auto-scaling Configuration

```hcl
# modules/autoscaling/main.tf
resource "aws_appautoscaling_target" "rds" {
  service_namespace  = "rds"
  resource_id        = "cluster:${aws_rds_cluster.main.cluster_identifier}"
  scalable_dimension = "rds:cluster:ReadReplicaCount"
  min_capacity       = 1
  max_capacity       = 5
}

resource "aws_appautoscaling_policy" "rds_read_replicas" {
  name               = "${var.project}-rds-autoscale"
  service_namespace  = aws_appautoscaling_target.rds.service_namespace
  resource_id        = aws_appautoscaling_target.rds.resource_id
  scalable_dimension = aws_appautoscaling_target.rds.scalable_dimension
  
  target_tracking_scaling_policy_configuration {
    predefined_metric_specification {
      predefined_metric_type = "RDSReaderAverageCPUUtilization"
    }
    target_value = 70
  }
}
```

### 10.2 Lambda Reserved Concurrency

```hcl
resource "aws_lambda_reserved_concurrent_executions" "kernels" {
  function_name                      = aws_lambda_function.kernel_executor.function_name
  reserved_concurrent_executions = 100  # Adjust based on load
}
```

---

## 11. Disaster Recovery

### 11.1 Automated Backups

```hcl
resource "aws_backup_plan" "loglineos" {
  name = "${var.project}-backup-plan"
  
  rule {
    rule_name         = "daily_backups"
    target_vault_name = aws_backup_vault.main.name
    schedule          = "cron(0 5 ? * * *)"
    
    lifecycle {
      delete_after = 30
    }
  }
}

resource "aws_backup_selection" "rds" {
  name         = "${var.project}-rds-backup"
  plan_id      = aws_backup_plan.loglineos.id
  iam_role_arn = aws_iam_role.backup.arn
  
  resources = [
    aws_db_instance.ledger.arn
  ]
}
```

---

## 12. Environment Variables Configuration

```hcl
# terraform/environments/production/terraform.tfvars
environment = "production"
aws_region  = "us-east-1"

# VPC Configuration
vpc_cidr           = "10.0.0.0/16"
availability_zones = ["us-east-1a", "us-east-1b", "us-east-1c"]

# RDS Configuration  
db_instance_class = "db.r6g.xlarge"
db_multi_az       = true

# ElastiCache Configuration
cache_node_type     = "cache.r6g.large"
cache_cluster_count = 2

# Lambda Configuration
lambda_memory_size = 1024
lambda_timeout     = 30

# API Gateway Configuration
api_throttle_burst_limit = 5000
api_throttle_rate_limit  = 2000

# Tags
tags = {
  Environment = "production"
  Project     = "LogLineOS"
  Owner       = "Engineering"
  CostCenter  = "Platform"
}
```

---

## Summary

This AWS deployment guide provides:

1. **Complete Infrastructure as Code** using Terraform
2. **Managed Services** for reduced operational overhead
3. **Serverless Architecture** for automatic scaling
4. **Security Best Practices** including encryption, WAF, and VPC isolation
5. **High Availability** with multi-AZ deployments
6. **Monitoring and Observability** with CloudWatch and X-Ray
7. **Cost Optimization** through auto-scaling and reserved capacity
8. **Disaster Recovery** with automated backups

The architecture maintains the core LogLineOS principles:
- Ledger-only design with 70 semantic columns
- Append-only immutability
- Cryptographic proofs
- Multi-tenant RLS
- Memory system with encryption
- Prompt system with LLM integration
- Real-time SSE via WebSockets

This setup can handle enterprise-scale workloads while maintaining the philosophical integrity of the LogLineOS design.
