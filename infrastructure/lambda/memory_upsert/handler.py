import json
import boto3
import psycopg2
from psycopg2 import pool
import os
from datetime import datetime, timedelta
import uuid
import time

secrets = boto3.client('secretsmanager')

# Global connection pool for Lambda container reuse (Blueprint4 optimization)
db_pool = None
db_config_cache = {'config': None, 'timestamp': 0}
DB_CONFIG_CACHE_TTL = 900  # 15 minutes in seconds

def handler(event, context):
    """Upsert memory with optional encryption"""
    
    print(f"Memory upsert invoked: {json.dumps(event)}")
    
    conn = None
    try:
        # Parse request body
        body = event.get('body', '{}')
        if isinstance(body, str):
            body = json.loads(body)
        
        # Get headers
        headers = event.get('headers', {})
        memory_mode = headers.get('x-logline-memory', headers.get('X-LogLine-Memory', 'off'))
        
        if memory_mode == 'off':
            return {
                'statusCode': 403,
                'body': json.dumps({'error': 'Memory is disabled'})
            }
        
        # Extract memory data
        content = body.get('content')
        memory_type = body.get('type', 'note')
        layer = body.get('layer', 'session' if memory_mode == 'session-only' else 'persistent')
        ttl_hours = body.get('ttl_hours', 24 if layer == 'session' else 168)
        sensitivity = body.get('sensitivity', 'internal')
        tags = body.get('tags', [])
        
        if not content:
            return {
                'statusCode': 400,
                'body': json.dumps({'error': 'content is required'})
            }
        
        # Get database connection from pool with retry
        conn = get_db_connection()
        
        # Extract user context
        user_id = headers.get('x-user-id', headers.get('X-User-Id', 'anonymous'))
        tenant_id = headers.get('x-tenant-id', headers.get('X-Tenant-Id'))
        session_id = headers.get('x-logline-session', headers.get('X-LogLine-Session'))
        
        with conn.cursor() as cur:
            # Set RLS context
            cur.execute('SET app.user_id = %s', (user_id,))
            if tenant_id:
                cur.execute('SET app.tenant_id = %s', (tenant_id,))
            
            # Generate memory span
            memory_id = str(uuid.uuid4())
            ttl_at = (datetime.utcnow() + timedelta(hours=ttl_hours)).isoformat()
            
            metadata = {
                'layer': layer,
                'type': memory_type,
                'tags': tags,
                'sensitivity': sensitivity,
                'session_id': session_id,
                'ttl_at': ttl_at
            }
            
            # Insert memory span
            cur.execute("""
                INSERT INTO ledger.universal_registry 
                (id, seq, entity_type, who, did, "this", at, status, description, metadata, owner_id, tenant_id, visibility)
                VALUES (%s, 0, 'memory', %s, 'upserted', %s, now(), 'active', %s, %s, %s, %s, 'private')
                RETURNING *
            """, (
                memory_id,
                f'kernel:memory@v1',
                f'memory.{memory_type}',
                content,
                json.dumps(metadata),
                user_id,
                tenant_id
            ))
            
            result = cur.fetchone()
        
        conn.commit()
        
        return {
            'statusCode': 201,
            'body': json.dumps({
                'id': memory_id,
                'created_at': datetime.utcnow().isoformat(),
                'ttl_at': ttl_at
            })
        }
        
    except psycopg2.OperationalError as e:
        print(f"Database connection error: {str(e)}")
        import traceback
        traceback.print_exc()
        return {
            'statusCode': 503,
            'body': json.dumps({
                'error': 'Service temporarily unavailable',
                'message': 'Database connection failed'
            })
        }
    except Exception as e:
        print(f"Error in memory upsert: {str(e)}")
        import traceback
        traceback.print_exc()
        return {
            'statusCode': 500,
            'body': json.dumps({
                'error': 'Memory upsert failed',
                'message': str(e) if os.environ.get('ENVIRONMENT') != 'production' else 'Internal server error'
            })
        }
    finally:
        # Return connection to pool
        if conn:
            try:
                conn.close()
            except:
                pass


def get_db_config():
    """Get database configuration with caching"""
    global db_config_cache
    
    now = time.time()
    
    # Return cached config if still valid
    if db_config_cache['config'] and (now - db_config_cache['timestamp']) < DB_CONFIG_CACHE_TTL:
        print('Using cached database configuration')
        return db_config_cache['config']
    
    # Fetch fresh config with retry logic
    last_error = None
    for attempt in range(1, 4):
        try:
            print(f'Fetching database credentials (attempt {attempt}/3)')
            secret = secrets.get_secret_value(SecretId=os.environ['DB_SECRET_ARN'])
            config = json.loads(secret['SecretString'])
            
            # Cache the config
            db_config_cache = {
                'config': config,
                'timestamp': now
            }
            
            print('Database configuration fetched and cached')
            return config
        except Exception as e:
            last_error = e
            print(f'Failed to retrieve database credentials (attempt {attempt}/3): {str(e)}')
            
            if attempt < 3:
                # Exponential backoff: 0.1s, 0.2s
                delay = 0.1 * (2 ** (attempt - 1))
                time.sleep(delay)
    
    raise Exception(f'Failed to retrieve database credentials after 3 attempts: {str(last_error)}')


def get_db_pool():
    """Initialize or get database connection pool"""
    global db_pool
    
    if db_pool:
        # Test if pool is still healthy
        try:
            conn = db_pool.getconn()
            db_pool.putconn(conn)
            return db_pool
        except Exception as e:
            print(f'Existing pool unhealthy, recreating: {str(e)}')
            try:
                db_pool.closeall()
            except:
                pass
            db_pool = None
    
    # Create new pool
    print('Creating new database connection pool')
    db_config = get_db_config()
    
    host = db_config['host'].split(':')[0]
    port = int(db_config.get('port', 5432))
    
    db_pool = pool.SimpleConnectionPool(
        1,  # minconn
        5,  # maxconn (conservative for Lambda)
        host=host,
        port=port,
        database=db_config['database'],
        user=db_config['username'],
        password=db_config['password'],
        connect_timeout=5
    )
    
    return db_pool


def get_db_connection():
    """Get database connection from pool with retry logic"""
    pool_obj = get_db_pool()
    
    last_error = None
    for attempt in range(1, 4):
        try:
            print(f'Acquiring database connection (attempt {attempt}/3)')
            conn = pool_obj.getconn()
            print('Database connection acquired from pool')
            return conn
        except Exception as e:
            last_error = e
            print(f'Failed to acquire database connection (attempt {attempt}/3): {str(e)}')
            
            if attempt < 3:
                # Exponential backoff: 0.05s, 0.1s
                delay = 0.05 * (2 ** (attempt - 1))
                time.sleep(delay)
    
    raise Exception(f'Failed to acquire database connection after 3 attempts: {str(last_error)}')
