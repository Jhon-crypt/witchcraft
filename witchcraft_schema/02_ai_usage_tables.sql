-- ============================================================================
-- Witchcraft AI Usage Tracking Tables
-- Track AI model usage, tokens, and performance (open-source models - no costs)
-- ============================================================================

-- ============================================================================
-- AI PROVIDERS TABLE
-- Track different AI providers (Ollama and other open-source models)
-- ============================================================================
CREATE TABLE ai_providers (
    id SERIAL PRIMARY KEY,
    name VARCHAR(100) NOT NULL UNIQUE, -- 'ollama', 'lmstudio', 'llamacpp', etc.
    display_name VARCHAR(100) NOT NULL,
    is_active BOOLEAN NOT NULL DEFAULT true,
    provider_type VARCHAR(50) NOT NULL DEFAULT 'local', -- 'local', 'self_hosted', 'api'
    
    -- Metadata
    created_at TIMESTAMP WITH TIME ZONE NOT NULL DEFAULT NOW(),
    updated_at TIMESTAMP WITH TIME ZONE NOT NULL DEFAULT NOW()
);

-- Providers will be added automatically as users configure them
-- Example: INSERT INTO ai_providers (name, display_name, provider_type) VALUES ('ollama', 'Ollama', 'local');

-- ============================================================================
-- AI MODELS TABLE
-- Track specific open-source models
-- ============================================================================
CREATE TABLE ai_models (
    id SERIAL PRIMARY KEY,
    provider_id INTEGER NOT NULL REFERENCES ai_providers(id),
    
    -- Model information
    model_name VARCHAR(255) NOT NULL, -- 'llama2', 'mistral', 'codellama', etc.
    display_name VARCHAR(255) NOT NULL,
    model_version VARCHAR(50), -- Optional version tracking
    model_size VARCHAR(50), -- '7B', '13B', '70B', etc.
    
    -- Capabilities
    max_tokens INTEGER,
    supports_streaming BOOLEAN DEFAULT true,
    supports_function_calling BOOLEAN DEFAULT false,
    
    -- Model type
    model_type VARCHAR(50), -- 'chat', 'code', 'instruct', 'base'
    
    -- Status
    is_active BOOLEAN NOT NULL DEFAULT true,
    deprecated_at TIMESTAMP WITH TIME ZONE,
    
    -- Metadata
    created_at TIMESTAMP WITH TIME ZONE NOT NULL DEFAULT NOW(),
    updated_at TIMESTAMP WITH TIME ZONE NOT NULL DEFAULT NOW(),
    
    UNIQUE(provider_id, model_name)
);

-- Models will be added automatically as users use them
-- Example: INSERT INTO ai_models (provider_id, model_name, display_name, model_size, max_tokens, model_type) 
--          VALUES (1, 'llama2', 'Llama 2', '7B', 4096, 'chat');

