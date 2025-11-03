import json
import boto3
import psycopg2
import os
from datetime import datetime, timedelta
import uuid

secrets = boto3.client('secretsmanager')

def handler(event, context):
    """Upsert memory with optional encryption"""
    
    print(f"Memory upsert invoked: {json.dumps(event)}")
    
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
        
        # Get database credentials
        secret = secrets.get_secret_value(SecretId=os.environ['DB_SECRET_ARN'])
        db_config = json.loads(secret['SecretString'])
        
        host = db_config['host'].split(':')[0]
        port = int(db_config.get('port', 5432))
        
        conn = psycopg2.connect(
            host=host,
            port=port,
            database=db_config['database'],
            user=db_config['username'],
            password=db_config['password']
        )
        
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
        conn.close()
        
        return {
            'statusCode': 201,
            'body': json.dumps({
                'id': memory_id,
                'created_at': datetime.utcnow().isoformat(),
                'ttl_at': ttl_at
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
                'message': str(e)
            })
        }
