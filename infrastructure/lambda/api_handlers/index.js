/**
 * API Handler Lambda Function
 * 
 * Handles REST API requests for the LogLineOS ledger system.
 * Implements Blueprint4 append-only ledger with RLS.
 * 
 * Endpoints:
 * - POST /spans - Create new span
 * - GET /spans - List spans with filtering
 * 
 * Security:
 * - Row-Level Security (RLS) enforced via session variables
 * - Input validation on all requests
 * - Parameterized queries to prevent SQL injection
 */

const { SecretsManagerClient, GetSecretValueCommand } = require('@aws-sdk/client-secrets-manager');
const { Pool } = require('pg');

const secretsClient = new SecretsManagerClient({});

// Global state for Lambda container reuse (Blueprint4 optimization)
let dbPool = null;
let dbConfigCache = null;

// Cache TTLs (milliseconds)
const DB_CONFIG_CACHE_TTL = 15 * 60 * 1000; // 15 minutes

exports.handler = async (event) => {
    const startTime = Date.now();
    const requestId = event.requestContext?.requestId || 'unknown';
    
    console.log('API Handler invoked', {
        timestamp: new Date().toISOString(),
        requestId,
        path: event.path,
        method: event.httpMethod
    });
    
    try {
        const path = event.path || event.requestContext?.resourcePath || '/';
        const method = event.httpMethod || event.requestContext?.http?.method || 'GET';
        
        // Get database credentials with caching and retry
        const dbConfig = await getDbConfig();
        
        // Get client from connection pool with retry
        const client = await getDbClient(dbConfig);
        
        try {
            // Extract and validate user context from headers or authorizer
            const userId = event.headers?.['x-user-id'] || 
                          event.requestContext?.authorizer?.principalId || 
                          'anonymous';
            const tenantId = event.headers?.['x-tenant-id'];
            
            if (!isValidUserId(userId)) {
                return createErrorResponse(400, 'Invalid user ID format');
            }
            
            if (tenantId && !isValidTenantId(tenantId)) {
                return createErrorResponse(400, 'Invalid tenant ID format');
            }
            
            // Set RLS context with sanitization
            await client.query('SET app.user_id = $1', [sanitizeRLSValue(userId)]);
            if (tenantId) {
                await client.query('SET app.tenant_id = $1', [sanitizeRLSValue(tenantId)]);
            }
            
            // Route requests with proper error handling
            let response;
            if (path === '/spans' && method === 'POST') {
                response = await createSpan(event, client, userId, tenantId);
            } else if (path === '/spans' && method === 'GET') {
                response = await listSpans(event, client);
            } else if (path === '/health' && method === 'GET') {
                response = await healthCheck(client, startTime);
            } else {
                response = createErrorResponse(404, 'Not found', { path, method });
            }
            
            // Add duration header
            const duration = Date.now() - startTime;
            response.headers = {
                ...response.headers,
                'X-Duration-Ms': duration.toString()
            };
            
            return response;
            
        } finally {
            // Release client back to pool (don't end connection - reuse in warm Lambda)
            if (client && client.release) {
                try {
                    client.release();
                } catch (releaseError) {
                    console.error('Error releasing database client', { error: releaseError.message });
                }
            }
        }
        
    } catch (error) {
        const duration = Date.now() - startTime;
        console.error('Unhandled error in API Handler', {
            error: error.message,
            stack: error.stack,
            duration_ms: duration,
            requestId
        });
        
        // Don't expose internal error details in production
        const message = process.env.ENVIRONMENT === 'production'
            ? 'Internal server error'
            : error.message;
        
        return createErrorResponse(500, message, { duration_ms: duration });
    }
};

/**
 * Create a new span in the ledger
 */
