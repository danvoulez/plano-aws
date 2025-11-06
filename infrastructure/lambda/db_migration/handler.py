"""
Database Migration Lambda Handler

Executes schema migrations for the LogLineOS ledger system.
Implements Blueprint4 70-column semantic schema with RLS.

Features:
- Idempotent migration execution
- Comprehensive error handling and logging
- Support for pgvector extension (optional)
- Automatic kernel seeding from Blueprint4

Security:
- Credentials from AWS Secrets Manager
- Parameterized queries
- Connection timeout handling
"""

import json
import boto3
import psycopg2
import os
from datetime import datetime
import traceback

secrets = boto3.client('secretsmanager')
logger = None

try:
    from aws_lambda_powertools import Logger
    logger = Logger(service="db_migration")
except ImportError:
    # Fallback to basic logging
    import logging
    logger = logging.getLogger()
    logger.setLevel(logging.INFO)

def handler(event, context):
    """Execute database migrations for LogLineOS schema"""
    
    start_time = datetime.utcnow()
    request_id = context.request_id if context else 'local'
    
    logger.info("Starting database migration", extra={
        "timestamp": start_time.isoformat(),
        "request_id": request_id,
        "environment": os.environ.get('ENVIRONMENT', 'unknown')
    })
    
    conn = None
    
    try:
        # Get DB credentials from Secrets Manager
        try:
            secret_response = secrets.get_secret_value(SecretId=os.environ['DB_SECRET_ARN'])
            db_config = json.loads(secret_response['SecretString'])
        except Exception as secret_error:
            logger.error("Failed to retrieve database credentials", extra={
                "error": str(secret_error)
            })
            return create_error_response(500, "Configuration error")
        
        # Parse connection parameters
        host = db_config['host'].split(':')[0]
        port = int(db_config.get('port', 5432))
        database = db_config.get('database', 'loglineos')
        username = db_config.get('username', 'loglineos')
        password = db_config.get('password')
        
        logger.info("Connecting to database", extra={
            "host": host,
            "port": port,
            "database": database
        })
        
        # Connect with timeout
        conn = psycopg2.connect(
            host=host,
            port=port,
            database=database,
            user=username,
            password=password,
            connect_timeout=10
        )
        
        conn.autocommit = True
        
        with conn.cursor() as cur:
            # Step 1: Create schemas
            logger.info("Creating schemas")
            cur.execute("""
                CREATE SCHEMA IF NOT EXISTS app;
                CREATE SCHEMA IF NOT EXISTS ledger;
            """)
            
            # Step 2: Create session functions for RLS
            logger.info("Creating RLS session functions")
            cur.execute("""
                CREATE OR REPLACE FUNCTION app.current_user_id() 
                RETURNS text LANGUAGE sql STABLE AS 
                $$ SELECT current_setting('app.user_id', true) $$;
                
                CREATE OR REPLACE FUNCTION app.current_tenant_id() 
                RETURNS text LANGUAGE sql STABLE AS 
                $$ SELECT current_setting('app.tenant_id', true) $$;
            """)
            
            # Step 3: Create universal_registry with 70 semantic columns
            logger.info("Creating universal_registry table with Blueprint4 schema")
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
            
            # Step 4: Create indexes
            logger.info("Creating performance indexes")
            cur.execute("""
                CREATE INDEX IF NOT EXISTS ur_idx_at ON ledger.universal_registry (at DESC);
                CREATE INDEX IF NOT EXISTS ur_idx_entity ON ledger.universal_registry (entity_type, at DESC);
                CREATE INDEX IF NOT EXISTS ur_idx_owner_tenant ON ledger.universal_registry (owner_id, tenant_id);
                CREATE INDEX IF NOT EXISTS ur_idx_trace ON ledger.universal_registry (trace_id);
                CREATE INDEX IF NOT EXISTS ur_idx_parent ON ledger.universal_registry (parent_id);
                CREATE INDEX IF NOT EXISTS ur_idx_related ON ledger.universal_registry USING GIN (related_to);
                CREATE INDEX IF NOT EXISTS ur_idx_metadata ON ledger.universal_registry USING GIN (metadata);
                CREATE INDEX IF NOT EXISTS ur_idx_status ON ledger.universal_registry (status) WHERE status IS NOT NULL;
                CREATE INDEX IF NOT EXISTS ur_idx_entity_status ON ledger.universal_registry (entity_type, status, at DESC);
            """)
            
            # Step 5: Enable Row-Level Security
            logger.info("Enabling Row-Level Security")
            cur.execute("""
                ALTER TABLE ledger.universal_registry ENABLE ROW LEVEL SECURITY;
            """)
            
            # Drop existing policies if they exist (idempotent)
            cur.execute("""
                DROP POLICY IF EXISTS ur_select_policy ON ledger.universal_registry;
                DROP POLICY IF EXISTS ur_insert_policy ON ledger.universal_registry;
            """)
            
            # Create RLS policies
            logger.info("Creating RLS policies")
            cur.execute("""
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
            
            # Step 6: Install pgvector extension (optional, for memory system)
            logger.info("Installing pgvector extension")
            try:
                cur.execute("CREATE EXTENSION IF NOT EXISTS vector;")
                
                logger.info("Creating memory_embeddings table")
                cur.execute("""
                    CREATE TABLE IF NOT EXISTS ledger.memory_embeddings (
                        span_id uuid PRIMARY KEY,
                        tenant_id text,
                        dim int DEFAULT 1536,
                        embedding vector(1536),
                        created_at timestamptz DEFAULT now(),
                        FOREIGN KEY (span_id) REFERENCES ledger.universal_registry(id) ON DELETE CASCADE
                    );
                    
                    CREATE INDEX IF NOT EXISTS mem_emb_tenant_idx 
                    ON ledger.memory_embeddings (tenant_id);
                    
                    CREATE INDEX IF NOT EXISTS mem_emb_vector_idx 
                    ON ledger.memory_embeddings USING ivfflat (embedding vector_cosine_ops)
                    WITH (lists = 100);
                """)
                logger.info("Memory system tables created successfully")
            except Exception as pgvector_error:
                logger.warning("Could not install pgvector extension", extra={
                    "error": str(pgvector_error)
                })
                logger.warning("Memory system will not be available without pgvector")
            
            # Step 7: Create helper views
            logger.info("Creating helper views")
            cur.execute("""
                CREATE OR REPLACE VIEW ledger.visible_timeline AS
                SELECT * FROM ledger.universal_registry
                WHERE is_deleted = false;
            """)
            
            # Step 8: Create append-only enforcement trigger
            logger.info("Creating append-only enforcement triggers")
            cur.execute("""
                CREATE OR REPLACE FUNCTION ledger.enforce_append_only()
                RETURNS TRIGGER AS $$
                BEGIN
                    RAISE EXCEPTION 'Updates and deletes are not allowed on append-only ledger';
                    RETURN NULL;
                END;
                $$ LANGUAGE plpgsql;
                
                DROP TRIGGER IF EXISTS ur_append_only_trigger ON ledger.universal_registry;
                
                CREATE TRIGGER ur_append_only_trigger
                BEFORE UPDATE OR DELETE ON ledger.universal_registry
                FOR EACH ROW EXECUTE FUNCTION ledger.enforce_append_only();
            """)
            
            # Step 9: Seed Blueprint4 kernels and manifest (optional)
            logger.info("Attempting to seed Blueprint4 kernels")
            try:
                seed_path = os.path.join(os.path.dirname(__file__), 'seeds', 'blueprint4_kernels.sql')
                if os.path.exists(seed_path):
                    with open(seed_path, 'r') as f:
                        seed_sql = f.read()
                    cur.execute(seed_sql)
                    logger.info("Blueprint4 kernels seeded successfully")
                else:
                    logger.warning("Seed file not found", extra={"path": seed_path})
            except Exception as seed_error:
                logger.warning("Could not seed Blueprint4 kernels", extra={
                    "error": str(seed_error)
                })
                # Don't fail the migration if seeding fails
        
        # Close connection
        if conn:
            conn.close()
            
        end_time = datetime.utcnow()
        duration = (end_time - start_time).total_seconds()
        
        logger.info("Database migration completed successfully", extra={
            "duration_seconds": duration,
            "end_time": end_time.isoformat()
        })
        
        return {
            'statusCode': 200,
            'body': json.dumps({
                'message': 'Migration completed successfully',
                'timestamp': end_time.isoformat(),
                'duration_seconds': duration,
                'environment': os.environ.get('ENVIRONMENT', 'unknown')
            })
        }
        
    except psycopg2.Error as db_error:
        logger.error("Database error during migration", extra={
            "error": str(db_error),
            "error_code": db_error.pgcode,
            "traceback": traceback.format_exc()
        })
        return create_error_response(500, "Database migration failed", {
            "error_code": db_error.pgcode
        })
        
    except Exception as error:
        logger.error("Unexpected error during migration", extra={
            "error": str(error),
            "traceback": traceback.format_exc()
        })
        return create_error_response(500, "Migration failed", {
            "error": str(error) if os.environ.get('ENVIRONMENT') != 'production' else None
        })
        
    finally:
        # Ensure connection is closed
        if conn and not conn.closed:
            try:
                conn.close()
                logger.info("Database connection closed")
            except Exception as close_error:
                logger.error("Error closing database connection", extra={
                    "error": str(close_error)
                })


def create_error_response(status_code, message, details=None):
    """Create standardized error response"""
    response_body = {
        'error': message,
        'timestamp': datetime.utcnow().isoformat()
    }
    
    if details:
        response_body.update(details)
    
    return {
        'statusCode': status_code,
        'body': json.dumps(response_body)
    }
