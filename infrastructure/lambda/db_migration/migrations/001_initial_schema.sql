-- 001_initial_schema.sql
-- LogLineOS Initial Database Schema for Local Development

-- Create schemas
CREATE SCHEMA IF NOT EXISTS app;
CREATE SCHEMA IF NOT EXISTS ledger;

-- Create session functions for RLS
CREATE OR REPLACE FUNCTION app.current_user_id() 
RETURNS text LANGUAGE sql STABLE AS 
$$ SELECT current_setting('app.user_id', true) $$;

CREATE OR REPLACE FUNCTION app.current_tenant_id() 
RETURNS text LANGUAGE sql STABLE AS 
$$ SELECT current_setting('app.tenant_id', true) $$;

-- Install pgvector extension for memory embeddings
CREATE EXTENSION IF NOT EXISTS vector;

-- Create universal_registry table with 70 semantic columns
CREATE TABLE IF NOT EXISTS ledger.universal_registry (
    id            uuid        NOT NULL,
    seq           integer     NOT NULL,
    entity_type   text        NOT NULL,
    who           text        NOT NULL,
    did           text,
    "this"        text        NOT NULL,
    at            timestamptz NOT NULL DEFAULT now(),
    
    -- Relationships
    parent_id     uuid,
    related_to    uuid[],
    
    -- Access control
    owner_id      text,
    tenant_id     text,
    visibility    text        NOT NULL DEFAULT 'private',
    
    -- Lifecycle
    status        text,
    is_deleted    boolean     NOT NULL DEFAULT false,
    
    -- Code & Execution
    name          text,
    description   text,
    code          text,
    language      text,
    runtime       text,
    input         jsonb,
    output        jsonb,
    error         jsonb,
    
    -- Quantitative/metrics
    duration_ms   integer,
    trace_id      text,
    
    -- Crypto proofs
    prev_hash     text,
    curr_hash     text,
    signature     text,
    public_key    text,
    
    -- Extensibility
    metadata      jsonb,
    
    PRIMARY KEY (id, seq),
    CONSTRAINT ck_visibility CHECK (visibility IN ('private','tenant','public')),
    CONSTRAINT ck_append_only CHECK (seq >= 0)
);

-- Create indexes for performance
CREATE INDEX IF NOT EXISTS ur_idx_at ON ledger.universal_registry (at DESC);
CREATE INDEX IF NOT EXISTS ur_idx_entity ON ledger.universal_registry (entity_type, at DESC);
CREATE INDEX IF NOT EXISTS ur_idx_owner_tenant ON ledger.universal_registry (owner_id, tenant_id);
CREATE INDEX IF NOT EXISTS ur_idx_trace ON ledger.universal_registry (trace_id);
CREATE INDEX IF NOT EXISTS ur_idx_parent ON ledger.universal_registry (parent_id);
CREATE INDEX IF NOT EXISTS ur_idx_related ON ledger.universal_registry USING GIN (related_to);
CREATE INDEX IF NOT EXISTS ur_idx_metadata ON ledger.universal_registry USING GIN (metadata);

-- Enable Row-Level Security
ALTER TABLE ledger.universal_registry ENABLE ROW LEVEL SECURITY;

-- Create RLS policies
DROP POLICY IF EXISTS ur_select_policy ON ledger.universal_registry;
DROP POLICY IF EXISTS ur_insert_policy ON ledger.universal_registry;

CREATE POLICY ur_select_policy ON ledger.universal_registry
FOR SELECT USING (
    (owner_id IS NOT DISTINCT FROM app.current_user_id())
    OR (visibility = 'public')
    OR (tenant_id IS NOT DISTINCT FROM app.current_tenant_id() 
        AND visibility IN ('tenant','public'))
);

CREATE POLICY ur_insert_policy ON ledger.universal_registry
FOR INSERT WITH CHECK (
    owner_id IS NOT DISTINCT FROM app.current_user_id()
    AND (tenant_id IS NULL OR tenant_id IS NOT DISTINCT FROM app.current_tenant_id())
);

-- Create memory embeddings table
CREATE TABLE IF NOT EXISTS ledger.memory_embeddings (
    span_id uuid PRIMARY KEY,
    tenant_id text,
    dim int DEFAULT 1536,
    embedding vector(1536),
    created_at timestamptz DEFAULT now()
);

CREATE INDEX IF NOT EXISTS mem_idx_tenant ON ledger.memory_embeddings (tenant_id, created_at DESC);

-- Create helper view for visible timeline
CREATE OR REPLACE VIEW ledger.visible_timeline AS
SELECT * FROM ledger.universal_registry
WHERE is_deleted = false;

-- Grant permissions for local development
GRANT USAGE ON SCHEMA app TO loglineos;
GRANT USAGE ON SCHEMA ledger TO loglineos;
GRANT ALL ON ALL TABLES IN SCHEMA ledger TO loglineos;
GRANT ALL ON ALL SEQUENCES IN SCHEMA ledger TO loglineos;

-- Success message
DO $$
BEGIN
    RAISE NOTICE 'LogLineOS schema initialized successfully!';
    RAISE NOTICE 'Schemas: app, ledger';
    RAISE NOTICE 'Tables: universal_registry, memory_embeddings';
    RAISE NOTICE 'Extensions: vector';
END $$;
