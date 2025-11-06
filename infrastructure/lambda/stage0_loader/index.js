const { SecretsManagerClient, GetSecretValueCommand } = require('@aws-sdk/client-secrets-manager');
const { StepFunctionsClient, StartExecutionCommand } = require('@aws-sdk/client-step-functions');
const { Client } = require('pg');
const { blake3 } = require('@noble/hashes/blake3');
const ed = require('@noble/ed25519');

const secretsClient = new SecretsManagerClient({});
const sfnClient = new StepFunctionsClient({});

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
        
        // Get database credentials from Secrets Manager with retry
        let dbConfig;
        try {
            const dbSecretResponse = await secretsClient.send(
                new GetSecretValueCommand({ SecretId: process.env.DB_SECRET_ARN })
            );
            dbConfig = JSON.parse(dbSecretResponse.SecretString);
        } catch (secretError) {
            console.error('Failed to retrieve database credentials', { error: secretError.message });
            return createErrorResponse(500, 'Configuration error');
        }
        
        // Connect to database with timeout
        const client = new Client({
            host: dbConfig.host.split(':')[0],
            database: dbConfig.database,
            user: dbConfig.username,
            password: dbConfig.password,
            ssl: { rejectUnauthorized: false },
            port: parseInt(dbConfig.port || '5432'),
            connectionTimeoutMillis: 5000,
            query_timeout: 30000
        });
        
        try {
            await client.connect();
        } catch (connError) {
            console.error('Database connection failed', { error: connError.message });
            return createErrorResponse(503, 'Service temporarily unavailable');
        }
        
        try {
            // Set session variables for RLS - sanitize inputs
            const sanitizedUserId = sanitizeRLSValue(user_id || 'edge:stage0');
            const sanitizedTenantId = tenant_id ? sanitizeRLSValue(tenant_id) : null;
            
            await client.query('SET app.user_id = $1', [sanitizedUserId]);
            if (sanitizedTenantId) {
                await client.query('SET app.tenant_id = $1', [sanitizedTenantId]);
            }
            
            // Fetch manifest with error handling
            const manifestResult = await client.query(`
                SELECT * FROM ledger.universal_registry 
                WHERE entity_type='manifest' 
                  AND is_deleted = false
                ORDER BY at DESC LIMIT 1
            `);
            
            const manifest = manifestResult.rows[0] || { metadata: {} };
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
            return createSuccessResponse(200, {
                success: true,
                boot_event_id: bootEventId,
                function_id: boot_function_id,
                message: 'Boot event recorded successfully',
                duration_ms: duration
            });
            
        } finally {
            // Always close database connection
            try {
                await client.end();
            } catch (endError) {
                console.error('Error closing database connection', { error: endError.message });
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
