# Blueprint4 Database Seeds

This directory contains SQL seed data files that implement the LogLineOS Blueprint4 specification.

## Files

### blueprint4_kernels.sql

Implements the five core execution kernels and governance manifest from Blueprint4:

1. **run_code_kernel** (`00000000-0000-4000-8000-000000000001`, seq=2)
   - Core execution kernel with sandboxed code execution
   - Advisory locking for concurrency control
   - Quota enforcement (per-tenant daily limits)
   - Signature verification (BLAKE3 + Ed25519)
   - Slow execution detection and marking

2. **observer_bot_kernel** (`00000000-0000-4000-8000-000000000002`, seq=2)
   - Monitors timeline for scheduled function spans
   - Creates request spans for execution
   - Idempotent scheduling via unique constraints
   - Respects throttle limits

3. **request_worker_kernel** (`00000000-0000-4000-8000-000000000003`, seq=2)
   - Processes scheduled request spans
   - Loads and executes target kernels
   - FIFO processing with advisory locks
   - Batch processing (8 requests per invocation)

4. **policy_agent_kernel** (`00000000-0000-4000-8000-000000000004`, seq=1)
   - Evaluates policy spans against timeline events
   - Sandboxed policy execution (Web Worker isolation)
   - Cursor-based timeline processing
   - Error observability via policy_error spans

5. **provider_exec_kernel** (`00000000-0000-4000-8000-000000000005`, seq=1)
   - Executes external provider calls (OpenAI, Ollama, etc.)
   - Supports multiple provider types
   - Emits provider_execution spans with results
   - API key management via environment

6. **kernel_manifest** (`00000000-0000-4000-8000-0000000000aa`, seq=2)
   - Governance and configuration for all kernels
   - Whitelisted boot IDs for security
   - Throttle limits and policies
   - Admin override public key

## Architecture Philosophy

All business logic lives in the ledger as versioned spans (entity_type='function', seq↑). The Stage-0 loader is a fixed, immutable bootstrap that:

1. Validates boot requests against manifest
2. Verifies cryptographic signatures
3. Executes whitelisted kernel code
4. Records all outputs as signed, append-only events

This implements the "code lives in the ledger" principle from Blueprint4.

## Usage

These seeds are automatically applied during database migration. The handler.py script loads and executes this file after creating the schema.

To manually apply:

```bash
psql $DATABASE_URL -f blueprint4_kernels.sql
```

## ON CONFLICT Behavior

All INSERT statements use `ON CONFLICT (id, seq) DO UPDATE` to allow:
- Idempotent migrations (can run multiple times safely)
- Kernel upgrades by incrementing seq while preserving ID
- Code updates without changing the governance structure

## Kernel IDs

All kernel IDs are stable and referenced in the manifest's `allowed_boot_ids`:

- `00000000-0000-4000-8000-000000000001` - run_code_kernel
- `00000000-0000-4000-8000-000000000002` - observer_bot_kernel  
- `00000000-0000-4000-8000-000000000003` - request_worker_kernel
- `00000000-0000-4000-8000-000000000004` - policy_agent_kernel
- `00000000-0000-4000-8000-000000000005` - provider_exec_kernel
- `00000000-0000-4000-8000-0000000000ff` - stage0_loader
- `00000000-0000-4000-8000-0000000000aa` - kernel_manifest

## Security

- All kernels execute in sandboxed environments (Web Workers, Deno isolates)
- Cryptographic verification (BLAKE3 hashing, Ed25519 signatures)
- Advisory locks prevent race conditions
- Row-Level Security (RLS) enforces tenant isolation
- Manifest whitelist prevents unauthorized kernel execution

## Extending

To add new kernels:

1. Create a new INSERT with a unique stable ID
2. Increment seq for upgrades to existing kernels
3. Add the ID to manifest's allowed_boot_ids
4. Register in manifest's kernels mapping
5. Test execution via Stage-0 loader

## References

- Blueprint4.md - Full specification (3455 lines)
- plano-aws.md - AWS deployment adaptation
- infrastructure/lambda/stage0_loader - Bootstrap implementation