async function createSpan(event, client, userId, tenantId) {
    let body;
    try {
        body = typeof event.body === 'string' ? JSON.parse(event.body) : event.body;
    } catch (parseError) {
        return createErrorResponse(400, 'Invalid JSON in request body');
    }
    
    // Extract and validate required fields
    const {
        entity_type,
        who,
        did,
        this: thisField,
        name,
        description,
        code,
        language,
        runtime,
        input,
        output,
        metadata,
        owner_id,
        tenant_id: bodyTenantId,
        visibility = 'private',
        parent_id,
        related_to
    } = body;
    
    // Validate required fields
    if (!entity_type || !who || !thisField) {
        return createErrorResponse(400, 'Missing required fields: entity_type, who, this');
    }
    
    // Validate field formats
    if (!isValidEntityType(entity_type)) {
        return createErrorResponse(400, 'Invalid entity_type format');
    }
    
    if (!['private', 'tenant', 'public'].includes(visibility)) {
        return createErrorResponse(400, 'Invalid visibility value. Must be: private, tenant, or public');
    }
    
    if (parent_id && !isValidUUID(parent_id)) {
        return createErrorResponse(400, 'Invalid parent_id UUID format');
    }
    
    // Use authenticated user/tenant if not provided
    const finalOwnerId = owner_id || userId;
    const finalTenantId = bodyTenantId || tenantId;
    
    const spanId = require('crypto').randomUUID();
    
    try {
        const result = await client.query(`
            INSERT INTO ledger.universal_registry 
            (id, seq, entity_type, who, did, "this", at, name, description, code, language, runtime,
             input, output, metadata, owner_id, tenant_id, visibility, status, parent_id, related_to)
            VALUES ($1, 0, $2, $3, $4, $5, now(), $6, $7, $8, $9, $10, $11, $12, $13, $14, $15, $16, 'active', $17, $18)
            RETURNING id, seq, entity_type, who, did, "this", at, status, owner_id, tenant_id, visibility
        `, [
            spanId,
            entity_type,
            who,
            did,
            thisField,
            name,
            description,
            code,
            language,
            runtime,
            input ? JSON.stringify(input) : null,
            output ? JSON.stringify(output) : null,
            metadata ? JSON.stringify(metadata) : null,
            finalOwnerId,
            finalTenantId,
            visibility,
            parent_id,
            related_to
        ]);
        
        console.log('Span created successfully', {
            id: spanId,
            entity_type,
            owner_id: finalOwnerId,
            tenant_id: finalTenantId
        });
        
        return createSuccessResponse(201, {
            success: true,
            span: result.rows[0]
        });
    } catch (dbError) {
        console.error('Database error creating span', {
            error: dbError.message,
            entity_type
        });
        
        // Check for specific errors
        if (dbError.code === '23505') {
            return createErrorResponse(409, 'Span already exists');
        }
        
        throw dbError; // Re-throw for general handler
    }
}

/**
 * List spans with filtering and pagination
 */
async function listSpans(event, client) {
    const params = event.queryStringParameters || {};
    
    // Parse and validate pagination parameters
    const limit = Math.min(parseInt(params.limit || '50'), 100); // Max 100
    const offset = Math.max(parseInt(params.offset || '0'), 0);
    const entityType = params.entity_type;
    const status = params.status;
    const ownerId = params.owner_id;
    const visibility = params.visibility;
    
    // Validate filters
    if (entityType && !isValidEntityType(entityType)) {
        return createErrorResponse(400, 'Invalid entity_type format');
    }
    
    if (visibility && !['private', 'tenant', 'public'].includes(visibility)) {
        return createErrorResponse(400, 'Invalid visibility value');
    }
    
    // Build query with parameterized filters
    let query = `
        SELECT id, seq, entity_type, who, did, "this", at, status, 
               owner_id, tenant_id, visibility, name, description, 
               duration_ms, trace_id, parent_id, metadata
        FROM ledger.visible_timeline
        WHERE is_deleted = false
    `;
    const queryParams = [];
    
    if (entityType) {
        queryParams.push(entityType);
        query += ` AND entity_type = $${queryParams.length}`;
    }
    
    if (status) {
        queryParams.push(status);
        query += ` AND status = $${queryParams.length}`;
    }
    
    if (ownerId) {
        queryParams.push(ownerId);
        query += ` AND owner_id = $${queryParams.length}`;
    }
    
    if (visibility) {
        queryParams.push(visibility);
        query += ` AND visibility = $${queryParams.length}`;
    }
    
    // Add ordering and pagination
    query += ` ORDER BY at DESC LIMIT $${queryParams.length + 1} OFFSET $${queryParams.length + 2}`;
    queryParams.push(limit, offset);
    
    try {
        const result = await client.query(query, queryParams);
        
        console.log('Spans listed successfully', {
            count: result.rows.length,
            limit,
            offset,
            filters: { entityType, status, ownerId, visibility }
        });
        
        return createSuccessResponse(200, {
            spans: result.rows,
            count: result.rows.length,
            limit,
            offset,
            has_more: result.rows.length === limit
        });
    } catch (dbError) {
        console.error('Database error listing spans', { error: dbError.message });
        throw dbError;
    }
}

/**
 * Health check endpoint
 */
async function healthCheck(client, startTime) {
    try {
        // Test database connectivity
        await client.query('SELECT 1');
        
        const duration = Date.now() - startTime;
        
        return createSuccessResponse(200, {
            status: 'healthy',
            timestamp: new Date().toISOString(),
            database: 'connected',
            duration_ms: duration,
            environment: process.env.ENVIRONMENT || 'unknown'
        });
    } catch (error) {
        console.error('Health check failed', { error: error.message });
        return createErrorResponse(503, 'Service unhealthy', {
            database: 'disconnected'
        });
    }
}

/**
 * Validation utilities
 */

function isValidUUID(uuid) {
    const uuidRegex = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;
    return uuidRegex.test(uuid);
}

function isValidUserId(userId) {
    return /^[a-z0-9:_-]{1,100}$/i.test(userId);
}

function isValidTenantId(tenantId) {
    return /^[a-z0-9-]{1,50}$/i.test(tenantId);
}

function isValidEntityType(entityType) {
    return /^[a-z0-9_-]{1,50}$/i.test(entityType);
}

