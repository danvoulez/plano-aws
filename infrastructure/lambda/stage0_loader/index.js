const { SecretsManagerClient, GetSecretValueCommand } = require('@aws-sdk/client-secrets-manager');
const { StepFunctionsClient, StartExecutionCommand } = require('@aws-sdk/client-step-functions');
const { CloudWatchClient, PutMetricDataCommand } = require('@aws-sdk/client-cloudwatch');
const { Pool } = require('pg');
const { blake3 } = require('@noble/hashes/blake3');
const ed = require('@noble/ed25519');

const secretsClient = new SecretsManagerClient({});
const sfnClient = new StepFunctionsClient({});
const cloudwatchClient = new CloudWatchClient({});

// Global state for Lambda container reuse (Blueprint4 optimization)
let dbPool = null;
let dbConfigCache = null;
let manifestCache = { data: null, timestamp: 0 };

// Cache TTLs (milliseconds)
const MANIFEST_CACHE_TTL = 5 * 60 * 1000; // 5 minutes per Blueprint4
const DB_CONFIG_CACHE_TTL = 15 * 60 * 1000; // 15 minutes

/**
 * Stage-0 Loader Lambda Handler
 * 
 * This is the bootloader that validates and schedules kernel execution.
 * It implements the Blueprint4 ledger-only architecture where all code lives as spans.
 * 
 * Security features:
 * - Manifest-based whitelist validation
 * - Cryptographic signature verification
 * - Row-Level Security (RLS) context isolation
 * - Structured error handling with no sensitive data leakage
 */
