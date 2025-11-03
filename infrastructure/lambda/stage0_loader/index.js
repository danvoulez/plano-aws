const { SecretsManagerClient, GetSecretValueCommand } = require('@aws-sdk/client-secrets-manager');
const { StepFunctionsClient, StartExecutionCommand } = require('@aws-sdk/client-step-functions');
const { Client } = require('pg');
const { blake3 } = require('@noble/hashes/blake3');
const ed = require('@noble/ed25519');

const secretsClient = new SecretsManagerClient({});
const sfnClient = new StepFunctionsClient({});

exports.handler = async (event) => {
    console.log('Stage-0 Loader invoked:', JSON.stringify(event));
    
    try {
        // Parse request body
        const body = typeof event.body === 'string' ? JSON.parse(event.body) : event.body;
        const { boot_function_id, user_id, tenant_id, trace_id } = body;
        
        if (!boot_function_id) {
            return {
                statusCode: 400,
                body: JSON.stringify({ error: 'boot_function_id is required' })
            };
        }
        
        // Get database credentials from Secrets Manager
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
            // Set session variables for RLS
            await client.query('SET app.user_id = $1', [user_id || 'edge:stage0']);
            if (tenant_id) {
                await client.query('SET app.tenant_id = $1', [tenant_id]);
            }
            
            // Fetch manifest
            const manifestResult = await client.query(`
                SELECT * FROM ledger.universal_registry 
                WHERE entity_type='manifest' 
                ORDER BY at DESC LIMIT 1
            `);
            
            const manifest = manifestResult.rows[0] || { metadata: {} };
            const allowedBootIds = manifest.metadata?.allowed_boot_ids || [];
            
            // For dev environment, allow all boot IDs if manifest is empty
            if (process.env.ENVIRONMENT !== 'production' && allowedBootIds.length === 0) {
                console.log('Dev environment: allowing boot without manifest validation');
            } else if (!allowedBootIds.includes(boot_function_id)) {
                return {
                    statusCode: 403,
                    body: JSON.stringify({ error: 'BOOT_FUNCTION_ID not allowed by manifest' })
                };
            }
            
            // Fetch function to execute
            const fnResult = await client.query(`
                SELECT * FROM ledger.universal_registry 
                WHERE id=$1 AND entity_type='function'
                ORDER BY at DESC, seq DESC LIMIT 1
            `, [boot_function_id]);
            
            const fnSpan = fnResult.rows[0];
            if (!fnSpan) {
                return {
                    statusCode: 404,
                    body: JSON.stringify({ error: 'Function span not found' })
                };
            }
            
            // Verify signature if present
            if (fnSpan.signature && fnSpan.public_key) {
                const verified = await verifySpan(fnSpan);
                if (!verified) {
                    return {
                        statusCode: 403,
                        body: JSON.stringify({ error: 'Invalid signature' })
                    };
                }
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
            
            return {
                statusCode: 200,
                body: JSON.stringify({
                    success: true,
                    boot_event_id: bootEventId,
                    function_id: boot_function_id,
                    message: 'Boot event recorded successfully'
                })
            };
            
        } finally {
            await client.end();
        }
        
    } catch (error) {
        console.error('Error in Stage-0 Loader:', error);
        return {
            statusCode: 500,
            body: JSON.stringify({ 
                error: 'Internal server error',
                message: error.message 
            })
        };
    }
};

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