function sanitizeRLSValue(value) {
    if (typeof value !== 'string') return String(value);
    return value.replace(/['";\\]/g, '');
}

/**
 * Response utilities
 */

function createErrorResponse(statusCode, message, details = {}) {
    const response = {
        statusCode,
        headers: {
            'Content-Type': 'application/json',
            'X-Request-Time': new Date().toISOString(),
            'Access-Control-Allow-Origin': getAllowedOrigin(),
            'Access-Control-Allow-Methods': 'GET, POST, OPTIONS',
            'Access-Control-Allow-Headers': 'Content-Type, X-User-Id, X-Tenant-Id'
        },
        body: JSON.stringify({
            error: message,
            ...details
        })
    };
    
    console.error('Error response', { statusCode, message, details });
    return response;
}

function createSuccessResponse(statusCode, data) {
    return {
        statusCode,
        headers: {
            'Content-Type': 'application/json',
            'X-Request-Time': new Date().toISOString(),
            'Access-Control-Allow-Origin': getAllowedOrigin(),
            'Access-Control-Allow-Methods': 'GET, POST, OPTIONS',
            'Access-Control-Allow-Headers': 'Content-Type, X-User-Id, X-Tenant-Id'
        },
        body: JSON.stringify(data)
    };
}

function getAllowedOrigin() {
    // Configure based on environment
    const environment = process.env.ENVIRONMENT || 'dev';
    
    // In production, use specific origins
    if (environment === 'production') {
        const allowedOrigins = process.env.ALLOWED_ORIGINS?.split(',') || [];
        // For now, return first origin or reject
        return allowedOrigins[0] || 'https://app.loglineos.com';
    }
    
    // In dev/staging, allow all origins
    return '*';
}

/**
 * Battle-Hardening Utilities (Blueprint4-compliant)
 */

// Get database configuration with caching
async function getDbConfig() {
    const now = Date.now();
    
    // Return cached config if still valid
    if (dbConfigCache && (now - dbConfigCache.timestamp) < DB_CONFIG_CACHE_TTL) {
        return dbConfigCache.config;
    }
    
    // Fetch fresh config with retry logic
    let lastError;
    for (let attempt = 1; attempt <= 3; attempt++) {
        try {
            const dbSecretResponse = await secretsClient.send(
                new GetSecretValueCommand({ SecretId: process.env.DB_SECRET_ARN })
            );
            const config = JSON.parse(dbSecretResponse.SecretString);
            
            // Cache the config
            dbConfigCache = {
                config,
                timestamp: now
            };
            
            return config;
        } catch (error) {
            lastError = error;
            console.error(`Failed to retrieve database credentials (attempt ${attempt}/3)`, { 
                error: error.message 
            });
            
            if (attempt < 3) {
                // Exponential backoff: 100ms, 200ms
                const delay = 100 * Math.pow(2, attempt - 1);
                await new Promise(resolve => setTimeout(resolve, delay));
            }
        }
    }
    
    throw new Error(`Failed to retrieve database credentials after 3 attempts: ${lastError.message}`);
}

// Initialize or get database connection pool
async function getDbPool(dbConfig) {
    if (dbPool) {
        // Test if pool is still healthy
        try {
            const client = await dbPool.connect();
            client.release();
            return dbPool;
        } catch (error) {
            console.warn('Existing pool unhealthy, recreating', { error: error.message });
            try {
                await dbPool.end();
            } catch (endErr) {
                console.error('Error closing pool', { error: endErr.message });
            }
            dbPool = null;
        }
    }
    
    // Create new pool
    dbPool = new Pool({
        host: dbConfig.host.split(':')[0],
        database: dbConfig.database,
        user: dbConfig.username,
        password: dbConfig.password,
        ssl: { rejectUnauthorized: false },
        port: parseInt(dbConfig.port || '5432'),
        // Pool configuration for Lambda
        max: 5, // Max connections (conservative for Lambda)
        min: 1, // Keep at least 1 warm
        idleTimeoutMillis: 30000, // Close idle connections after 30s
        connectionTimeoutMillis: 5000, // Connection timeout
        statement_timeout: 30000, // Query timeout (30s)
    });
    
    // Handle pool errors
    dbPool.on('error', (err) => {
        console.error('Unexpected database pool error', { error: err.message });
    });
    
    return dbPool;
}

// Get database client from pool with retry logic
async function getDbClient(dbConfig) {
    const pool = await getDbPool(dbConfig);
    
    let lastError;
    for (let attempt = 1; attempt <= 3; attempt++) {
        try {
            const client = await pool.connect();
            return client;
        } catch (error) {
            lastError = error;
            console.error(`Failed to acquire database client (attempt ${attempt}/3)`, { 
                error: error.message 
            });
            
            if (attempt < 3) {
                // Exponential backoff: 50ms, 100ms
                const delay = 50 * Math.pow(2, attempt - 1);
                await new Promise(resolve => setTimeout(resolve, delay));
            }
        }
    }
    
    throw new Error(`Failed to acquire database client after 3 attempts: ${lastError.message}`);
}