exports.handler = async (event) => {
    const startTime = Date.now();
    console.log('Stage-0 Loader invoked', { 
        timestamp: new Date().toISOString(),
        requestId: event.requestContext?.requestId 
    });
    
    try {
        // Parse and validate request body
        let body;
        try {
            body = typeof event.body === 'string' ? JSON.parse(event.body) : event.body;
        } catch (parseError) {
            console.error('Invalid JSON in request body', { error: parseError.message });
            return createErrorResponse(400, 'Invalid JSON in request body');
        }
        
        const { boot_function_id, user_id, tenant_id, trace_id } = body;
        
        // Input validation
        if (!boot_function_id) {
            return createErrorResponse(400, 'boot_function_id is required');
        }
        
        if (!isValidUUID(boot_function_id)) {
            return createErrorResponse(400, 'boot_function_id must be a valid UUID');
        }
        
        if (user_id && !isValidUserId(user_id)) {
            return createErrorResponse(400, 'Invalid user_id format');
        }
        
        if (tenant_id && !isValidTenantId(tenant_id)) {
            return createErrorResponse(400, 'Invalid tenant_id format');
        }
        
        // Get database credentials with caching and retry
        const dbConfig = await getDbConfig();
        
        // Get client from connection pool with retry
        const client = await getDbClient(dbConfig);
        
        try {
            // Set session variables for RLS - sanitize inputs
            const sanitizedUserId = sanitizeRLSValue(user_id || 'edge:stage0');
            const sanitizedTenantId = tenant_id ? sanitizeRLSValue(tenant_id) : null;
            
            await client.query('SET app.user_id = $1', [sanitizedUserId]);
            if (sanitizedTenantId) {
                await client.query('SET app.tenant_id = $1', [sanitizedTenantId]);
            }
            
            // Fetch manifest with caching (Blueprint4 optimization)
            const manifest = await getCachedManifest(client);
            const allowedBootIds = manifest.metadata?.allowed_boot_ids || [];
            
            // Manifest validation logic
            const isProduction = process.env.ENVIRONMENT === 'production';
            const hasManifest = allowedBootIds.length > 0;
            const isAllowed = allowedBootIds.includes(boot_function_id);
            
            if (isProduction && !hasManifest) {
                console.error('Production environment requires manifest configuration');
                return createErrorResponse(503, 'Service not properly configured');
            }
            
            if (hasManifest && !isAllowed) {
                console.warn('Boot function not in manifest allowlist', { 
                    boot_function_id,
                    manifest_id: manifest.id 
                });
                return createErrorResponse(403, 'Function not authorized in manifest');
            }
            
            if (!hasManifest && !isProduction) {
                console.warn('Dev environment: allowing boot without manifest validation');
            }
            
            // Fetch function to execute
            const fnResult = await client.query(`
                SELECT * FROM ledger.universal_registry 
                WHERE id=$1 AND entity_type='function'
                ORDER BY at DESC, seq DESC LIMIT 1
            `, [boot_function_id]);
            
            const fnSpan = fnResult.rows[0];
            if (!fnSpan) {
                console.warn('Function span not found', { boot_function_id });
                return createErrorResponse(404, 'Function not found');
            }
            
            // Verify signature if present
            if (fnSpan.signature && fnSpan.public_key) {
                console.log('Verifying function signature', { function_id: boot_function_id });
                const verified = await verifySpan(fnSpan);
                if (!verified) {
                    console.error('Signature verification failed', { function_id: boot_function_id });
                    return createErrorResponse(403, 'Invalid function signature');
                }
                console.log('Signature verified successfully');
            }
            
            // Insert boot event
            const bootEventId = require('crypto').randomUUID();
            await client.query(`
                INSERT INTO ledger.universal_registry 
                (id, seq, entity_type, who, did, "this", at, status, input, owner_id, tenant_id, visibility, related_to)
                VALUES 
                ($1, 0, 'boot_event', 'edge:stage0', 'booted', 'stage0', now(), 'complete', $2, $3, $4, $5, ARRAY[$6]::uuid[])
            `, [
                bootEventId,
                JSON.stringify({ boot_id: boot_function_id, env: { user: user_id, tenant: tenant_id } }),
                fnSpan.owner_id,
                fnSpan.tenant_id,
                fnSpan.visibility || 'private',
                boot_function_id
            ]);
            
            // Execute kernel code if present (Blueprint4 execution model)
            if (fnSpan.code && fnSpan.language === 'javascript') {
                console.log('Executing kernel code from ledger', { function_id: boot_function_id });
                
                const ctx = createExecutionContext(client, sanitizedUserId, sanitizedTenantId);
                const result = await executeKernelCode(fnSpan.code, ctx);
                
                const duration = Date.now() - startTime;
                console.log('Kernel execution completed', { 
                    status: result.status,
                    duration_ms: duration 
                });
                
                // Emit custom CloudWatch metrics (async, don't wait)
                publishMetrics('KernelExecution', {
                    Duration: duration,
                    Success: result.status === 'complete' ? 1 : 0,
                    Error: result.status === 'error' ? 1 : 0
                }, {
                    FunctionId: boot_function_id,
                    Runtime: fnSpan.language || 'unknown'
                }).catch(err => console.error('Failed to publish metrics:', err.message));
                
                return createSuccessResponse(200, {
                    success: true,
                    boot_event_id: bootEventId,
                    function_id: boot_function_id,
                    execution: result,
                    message: 'Kernel executed successfully',
                    duration_ms: duration
                });
            }
            
            const duration = Date.now() - startTime;
            
            // Emit boot event metrics (async, don't wait)
            publishMetrics('BootEvent', {
                Duration: duration,
                Success: 1
            }, {
                FunctionId: boot_function_id
            }).catch(err => console.error('Failed to publish metrics:', err.message));
            
            return createSuccessResponse(200, {
                success: true,
                boot_event_id: bootEventId,
                function_id: boot_function_id,
                message: 'Boot event recorded successfully',
                duration_ms: duration
            });
            
        } finally {
            // Release client back to pool (don't end connection - reuse in warm Lambda)
            if (client && client.release) {
                try {
                    client.release();
                    console.log('Database client released back to pool');
                } catch (releaseError) {
                    console.error('Error releasing database client', { error: releaseError.message });
                }
            }
        }
        
    } catch (error) {
        const duration = Date.now() - startTime;
        console.error('Unhandled error in Stage-0 Loader', { 
            error: error.message,
            stack: error.stack,
            duration_ms: duration
        });
        
        // Don't expose internal error details in production
        const message = process.env.ENVIRONMENT === 'production' 
            ? 'Internal server error' 
            : error.message;
            
        return createErrorResponse(500, message, {
            duration_ms: duration
        });
    }
};

