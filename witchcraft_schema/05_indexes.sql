-- ============================================================================
-- Witchcraft Additional Performance Indexes
-- Composite and specialized indexes for common queries
-- ============================================================================

-- ============================================================================
-- USER QUERIES
-- ============================================================================

-- Find active users with recent activity
CREATE INDEX idx_users_active_recent ON users(is_active, last_login_at DESC) 
    WHERE is_active = true AND deleted_at IS NULL;

-- Admin user lookup
CREATE INDEX idx_users_admin ON users(is_admin) WHERE is_admin = true;

-- ============================================================================
-- AI USAGE QUERIES
-- ============================================================================

-- User's recent AI requests with provider/model
CREATE INDEX idx_ai_usage_user_recent ON ai_usage_requests(user_id, created_at DESC, provider_id, model_id);

-- Failed requests for debugging
CREATE INDEX idx_ai_usage_failures ON ai_usage_requests(created_at DESC, error_code) 
    WHERE success = false;

-- High-cost requests for analysis
CREATE INDEX idx_ai_usage_high_cost ON ai_usage_requests(total_cost_usd DESC, created_at DESC) 
    WHERE total_cost_usd > 0.10;

-- Agent mode performance analysis
CREATE INDEX idx_ai_usage_agent_mode_perf ON ai_usage_requests(agent_mode, latency_ms, created_at DESC) 
    WHERE agent_mode IS NOT NULL;

-- Daily usage summary queries
CREATE INDEX idx_ai_usage_daily_user_recent ON ai_usage_daily(user_id, date DESC, provider_id);

-- Monthly cost analysis
CREATE INDEX idx_ai_usage_monthly_cost ON ai_usage_monthly(user_id, year DESC, month DESC, total_cost_usd DESC);

-- Provider performance comparison
CREATE INDEX idx_ai_usage_provider_comparison ON ai_usage_requests(provider_id, success, latency_ms, created_at DESC);

-- ============================================================================
-- AGENT SESSION QUERIES
-- ============================================================================

-- User's active sessions
CREATE INDEX idx_agent_sessions_user_active ON agent_sessions(user_id, last_activity_at DESC) 
    WHERE is_active = true;

-- Sessions by mode and activity
CREATE INDEX idx_agent_sessions_mode_activity ON agent_sessions(agent_mode, last_activity_at DESC);

-- Recent messages in session
CREATE INDEX idx_agent_messages_session_recent ON agent_messages(session_id, created_at DESC);

-- User's message history
CREATE INDEX idx_agent_messages_user_recent ON agent_messages(user_id, created_at DESC);

-- Assistant messages with AI requests
CREATE INDEX idx_agent_messages_assistant_ai ON agent_messages(role, ai_request_id, created_at DESC) 
    WHERE role = 'assistant' AND ai_request_id IS NOT NULL;

-- Tool usage patterns
CREATE INDEX idx_agent_tools_usage_pattern ON agent_tool_calls(tool_name, success, called_at DESC);

-- Session tool performance
CREATE INDEX idx_agent_tools_session_perf ON agent_tool_calls(session_id, execution_time_ms, called_at DESC);

-- Failed tool calls for debugging
CREATE INDEX idx_agent_tools_failures ON agent_tool_calls(tool_name, error_message, called_at DESC) 
    WHERE success = false;

-- ============================================================================
-- BILLING AND QUOTA QUERIES
-- ============================================================================

-- Active subscriptions expiring soon
CREATE INDEX idx_subscriptions_expiring ON user_subscriptions(current_period_end, status) 
    WHERE status = 'active' AND cancel_at_period_end = false;

-- Cancelled subscriptions
CREATE INDEX idx_subscriptions_cancelled ON user_subscriptions(cancelled_at DESC, status) 
    WHERE status = 'cancelled';

-- Users approaching quota limits
CREATE INDEX idx_quotas_approaching_limit ON user_quotas(
    user_id, 
    (tokens_used::FLOAT / NULLIF(monthly_token_limit, 0))
) WHERE monthly_token_limit IS NOT NULL 
    AND tokens_used::FLOAT / monthly_token_limit > 0.8;

-- Payment failures
CREATE INDEX idx_payments_failed ON payment_history(user_id, payment_date DESC, status) 
    WHERE status IN ('failed', 'pending');

-- Recent successful payments
CREATE INDEX idx_payments_successful ON payment_history(payment_date DESC, amount_usd) 
    WHERE status = 'succeeded';

-- ============================================================================
-- SECURITY AND AUDIT QUERIES
-- ============================================================================

