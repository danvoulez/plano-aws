const { SecretsManagerClient, GetSecretValueCommand } = require('@aws-sdk/client-secrets-manager');
const { Client } = require('pg');

const secretsClient = new SecretsManagerClient({});

exports.handler = async (event) => {
    console.log('API Handler invoked:', JSON.stringify(event));
    
    try {
        const path = event.path || event.requestContext?.resourcePath || '/';
        const method = event.httpMethod || event.requestContext?.http?.method || 'GET';
        
        // Get database credentials
        const dbSecretResponse = await secretsClient.send(
            new GetSecretValueCommand({ SecretId: process.env.DB_SECRET_ARN })
        );
        
        const dbConfig = JSON.parse(dbSecretResponse.SecretString);
        
        // Connect to database
        const client = new Client({
            host: dbConfig.host.split(':')[0],
            database: dbConfig.database,
            user: dbConfig.username,
            password: dbConfig.password,
            ssl: { rejectUnauthorized: false },
            port: parseInt(dbConfig.port || '5432')
        });
        
        await client.connect();
        
        try {
            // Extract user context from headers or authorizer
            const userId = event.headers?.['x-user-id'] || 'anonymous';
            const tenantId = event.headers?.['x-tenant-id'];
            
            // Set RLS context
            await client.query('SET app.user_id = $1', [userId]);
            if (tenantId) {
                await client.query('SET app.tenant_id = $1', [tenantId]);
            }
            
            // Route requests
            if (path === '/spans' && method === 'POST') {
                return await createSpan(event, client);
            } else if (path === '/spans' && method === 'GET') {
                return await listSpans(event, client);
            } else {
                return {
                    statusCode: 404,
                    body: JSON.stringify({ error: 'Not found' })
                };
            }
            
        } finally {
            await client.end();
        }
        
    } catch (error) {
        console.error('Error in API Handler:', error);
        return {
            statusCode: 500,
            body: JSON.stringify({ 
                error: 'Internal server error',
                message: error.message 
            })
        };
    }
};

async function createSpan(event, client) {
    const body = typeof event.body === 'string' ? JSON.parse(event.body) : event.body;
    
    const {
        entity_type,
        who,
        did,
        this: thisField,
        name,
        description,
        code,
        input,
        output,
        metadata,
        owner_id,
        tenant_id,
        visibility = 'private'
    } = body;
    
    if (!entity_type || !who || !thisField) {
        return {
            statusCode: 400,
            body: JSON.stringify({ error: 'Missing required fields: entity_type, who, this' })
        };
    }
    
    const spanId = require('crypto').randomUUID();
    
    const result = await client.query(`
        INSERT INTO ledger.universal_registry 
        (id, seq, entity_type, who, did, "this", at, name, description, code, input, output, metadata, owner_id, tenant_id, visibility, status)
        VALUES ($1, 0, $2, $3, $4, $5, now(), $6, $7, $8, $9, $10, $11, $12, $13, $14, 'active')
        RETURNING *
    `, [
        spanId,
        entity_type,
        who,
        did,
        thisField,
        name,
        description,
        code,
        input ? JSON.stringify(input) : null,
        output ? JSON.stringify(output) : null,
        metadata ? JSON.stringify(metadata) : null,
        owner_id,
        tenant_id,
        visibility
    ]);
    
    return {
        statusCode: 201,
        body: JSON.stringify({
            success: true,
            span: result.rows[0]
        })
    };
}

async function listSpans(event, client) {
    const params = event.queryStringParameters || {};
    const limit = parseInt(params.limit || '50');
    const offset = parseInt(params.offset || '0');
    const entityType = params.entity_type;
    
    let query = `
        SELECT * FROM ledger.visible_timeline
        WHERE is_deleted = false
    `;
    const queryParams = [];
    
    if (entityType) {
        queryParams.push(entityType);
        query += ` AND entity_type = $${queryParams.length}`;
    }
    
    query += ` ORDER BY at DESC LIMIT $${queryParams.length + 1} OFFSET $${queryParams.length + 2}`;
    queryParams.push(limit, offset);
    
    const result = await client.query(query, queryParams);
    
    return {
        statusCode: 200,
        body: JSON.stringify({
            spans: result.rows,
            count: result.rows.length,
            limit,
            offset
        })
    };
}