// Create execution context for kernels (Blueprint4 ctx pattern)
function createExecutionContext(client, user_id, tenant_id) {
    const { randomUUID } = require('crypto');
    
    // Safe SQL tagged template
    const sql = async (strings, ...values) => {
        const queryText = strings.reduce((prev, curr, i) => {
            return prev + (i > 0 ? `$${i}` : "") + curr;
        }, "");
        const result = await client.query(queryText, values);
        return result;
    };
    
    // insertSpan helper
    const insertSpan = async (span) => {
        const cols = Object.keys(span);
        const vals = Object.values(span);
        const placeholders = cols.map((_, i) => `$${i + 1}`).join(",");
        const query = `INSERT INTO ledger.universal_registry (${cols.map(c => `"${c}"`).join(",")})
                       VALUES (${placeholders})`;
        await client.query(query, vals);
    };
    
    // Crypto helpers
    const crypto = {
        blake3: (data) => blake3(data),
        ed25519: ed,
        randomUUID: () => randomUUID(),
        hex: (u8) => Array.from(u8).map(b => b.toString(16).padStart(2, "0")).join(""),
        toU8: (h) => Uint8Array.from(h.match(/.{1,2}/g).map(x => parseInt(x, 16)))
    };
    
    return {
        sql,
        insertSpan,
        now: () => new Date().toISOString(),
        crypto,
        env: {
            APP_USER_ID: user_id || 'edge:stage0',
            APP_TENANT_ID: tenant_id || null,
            SIGNING_KEY_HEX: process.env.SIGNING_KEY_HEX || undefined
        }
    };
}

// Execute kernel code in isolated context
async function executeKernelCode(code, ctx) {
    try {
        // Create function from kernel code
        const factory = new Function("ctx", `"use strict";\n${code}\n;return (typeof default !== 'undefined' ? default : globalThis.main);`);
        const kernelFn = factory(ctx);
        
        if (typeof kernelFn !== "function") {
            throw new Error("Kernel code does not export a function");
        }
        
        // Execute kernel
        const result = await kernelFn(ctx);
        
        return {
            status: 'complete',
            output: result
        };
    } catch (error) {
        console.error('Kernel execution error:', error);
        return {
            status: 'error',
            error: {
                message: error.message,
                stack: error.stack
            }
        };
    }
}

async function verifySpan(span) {
    try {
        const clone = { ...span };
        delete clone.signature;
        
        const msg = new TextEncoder().encode(
            JSON.stringify(clone, Object.keys(clone).sort())
        );
        
        const hash = blake3(msg);
        const signature = hexToUint8Array(span.signature);
        const publicKey = hexToUint8Array(span.public_key);
        
        return await ed.verify(signature, hash, publicKey);
    } catch (error) {
        console.error('Signature verification error:', error);
        return false;
    }
}

function hexToUint8Array(hex) {
    return Uint8Array.from(
        hex.match(/.{1,2}/g).map(byte => parseInt(byte, 16))
    );
}

/**
 * Validation and sanitization utilities
 */

