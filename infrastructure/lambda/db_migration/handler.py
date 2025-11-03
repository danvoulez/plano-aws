import json
import boto3
import psycopg2
import os
from datetime import datetime

secrets = boto3.client('secretsmanager')

def handler(event, context):
    """Execute database migrations for LogLineOS schema"""
    
    print(f"Starting database migration at {datetime.utcnow().isoformat()}")
    
    try:
        # Get DB credentials from Secrets Manager
        secret = secrets.get_secret_value(SecretId=os.environ['DB_SECRET_ARN'])
        db_config = json.loads(secret['SecretString'])
        
        # Parse host to remove port if included
        host = db_config['host'].split(':')[0]
        port = int(db_config.get('port', 5432))
        
        conn = psycopg2.connect(
            host=host,
            port=port,
            database=db_config['database'],
            user=db_config['username'],
            password=db_config['password']
        )
        
        conn.autocommit = True
        
        with conn.cursor() as cur:
            print("Creating schemas...")
            # Create schemas
            cur.execute("""
                CREATE SCHEMA IF NOT EXISTS app;
                CREATE SCHEMA IF NOT EXISTS ledger;
            """)
            
            print("Creating session functions...")
            # Create session functions for RLS
            cur.execute("""
                CREATE OR REPLACE FUNCTION app.current_user_id() 
                RETURNS text LANGUAGE sql STABLE AS 
                $$ SELECT current_setting('app.user_id', true) $$;
                
                CREATE OR REPLACE FUNCTION app.current_tenant_id() 
                RETURNS text LANGUAGE sql STABLE AS 
                $$ SELECT current_setting('app.tenant_id', true) $$;
            """)
            
            print("Creating universal_registry table...")
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
            
            print("Creating indexes...")
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
            
            print("Enabling RLS...")
            # Enable RLS
            cur.execute("""
                ALTER TABLE ledger.universal_registry ENABLE ROW LEVEL SECURITY;
            """)
            
            # Drop existing policies if they exist
            cur.execute("""
                DROP POLICY IF EXISTS ur_select_policy ON ledger.universal_registry;
                DROP POLICY IF EXISTS ur_insert_policy ON ledger.universal_registry;
            """)
            
            # Create RLS policies
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
            
            print("Installing pgvector extension...")
            # Install pgvector for memory system
            try:
                cur.execute("CREATE EXTENSION IF NOT EXISTS vector;")
                
                print("Creating memory_embeddings table...")
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
            except Exception as e:
                print(f"Warning: Could not install pgvector: {e}")
                print("Memory system will not be available without pgvector extension")
            
            print("Creating helper views...")
            # Create helper view for visible timeline
            cur.execute("""
                CREATE OR REPLACE VIEW ledger.visible_timeline AS
                SELECT * FROM ledger.universal_registry
                WHERE is_deleted = false;
            """)
        
        conn.close()
        print("Database migration completed successfully")
        
        return {
            'statusCode': 200,
            'body': json.dumps({
                'message': 'Migration completed successfully',
                'timestamp': datetime.utcnow().isoformat()
            })
        }
        
    except Exception as e:
        print(f"Error during migration: {str(e)}")
        import traceback
        traceback.print_exc()
        return {
            'statusCode': 500,
            'body': json.dumps({
                'error': 'Migration failed',
                'message': str(e)
            })
        }
