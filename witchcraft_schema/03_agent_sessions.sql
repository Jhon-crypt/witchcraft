-- ============================================================================
-- Witchcraft Agent Sessions Tables
-- Track agent conversations, messages, and interactions
-- ============================================================================

-- ============================================================================
-- AGENT SESSIONS TABLE
-- Track individual agent conversation sessions
-- ============================================================================
CREATE TABLE agent_sessions (
    id BIGSERIAL PRIMARY KEY,
    user_id BIGINT NOT NULL REFERENCES users(id) ON DELETE CASCADE,
    
    -- Session metadata
    title VARCHAR(500), -- Optional session title
    agent_mode VARCHAR(50) NOT NULL, -- 'understand', 'debug', 'implement'
    
    -- Project context
    project_path TEXT, -- Path to the project being worked on
    project_name VARCHAR(255),
    
    -- Session status
    is_active BOOLEAN NOT NULL DEFAULT true,
    
    -- Timestamps
    started_at TIMESTAMP WITH TIME ZONE NOT NULL DEFAULT NOW(),
    ended_at TIMESTAMP WITH TIME ZONE,
    last_activity_at TIMESTAMP WITH TIME ZONE NOT NULL DEFAULT NOW(),
    
    -- Aggregated metrics (updated via triggers)
    message_count INTEGER NOT NULL DEFAULT 0,
    total_tokens BIGINT NOT NULL DEFAULT 0,
    total_cost_usd DECIMAL(12, 6) NOT NULL DEFAULT 0.0,
    
    -- Additional metadata
    metadata JSONB,
    
    CONSTRAINT valid_session_period CHECK (ended_at IS NULL OR ended_at >= started_at)
);

-- Indexes for agent_sessions table
CREATE INDEX idx_agent_sessions_user_id ON agent_sessions(user_id);
CREATE INDEX idx_agent_sessions_started_at ON agent_sessions(started_at DESC);
CREATE INDEX idx_agent_sessions_agent_mode ON agent_sessions(agent_mode);
CREATE INDEX idx_agent_sessions_is_active ON agent_sessions(is_active) WHERE is_active = true;
CREATE INDEX idx_agent_sessions_last_activity ON agent_sessions(last_activity_at DESC);

-- ============================================================================
-- AGENT MESSAGES TABLE
-- Individual messages within agent sessions
-- ============================================================================
CREATE TABLE agent_messages (
    id BIGSERIAL PRIMARY KEY,
    session_id BIGINT NOT NULL REFERENCES agent_sessions(id) ON DELETE CASCADE,
    user_id BIGINT NOT NULL REFERENCES users(id) ON DELETE CASCADE,
    
    -- Message details
    role VARCHAR(50) NOT NULL, -- 'user', 'assistant', 'system'
    content TEXT NOT NULL,
    
    -- AI request tracking (if this message triggered an AI request)
    ai_request_id BIGINT REFERENCES ai_usage_requests(id),
    
    -- Token usage for this message
    tokens INTEGER,
    cost_usd DECIMAL(10, 6),
    
    -- Message metadata
    sequence_number INTEGER NOT NULL, -- Order within the session
    parent_message_id BIGINT REFERENCES agent_messages(id), -- For threaded conversations
    
    -- Timestamps
    created_at TIMESTAMP WITH TIME ZONE NOT NULL DEFAULT NOW(),
    
    -- Additional metadata (attachments, code blocks, etc.)
    metadata JSONB,
    
    CONSTRAINT valid_role CHECK (role IN ('user', 'assistant', 'system'))
);

-- Indexes for agent_messages table
CREATE INDEX idx_agent_messages_session_id ON agent_messages(session_id, sequence_number);
CREATE INDEX idx_agent_messages_user_id ON agent_messages(user_id);
CREATE INDEX idx_agent_messages_created_at ON agent_messages(created_at DESC);
CREATE INDEX idx_agent_messages_ai_request_id ON agent_messages(ai_request_id) WHERE ai_request_id IS NOT NULL;
CREATE INDEX idx_agent_messages_parent_id ON agent_messages(parent_message_id) WHERE parent_message_id IS NOT NULL;

