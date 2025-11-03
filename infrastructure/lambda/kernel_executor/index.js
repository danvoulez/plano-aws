const { SecretsManagerClient, GetSecretValueCommand } = require('@aws-sdk/client-secrets-manager');
const { Client } = require('pg');

const secretsClient = new SecretsManagerClient({});

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
            await client.end();
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