-- Recent access token usage
CREATE INDEX idx_access_tokens_recent_use ON access_tokens(user_id, last_used_at DESC) 
    WHERE revoked_at IS NULL AND expires_at > NOW();

-- Expired tokens cleanup
CREATE INDEX idx_access_tokens_expired ON access_tokens(expires_at) 
    WHERE revoked_at IS NULL AND expires_at < NOW();

-- Audit log by user and action
CREATE INDEX idx_audit_logs_user_action ON audit_logs(user_id, action, created_at DESC);

-- Recent security events
CREATE INDEX idx_audit_logs_security ON audit_logs(action, created_at DESC) 
    WHERE action IN ('login', 'logout', 'password_change', 'email_change', 'token_revoked');

-- Suspicious activity (multiple failed logins)
CREATE INDEX idx_audit_logs_failed_logins ON audit_logs(ip_address, action, created_at DESC) 
    WHERE action = 'login_failed';

-- ============================================================================
-- FEEDBACK AND QUALITY QUERIES
-- ============================================================================

-- Recent negative feedback
CREATE INDEX idx_feedback_negative ON agent_feedback(feedback_type, created_at DESC) 
    WHERE feedback_type IN ('thumbs_down', 'report');

-- Session quality scores
CREATE INDEX idx_feedback_session_quality ON agent_feedback(session_id, rating, created_at DESC) 
    WHERE rating IS NOT NULL;

-- User satisfaction trends
CREATE INDEX idx_feedback_user_trends ON agent_feedback(user_id, feedback_type, created_at DESC);

-- ============================================================================
-- COMPOSITE INDEXES FOR COMPLEX QUERIES
-- ============================================================================

-- User's monthly AI spend by provider
CREATE INDEX idx_ai_spend_analysis ON ai_usage_daily(
    user_id, 
    date, 
    provider_id, 
    total_cost_usd
) WHERE total_cost_usd > 0;

-- Session engagement metrics
CREATE INDEX idx_session_engagement ON agent_sessions(
    user_id,
    agent_mode,
    message_count,
    total_tokens,
    started_at DESC
) WHERE message_count > 0;

-- Model popularity and performance
CREATE INDEX idx_model_popularity ON ai_usage_requests(
    model_id,
    success,
    latency_ms,
    created_at DESC
) WHERE model_id IS NOT NULL;

-- User activity timeline
CREATE INDEX idx_user_activity_timeline ON audit_logs(
    user_id,
    created_at DESC,
    action,
    resource_type
);

-- ============================================================================
-- PARTIAL INDEXES FOR SPECIFIC USE CASES
-- ============================================================================

-- Only track active, non-deleted users
CREATE INDEX idx_users_active_only ON users(id, email, created_at) 
    WHERE is_active = true AND deleted_at IS NULL;

-- Only track valid, non-revoked tokens
CREATE INDEX idx_tokens_valid_only ON access_tokens(token_hash, user_id, last_used_at) 
    WHERE revoked_at IS NULL AND expires_at > NOW();

-- Only track successful AI requests
CREATE INDEX idx_ai_requests_successful ON ai_usage_requests(
    user_id,
    provider_id,
    model_id,
    total_tokens,
    created_at DESC
) WHERE success = true;

-- Only track ongoing sessions
CREATE INDEX idx_sessions_ongoing ON agent_sessions(
    user_id,
    agent_mode,
    last_activity_at DESC
) WHERE is_active = true AND ended_at IS NULL;

-- ============================================================================
-- COVERING INDEXES FOR COMMON QUERIES
-- ============================================================================

-- User dashboard - recent activity summary
CREATE INDEX idx_user_dashboard_activity ON ai_usage_daily(
    user_id,
    date DESC
) INCLUDE (
    provider_id,
    model_name,
    request_count,
    total_tokens,
    total_cost_usd
);

-- Session list with basic info
CREATE INDEX idx_session_list ON agent_sessions(
    user_id,
    started_at DESC
) INCLUDE (
    title,
    agent_mode,
    message_count,
    is_active
);

-- ============================================================================
-- COMMENTS
-- ============================================================================

COMMENT ON INDEX idx_users_active_recent IS 'Find active users with recent login activity';
COMMENT ON INDEX idx_ai_usage_user_recent IS 'User AI usage history with provider/model details';
COMMENT ON INDEX idx_quotas_approaching_limit IS 'Users approaching their quota limits (>80%)';
COMMENT ON INDEX idx_subscriptions_expiring IS 'Active subscriptions expiring soon';
COMMENT ON INDEX idx_audit_logs_security IS 'Security-related audit events';
COMMENT ON INDEX idx_feedback_negative IS 'Negative feedback for quality monitoring';