-- ============================================================================
-- AGENT TOOLS TABLE
-- Track tool/function calls made by agents
-- ============================================================================
CREATE TABLE agent_tool_calls (
    id BIGSERIAL PRIMARY KEY,
    session_id BIGINT NOT NULL REFERENCES agent_sessions(id) ON DELETE CASCADE,
    message_id BIGINT REFERENCES agent_messages(id) ON DELETE CASCADE,
    user_id BIGINT NOT NULL REFERENCES users(id) ON DELETE CASCADE,
    
    -- Tool information
    tool_name VARCHAR(255) NOT NULL, -- 'read_file', 'edit_file', 'run_command', etc.
    tool_category VARCHAR(100), -- 'file_operations', 'code_analysis', 'terminal', etc.
    
    -- Tool execution
    input_parameters JSONB, -- Tool input
    output_result JSONB, -- Tool output
    
    -- Execution status
    success BOOLEAN NOT NULL DEFAULT true,
    error_message TEXT,
    execution_time_ms INTEGER,
    
    -- Timestamps
    called_at TIMESTAMP WITH TIME ZONE NOT NULL DEFAULT NOW(),
    completed_at TIMESTAMP WITH TIME ZONE,
    
    CONSTRAINT valid_execution_time CHECK (completed_at IS NULL OR completed_at >= called_at)
);

-- Indexes for agent_tool_calls table
CREATE INDEX idx_agent_tool_calls_session_id ON agent_tool_calls(session_id);
CREATE INDEX idx_agent_tool_calls_user_id ON agent_tool_calls(user_id);
CREATE INDEX idx_agent_tool_calls_tool_name ON agent_tool_calls(tool_name);
CREATE INDEX idx_agent_tool_calls_called_at ON agent_tool_calls(called_at DESC);
CREATE INDEX idx_agent_tool_calls_success ON agent_tool_calls(success) WHERE success = false;

-- ============================================================================
-- AGENT FEEDBACK TABLE
-- User feedback on agent responses
-- ============================================================================
CREATE TABLE agent_feedback (
    id BIGSERIAL PRIMARY KEY,
    user_id BIGINT NOT NULL REFERENCES users(id) ON DELETE CASCADE,
    session_id BIGINT NOT NULL REFERENCES agent_sessions(id) ON DELETE CASCADE,
    message_id BIGINT REFERENCES agent_messages(id) ON DELETE SET NULL,
    
    -- Feedback type
    feedback_type VARCHAR(50) NOT NULL, -- 'thumbs_up', 'thumbs_down', 'report'
    
    -- Feedback details
    rating INTEGER, -- 1-5 scale
    comment TEXT,
    
    -- Categories (for negative feedback)
    issue_category VARCHAR(100), -- 'incorrect', 'unhelpful', 'offensive', 'other'
    
    -- Timestamps
    created_at TIMESTAMP WITH TIME ZONE NOT NULL DEFAULT NOW(),
    
    -- Additional metadata
    metadata JSONB,
    
    CONSTRAINT valid_rating CHECK (rating IS NULL OR (rating >= 1 AND rating <= 5)),
    CONSTRAINT valid_feedback_type CHECK (feedback_type IN ('thumbs_up', 'thumbs_down', 'report', 'rating'))
);

-- Indexes for agent_feedback table
CREATE INDEX idx_agent_feedback_user_id ON agent_feedback(user_id);
CREATE INDEX idx_agent_feedback_session_id ON agent_feedback(session_id);
CREATE INDEX idx_agent_feedback_message_id ON agent_feedback(message_id) WHERE message_id IS NOT NULL;
CREATE INDEX idx_agent_feedback_type ON agent_feedback(feedback_type);
CREATE INDEX idx_agent_feedback_created_at ON agent_feedback(created_at DESC);