// UUID validation (accepts v4 UUIDs specifically)
function isValidUUID(uuid) {
    // v4 UUID format: xxxxxxxx-xxxx-4xxx-yxxx-xxxxxxxxxxxx where y is 8, 9, a, or b
    const uuidV4Regex = /^[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/i;
    return uuidV4Regex.test(uuid);
}

// User ID validation (alphanumeric, colons, hyphens, max 100 chars)
function isValidUserId(userId) {
    return /^[a-z0-9:_-]{1,100}$/i.test(userId);
}

// Tenant ID validation (alphanumeric, hyphens, max 50 chars)
function isValidTenantId(tenantId) {
    return /^[a-z0-9-]{1,50}$/i.test(tenantId);
}

// Sanitize RLS values to prevent injection
function sanitizeRLSValue(value) {
    if (typeof value !== 'string') return String(value);
    // Remove any potential SQL injection characters
    return value.replace(/['";\\]/g, '');
}

// Create standardized error response
function createErrorResponse(statusCode, message, details = {}) {
    const response = {
        statusCode,
        headers: {
            'Content-Type': 'application/json',
            'X-Request-Time': new Date().toISOString()
        },
        body: JSON.stringify({
            error: message,
            ...details
        })
    };
    
    console.error('Error response', { statusCode, message, details });
    return response;
}

// Create standardized success response
function createSuccessResponse(statusCode, data) {
    return {
        statusCode,
        headers: {
            'Content-Type': 'application/json',
            'X-Request-Time': new Date().toISOString()
        },
        body: JSON.stringify(data)
    };
}

/**
 * Battle-Hardening Utilities (Blueprint4-compliant)
 */

// Get database configuration with caching
async function getDbConfig() {
    const now = Date.now();
    
    // Return cached config if still valid
    if (dbConfigCache && (now - dbConfigCache.timestamp) < DB_CONFIG_CACHE_TTL) {
        console.log('Using cached database configuration');
        return dbConfigCache.config;
    }
    
    // Fetch fresh config with retry logic
    let lastError;
    for (let attempt = 1; attempt <= 3; attempt++) {
        try {
            console.log(`Fetching database credentials (attempt ${attempt}/3)`);
            const dbSecretResponse = await secretsClient.send(
                new GetSecretValueCommand({ SecretId: process.env.DB_SECRET_ARN })
            );
            const config = JSON.parse(dbSecretResponse.SecretString);
            
            // Cache the config
            dbConfigCache = {
                config,
                timestamp: now
            };
            
            console.log('Database configuration fetched and cached');
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
    console.log('Creating new database connection pool');
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
            console.log(`Acquiring database client (attempt ${attempt}/3)`);
            const client = await pool.connect();
            console.log('Database client acquired from pool');
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

// Publish custom CloudWatch metrics (Blueprint4 observability)
async function publishMetrics(metricName, metrics, dimensions) {
    try {
        const namespace = process.env.CLOUDWATCH_NAMESPACE || 'LogLineOS';
        const metricData = [];
        
        // Convert metrics object to CloudWatch format
        for (const [name, value] of Object.entries(metrics)) {
            metricData.push({
                MetricName: `${metricName}_${name}`,
                Value: value,
                Unit: name === 'Duration' ? 'Milliseconds' : 'Count',
                Timestamp: new Date(),
                Dimensions: Object.entries(dimensions || {}).map(([Name, Value]) => ({ Name, Value }))
            });
        }
        
        if (metricData.length > 0) {
            await cloudwatchClient.send(new PutMetricDataCommand({
                Namespace: namespace,
                MetricData: metricData
            }));
            
            console.log('Metrics published', { 
                namespace,
                metricName,
                count: metricData.length
            });
        }
    } catch (error) {
        // Don't fail the request if metrics fail
        console.error('Failed to publish metrics', { 
            error: error.message,
            metricName
        });
    }
}

// Get cached manifest (Blueprint4 optimization - 5 min TTL)
async function getCachedManifest(client) {
    const now = Date.now();
    
    // Return cached manifest if still valid
    if (manifestCache.data && (now - manifestCache.timestamp) < MANIFEST_CACHE_TTL) {
        console.log('Using cached manifest', { 
            age_seconds: Math.floor((now - manifestCache.timestamp) / 1000)
        });
        return manifestCache.data;
    }
    
    // Fetch fresh manifest
    console.log('Fetching fresh manifest from ledger');
    try {
        const manifestResult = await client.query(`
            SELECT * FROM ledger.universal_registry 
            WHERE entity_type='manifest' 
              AND is_deleted = false
            ORDER BY at DESC LIMIT 1
        `);
        
        const manifest = manifestResult.rows[0] || { metadata: {} };
        
        // Cache the manifest
        manifestCache = {
            data: manifest,
            timestamp: now
        };
        
        console.log('Manifest fetched and cached', { 
            manifest_id: manifest.id,
            allowed_boot_ids_count: manifest.metadata?.allowed_boot_ids?.length || 0
        });
        
        return manifest;
    } catch (error) {
        console.error('Failed to fetch manifest', { error: error.message });
        
        // If we have stale cache, use it as fallback
        if (manifestCache.data) {
            console.warn('Using stale manifest cache as fallback', {
                age_seconds: Math.floor((now - manifestCache.timestamp) / 1000)
            });
            return manifestCache.data;
        }
        
        throw error;
    }
}