-- ============================================================================
-- AI USAGE REQUESTS TABLE
-- Track individual AI requests with full details
-- ============================================================================
CREATE TABLE ai_usage_requests (
    id BIGSERIAL PRIMARY KEY,
    user_id BIGINT NOT NULL REFERENCES users(id) ON DELETE CASCADE,
    
    -- Model information
    provider_id INTEGER NOT NULL REFERENCES ai_providers(id),
    model_id INTEGER REFERENCES ai_models(id),
    model_name VARCHAR(255) NOT NULL, -- Denormalized for historical tracking
    
    -- Agent mode (from Witchcraft's agent selector)
    agent_mode VARCHAR(50), -- 'understand', 'debug', 'implement'
    
    -- Request details
    prompt_tokens INTEGER NOT NULL DEFAULT 0,
    completion_tokens INTEGER NOT NULL DEFAULT 0,
    total_tokens INTEGER NOT NULL DEFAULT 0,
    
    -- Performance metrics
    latency_ms INTEGER, -- Response time in milliseconds
    streaming BOOLEAN DEFAULT false,
    
    -- Request metadata
    request_id VARCHAR(255), -- External request ID from provider
    session_id BIGINT, -- Link to agent_sessions if applicable
    
    -- Error tracking
    success BOOLEAN NOT NULL DEFAULT true,
    error_message TEXT,
    error_code VARCHAR(100),
    
    -- Timestamps
    created_at TIMESTAMP WITH TIME ZONE NOT NULL DEFAULT NOW(),
    
    -- Additional metadata (JSON for flexibility)
    metadata JSONB
);

-- Indexes for ai_usage_requests table
CREATE INDEX idx_ai_usage_requests_user_id ON ai_usage_requests(user_id);
CREATE INDEX idx_ai_usage_requests_created_at ON ai_usage_requests(created_at DESC);
CREATE INDEX idx_ai_usage_requests_provider_model ON ai_usage_requests(provider_id, model_id);
CREATE INDEX idx_ai_usage_requests_agent_mode ON ai_usage_requests(agent_mode);
CREATE INDEX idx_ai_usage_requests_session_id ON ai_usage_requests(session_id) WHERE session_id IS NOT NULL;
CREATE INDEX idx_ai_usage_requests_success ON ai_usage_requests(success) WHERE success = false;

-- ============================================================================
-- AI USAGE DAILY TABLE
-- Aggregated daily usage statistics per user
-- ============================================================================
CREATE TABLE ai_usage_daily (
    id BIGSERIAL PRIMARY KEY,
    user_id BIGINT NOT NULL REFERENCES users(id) ON DELETE CASCADE,
    date DATE NOT NULL,
    
    -- Provider and model
    provider_id INTEGER NOT NULL REFERENCES ai_providers(id),
    model_id INTEGER REFERENCES ai_models(id),
    model_name VARCHAR(255) NOT NULL,
    
    -- Agent mode aggregation
    agent_mode VARCHAR(50),
    
    -- Aggregated metrics
    request_count INTEGER NOT NULL DEFAULT 0,
    total_tokens BIGINT NOT NULL DEFAULT 0,
    prompt_tokens BIGINT NOT NULL DEFAULT 0,
    completion_tokens BIGINT NOT NULL DEFAULT 0,
    
    -- Performance metrics
    avg_latency_ms INTEGER,
    success_count INTEGER NOT NULL DEFAULT 0,
    error_count INTEGER NOT NULL DEFAULT 0,
    
    -- Timestamps
    created_at TIMESTAMP WITH TIME ZONE NOT NULL DEFAULT NOW(),
    updated_at TIMESTAMP WITH TIME ZONE NOT NULL DEFAULT NOW(),
    
    UNIQUE(user_id, date, provider_id, model_id, agent_mode)
);

-- Indexes for ai_usage_daily table
CREATE INDEX idx_ai_usage_daily_user_date ON ai_usage_daily(user_id, date DESC);
CREATE INDEX idx_ai_usage_daily_date ON ai_usage_daily(date DESC);
CREATE INDEX idx_ai_usage_daily_provider_model ON ai_usage_daily(provider_id, model_id);

-- ============================================================================
-- AI USAGE MONTHLY TABLE
-- Aggregated monthly usage statistics per user
-- ============================================================================
CREATE TABLE ai_usage_monthly (
    id BIGSERIAL PRIMARY KEY,
    user_id BIGINT NOT NULL REFERENCES users(id) ON DELETE CASCADE,
    year INTEGER NOT NULL,
    month INTEGER NOT NULL,
    
    -- Provider and model
    provider_id INTEGER NOT NULL REFERENCES ai_providers(id),
    model_id INTEGER REFERENCES ai_models(id),
    model_name VARCHAR(255) NOT NULL,
    
    -- Aggregated metrics
    request_count INTEGER NOT NULL DEFAULT 0,
    total_tokens BIGINT NOT NULL DEFAULT 0,
    prompt_tokens BIGINT NOT NULL DEFAULT 0,
    completion_tokens BIGINT NOT NULL DEFAULT 0,
    
    -- Performance metrics
    avg_latency_ms INTEGER,
    success_count INTEGER NOT NULL DEFAULT 0,
    error_count INTEGER NOT NULL DEFAULT 0,
    
    -- Timestamps
    created_at TIMESTAMP WITH TIME ZONE NOT NULL DEFAULT NOW(),
    updated_at TIMESTAMP WITH TIME ZONE NOT NULL DEFAULT NOW(),
    
    UNIQUE(user_id, year, month, provider_id, model_id),
    CONSTRAINT valid_month CHECK (month >= 1 AND month <= 12)
);

-- Indexes for ai_usage_monthly table
CREATE INDEX idx_ai_usage_monthly_user_period ON ai_usage_monthly(user_id, year DESC, month DESC);
CREATE INDEX idx_ai_usage_monthly_period ON ai_usage_monthly(year DESC, month DESC);
CREATE INDEX idx_ai_usage_monthly_provider_model ON ai_usage_monthly(provider_id, model_id);

-- ============================================================================
-- TRIGGERS
-- ============================================================================

-- Update updated_at timestamp automatically
CREATE TRIGGER update_ai_providers_updated_at
    BEFORE UPDATE ON ai_providers
    FOR EACH ROW
    EXECUTE FUNCTION update_updated_at_column();

CREATE TRIGGER update_ai_models_updated_at
    BEFORE UPDATE ON ai_models
    FOR EACH ROW
    EXECUTE FUNCTION update_updated_at_column();

CREATE TRIGGER update_ai_usage_daily_updated_at
    BEFORE UPDATE ON ai_usage_daily
    FOR EACH ROW
    EXECUTE FUNCTION update_updated_at_column();

CREATE TRIGGER update_ai_usage_monthly_updated_at
    BEFORE UPDATE ON ai_usage_monthly
    FOR EACH ROW
    EXECUTE FUNCTION update_updated_at_column();

-- ============================================================================
-- COMMENTS
-- ============================================================================

COMMENT ON TABLE ai_providers IS 'AI service providers (Ollama, LM Studio, etc.)';
COMMENT ON TABLE ai_models IS 'Specific open-source AI models';
COMMENT ON TABLE ai_usage_requests IS 'Individual AI requests with full details';
COMMENT ON TABLE ai_usage_daily IS 'Daily aggregated AI usage statistics';
COMMENT ON TABLE ai_usage_monthly IS 'Monthly aggregated AI usage statistics';

COMMENT ON COLUMN ai_usage_requests.agent_mode IS 'Witchcraft agent mode: understand, debug, or implement';
COMMENT ON COLUMN ai_usage_requests.latency_ms IS 'Response time in milliseconds';