-- ============================================================================
-- AGENT SESSION STATS TABLE
-- Pre-computed statistics for sessions (for performance)
-- ============================================================================
CREATE TABLE agent_session_stats (
    session_id BIGINT PRIMARY KEY REFERENCES agent_sessions(id) ON DELETE CASCADE,
    
    -- Message statistics
    user_message_count INTEGER NOT NULL DEFAULT 0,
    assistant_message_count INTEGER NOT NULL DEFAULT 0,
    system_message_count INTEGER NOT NULL DEFAULT 0,
    
    -- Tool usage statistics
    tool_call_count INTEGER NOT NULL DEFAULT 0,
    successful_tool_calls INTEGER NOT NULL DEFAULT 0,
    failed_tool_calls INTEGER NOT NULL DEFAULT 0,
    
    -- AI usage statistics
    total_ai_requests INTEGER NOT NULL DEFAULT 0,
    total_tokens BIGINT NOT NULL DEFAULT 0,
    total_cost_usd DECIMAL(12, 6) NOT NULL DEFAULT 0.0,
    
    -- Feedback statistics
    positive_feedback_count INTEGER NOT NULL DEFAULT 0,
    negative_feedback_count INTEGER NOT NULL DEFAULT 0,
    
    -- Performance metrics
    avg_response_time_ms INTEGER,
    
    -- Timestamps
    updated_at TIMESTAMP WITH TIME ZONE NOT NULL DEFAULT NOW()
);

-- ============================================================================
-- FUNCTIONS AND TRIGGERS
-- ============================================================================

-- Function to update session last_activity_at
CREATE OR REPLACE FUNCTION update_session_last_activity()
RETURNS TRIGGER AS $$
BEGIN
    UPDATE agent_sessions
    SET last_activity_at = NOW()
    WHERE id = NEW.session_id;
    RETURN NEW;
END;
$$ LANGUAGE plpgsql;

-- Trigger to update session activity on new messages
CREATE TRIGGER update_session_activity_on_message
    AFTER INSERT ON agent_messages
    FOR EACH ROW
    EXECUTE FUNCTION update_session_last_activity();

-- Trigger to update session activity on tool calls
CREATE TRIGGER update_session_activity_on_tool
    AFTER INSERT ON agent_tool_calls
    FOR EACH ROW
    EXECUTE FUNCTION update_session_last_activity();

-- Function to increment session message count
CREATE OR REPLACE FUNCTION increment_session_message_count()
RETURNS TRIGGER AS $$
BEGIN
    UPDATE agent_sessions
    SET message_count = message_count + 1
    WHERE id = NEW.session_id;
    RETURN NEW;
END;
$$ LANGUAGE plpgsql;

-- Trigger to increment message count
CREATE TRIGGER increment_message_count_on_insert
    AFTER INSERT ON agent_messages
    FOR EACH ROW
    EXECUTE FUNCTION increment_session_message_count();

-- Function to update session totals
CREATE OR REPLACE FUNCTION update_session_totals()
RETURNS TRIGGER AS $$
BEGIN
    IF NEW.tokens IS NOT NULL AND NEW.cost_usd IS NOT NULL THEN
        UPDATE agent_sessions
        SET 
            total_tokens = total_tokens + NEW.tokens,
            total_cost_usd = total_cost_usd + NEW.cost_usd
        WHERE id = NEW.session_id;
    END IF;
    RETURN NEW;
END;
$$ LANGUAGE plpgsql;

-- Trigger to update session totals on message insert
CREATE TRIGGER update_session_totals_on_message
    AFTER INSERT ON agent_messages
    FOR EACH ROW
    EXECUTE FUNCTION update_session_totals();

-- ============================================================================
-- COMMENTS
-- ============================================================================

COMMENT ON TABLE agent_sessions IS 'Individual agent conversation sessions';
COMMENT ON TABLE agent_messages IS 'Messages within agent sessions (user, assistant, system)';
COMMENT ON TABLE agent_tool_calls IS 'Tool/function calls made by agents during sessions';
COMMENT ON TABLE agent_feedback IS 'User feedback on agent responses';
COMMENT ON TABLE agent_session_stats IS 'Pre-computed statistics for agent sessions';

COMMENT ON COLUMN agent_sessions.agent_mode IS 'Witchcraft agent mode: understand, debug, or implement';
COMMENT ON COLUMN agent_messages.sequence_number IS 'Message order within the session';
COMMENT ON COLUMN agent_messages.parent_message_id IS 'For threaded conversations';
COMMENT ON COLUMN agent_tool_calls.tool_name IS 'Name of the tool/function called (e.g., read_file, edit_file)';
COMMENT ON COLUMN agent_feedback.feedback_type IS 'Type of feedback: thumbs_up, thumbs_down, report, or rating';

