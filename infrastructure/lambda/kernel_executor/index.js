const { SecretsManagerClient, GetSecretValueCommand } = require('@aws-sdk/client-secrets-manager');
const { Pool } = require('pg');

const secretsClient = new SecretsManagerClient({});

// Global state for Lambda container reuse (Blueprint4 optimization)
let dbPool = null;
let dbConfigCache = null;

// Cache TTLs (milliseconds)
const DB_CONFIG_CACHE_TTL = 15 * 60 * 1000; // 15 minutes

exports.handler = async (event) => {
    console.log('Kernel Executor invoked:', JSON.stringify(event));
    
    try {
        const { kernel_id, code, runtime, input, context } = event;
        
        if (!kernel_id || !code) {
            return {
                statusCode: 400,
                error: 'Missing required fields: kernel_id, code'
            };
        }
        
        // Get database credentials with caching and retry
        const dbConfig = await getDbConfig();
        
        // Get client from connection pool with retry
        const client = await getDbClient(dbConfig);
        
        try {
            // Set RLS context
            if (context?.user_id) {
                await client.query('SET app.user_id = $1', [context.user_id]);
            }
            if (context?.tenant_id) {
                await client.query('SET app.tenant_id = $1', [context.tenant_id]);
            }
            
            const startTime = Date.now();
            
            // In a full implementation, this would execute the kernel code
            // in an isolated Deno runtime. For now, we'll just log it.
            console.log(`Executing kernel ${kernel_id} with runtime ${runtime}`);
            
            const output = {
                message: 'Kernel execution placeholder',
                kernel_id,
                runtime,
                executed_at: new Date().toISOString()
            };
            
            const durationMs = Date.now() - startTime;
            
            // Record execution in ledger
            const executionId = require('crypto').randomUUID();
            await client.query(`
                INSERT INTO ledger.universal_registry 
                (id, seq, entity_type, who, did, "this", at, status, input, output, duration_ms, trace_id, owner_id, tenant_id, visibility, related_to)
                VALUES ($1, 0, 'kernel_execution', 'kernel:executor', 'executed', $2, now(), 'complete', $3, $4, $5, $6, $7, $8, 'private', ARRAY[$9]::uuid[])
            `, [
                executionId,
                `kernel.${kernel_id}`,
                JSON.stringify(input || {}),
                JSON.stringify(output),
                durationMs,
                context?.trace_id || executionId,
                context?.user_id,
                context?.tenant_id,
                kernel_id
            ]);
            
            return {
                statusCode: 200,
                execution_id: executionId,
                output,
                duration_ms: durationMs
            };
            
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
        console.error('Error in Kernel Executor:', error);
        return {
            statusCode: 500,
            error: 'Kernel execution failed',
            message: error.message
        };
    }
};

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
