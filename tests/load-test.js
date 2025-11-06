/**
 * Load Test for LogLineOS Battle-Hardened Lambdas
 * 
 * Usage: API_ENDPOINT=https://your-api.com CONCURRENT=50 TOTAL=200 node tests/load-test.js
 */

const https = require('https');

const API_ENDPOINT = process.env.API_ENDPOINT || 'https://your-api-gateway-url.execute-api.region.amazonaws.com/dev';
const CONCURRENT_REQUESTS = parseInt(process.env.CONCURRENT || '50');
const TOTAL_REQUESTS = parseInt(process.env.TOTAL || '200');

const testFunctionId = '00000000-0000-4000-8000-000000000001';

const metrics = {
    total: 0,
    success: 0,
    error: 0,
    durations: [],
    errors: {}
};

function makeRequest() {
    return new Promise((resolve) => {
        const startTime = Date.now();
        
        const postData = JSON.stringify({
            boot_function_id: testFunctionId,
            user_id: 'loadtest:user',
            tenant_id: 'loadtest',
            trace_id: `loadtest-${Date.now()}-${Math.random()}`
        });
        
        const url = new URL(API_ENDPOINT + '/boot');
        const options = {
            method: 'POST',
            hostname: url.hostname,
            path: url.pathname + url.search,
            headers: {
                'Content-Type': 'application/json',
                'Content-Length': Buffer.byteLength(postData)
            }
        };
        
        const req = https.request(options, (res) => {
            let data = '';
            res.on('data', (chunk) => { data += chunk; });
            res.on('end', () => {
                const duration = Date.now() - startTime;
                if (res.statusCode >= 200 && res.statusCode < 300) {
                    metrics.success++;
                    metrics.durations.push(duration);
                } else {
                    metrics.error++;
                    metrics.errors[`HTTP_${res.statusCode}`] = (metrics.errors[`HTTP_${res.statusCode}`] || 0) + 1;
                }
                resolve({ success: res.statusCode < 300, duration });
            });
        });
        
        req.on('error', (error) => {
            metrics.error++;
            metrics.errors[error.code || 'UNKNOWN'] = (metrics.errors[error.code || 'UNKNOWN'] || 0) + 1;
            resolve({ success: false, duration: Date.now() - startTime });
        });
        
        req.write(postData);
        req.end();
    });
}

async function runLoadTest() {
    console.log('🚀 LogLineOS Load Test');
    console.log(`   Endpoint: ${API_ENDPOINT}`);
    console.log(`   Concurrent: ${CONCURRENT_REQUESTS}, Total: ${TOTAL_REQUESTS}\n`);
    
    const startTime = Date.now();
    const batches = Math.ceil(TOTAL_REQUESTS / CONCURRENT_REQUESTS);
    
    for (let batch = 0; batch < batches; batch++) {
        const batchSize = Math.min(CONCURRENT_REQUESTS, TOTAL_REQUESTS - metrics.total);
        await Promise.all(Array(batchSize).fill(0).map(() => makeRequest()));
        metrics.total += batchSize;
        process.stdout.write(`\r   Progress: ${((metrics.total / TOTAL_REQUESTS) * 100).toFixed(1)}%`);
    }
    
    const totalDuration = Date.now() - startTime;
    const sorted = metrics.durations.sort((a, b) => a - b);
    
    console.log('\n\n📊 Results');
    console.log('═'.repeat(60));
    console.log(`Requests:  ${metrics.total} (${metrics.success} success, ${metrics.error} failed)`);
    if (sorted.length > 0) {
        console.log(`Latency:   avg=${(sorted.reduce((a,b)=>a+b,0)/sorted.length).toFixed(0)}ms p50=${sorted[Math.floor(sorted.length*0.5)]}ms p95=${sorted[Math.floor(sorted.length*0.95)]}ms`);
    }
    console.log(`Duration:  ${(totalDuration/1000).toFixed(2)}s (${(metrics.total/(totalDuration/1000)).toFixed(2)} req/s)`);
    if (Object.keys(metrics.errors).length > 0) {
        console.log(`Errors:    ${JSON.stringify(metrics.errors)}`);
    }
    console.log('═'.repeat(60));
}

runLoadTest().catch(console.error);
