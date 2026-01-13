-- ============================================================================
-- Witchcraft Helper Functions and Stored Procedures
-- Utility functions for common operations
-- ============================================================================

-- ============================================================================
-- USER MANAGEMENT FUNCTIONS
-- ============================================================================

-- Function to create a new user with profile
CREATE OR REPLACE FUNCTION create_user_with_profile(
    p_email VARCHAR,
    p_password_hash VARCHAR,
    p_name VARCHAR DEFAULT NULL
)
RETURNS BIGINT AS $$
DECLARE
    v_user_id BIGINT;
BEGIN
    -- Insert user
    INSERT INTO users (email, password_hash, name)
    VALUES (LOWER(p_email), p_password_hash, p_name)
    RETURNING id INTO v_user_id;
    
    -- Create profile
    INSERT INTO user_profiles (user_id)
    VALUES (v_user_id);
    
    -- Create default quota (free tier)
    INSERT INTO user_quotas (
        user_id,
        monthly_token_limit,
        monthly_request_limit,
        current_period_start,
        current_period_end
    )
    SELECT 
        v_user_id,
        monthly_token_limit,
        monthly_request_limit,
        CURRENT_DATE,
        (CURRENT_DATE + INTERVAL '1 month')::DATE
    FROM subscription_tiers
    WHERE name = 'free';
    
    -- Log audit event
    INSERT INTO audit_logs (user_id, action, resource_type, resource_id)
    VALUES (v_user_id, 'user_created', 'user', v_user_id);
    
    RETURN v_user_id;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;

-- Function to validate and consume user quota
CREATE OR REPLACE FUNCTION check_and_consume_quota(
    p_user_id BIGINT,
    p_tokens INTEGER,
    p_cost_usd DECIMAL
)
RETURNS BOOLEAN AS $$
DECLARE
    v_quota RECORD;
    v_can_proceed BOOLEAN := true;
BEGIN
    -- Get current quota
    SELECT * INTO v_quota
    FROM user_quotas
    WHERE user_id = p_user_id
    FOR UPDATE;
    
    -- Check if quota exists
    IF NOT FOUND THEN
        RAISE EXCEPTION 'No quota found for user %', p_user_id;
    END IF;
    
    -- Check token limit
    IF v_quota.monthly_token_limit IS NOT NULL THEN
        IF (v_quota.tokens_used + p_tokens) > v_quota.monthly_token_limit THEN
            v_can_proceed := false;
        END IF;
    END IF;
    
    -- Check cost limit
    IF v_quota.monthly_cost_limit_usd IS NOT NULL THEN
        IF (v_quota.cost_used_usd + p_cost_usd) > v_quota.monthly_cost_limit_usd THEN
            v_can_proceed := false;
        END IF;
    END IF;
    
    -- If can proceed, update usage
    IF v_can_proceed THEN
        UPDATE user_quotas
        SET 
            tokens_used = tokens_used + p_tokens,
            requests_used = requests_used + 1,
            cost_used_usd = cost_used_usd + p_cost_usd,
            updated_at = NOW()
        WHERE user_id = p_user_id;
    END IF;
    
    RETURN v_can_proceed;
END;
$$ LANGUAGE plpgsql;

-- ============================================================================
-- AI USAGE TRACKING FUNCTIONS
-- ============================================================================

-- Function to record AI usage and update aggregations
CREATE OR REPLACE FUNCTION record_ai_usage(
    p_user_id BIGINT,
    p_provider_id INTEGER,
    p_model_id INTEGER,
    p_model_name VARCHAR,
    p_agent_mode VARCHAR,
    p_prompt_tokens INTEGER,
    p_completion_tokens INTEGER,
    p_input_cost_usd DECIMAL,
    p_output_cost_usd DECIMAL,
    p_latency_ms INTEGER DEFAULT NULL,
    p_session_id BIGINT DEFAULT NULL,
    p_success BOOLEAN DEFAULT true,
    p_error_message TEXT DEFAULT NULL
)
RETURNS BIGINT AS $$
DECLARE
    v_request_id BIGINT;
    v_total_tokens INTEGER;
    v_total_cost DECIMAL;
    v_today DATE;
BEGIN
    v_total_tokens := p_prompt_tokens + p_completion_tokens;
    v_total_cost := p_input_cost_usd + p_output_cost_usd;
    v_today := CURRENT_DATE;
    
    -- Insert request
    INSERT INTO ai_usage_requests (
        user_id,
        provider_id,
        model_id,
        model_name,
        agent_mode,
        prompt_tokens,
        completion_tokens,
        total_tokens,
        input_cost_usd,
        output_cost_usd,
        latency_ms,
        session_id,
        success,
        error_message
    ) VALUES (
        p_user_id,
        p_provider_id,
        p_model_id,
        p_model_name,
        p_agent_mode,
        p_prompt_tokens,
        p_completion_tokens,
        v_total_tokens,
        p_input_cost_usd,
        p_output_cost_usd,
        p_latency_ms,
        p_session_id,
        p_success,
        p_error_message
    ) RETURNING id INTO v_request_id;
    
    -- Update daily aggregation
    INSERT INTO ai_usage_daily (
        user_id,
        date,
        provider_id,
        model_id,
        model_name,
        agent_mode,
        request_count,
        total_tokens,
        prompt_tokens,
        completion_tokens,
        total_cost_usd,
        success_count,
        error_count
    ) VALUES (
        p_user_id,
        v_today,
        p_provider_id,
        p_model_id,
        p_model_name,
        p_agent_mode,
        1,
        v_total_tokens,
        p_prompt_tokens,
        p_completion_tokens,
        v_total_cost,
        CASE WHEN p_success THEN 1 ELSE 0 END,
        CASE WHEN p_success THEN 0 ELSE 1 END
    )
    ON CONFLICT (user_id, date, provider_id, model_id, agent_mode)
    DO UPDATE SET
        request_count = ai_usage_daily.request_count + 1,
        total_tokens = ai_usage_daily.total_tokens + v_total_tokens,
        prompt_tokens = ai_usage_daily.prompt_tokens + p_prompt_tokens,
        completion_tokens = ai_usage_daily.completion_tokens + p_completion_tokens,
        total_cost_usd = ai_usage_daily.total_cost_usd + v_total_cost,
        success_count = ai_usage_daily.success_count + CASE WHEN p_success THEN 1 ELSE 0 END,
        error_count = ai_usage_daily.error_count + CASE WHEN p_success THEN 0 ELSE 1 END,
        updated_at = NOW();
    
    -- Update monthly aggregation
    INSERT INTO ai_usage_monthly (
        user_id,
        year,
        month,
        provider_id,
        model_id,
        model_name,
        request_count,
        total_tokens,
        prompt_tokens,
        completion_tokens,
        total_cost_usd,
        success_count,
        error_count
    ) VALUES (
        p_user_id,
        EXTRACT(YEAR FROM v_today)::INTEGER,
        EXTRACT(MONTH FROM v_today)::INTEGER,
        p_provider_id,
        p_model_id,
        p_model_name,
        1,
        v_total_tokens,
        p_prompt_tokens,
        p_completion_tokens,
        v_total_cost,
        CASE WHEN p_success THEN 1 ELSE 0 END,
        CASE WHEN p_success THEN 0 ELSE 1 END
    )
    ON CONFLICT (user_id, year, month, provider_id, model_id)
    DO UPDATE SET
        request_count = ai_usage_monthly.request_count + 1,
        total_tokens = ai_usage_monthly.total_tokens + v_total_tokens,
        prompt_tokens = ai_usage_monthly.prompt_tokens + p_prompt_tokens,
        completion_tokens = ai_usage_monthly.completion_tokens + p_completion_tokens,
        total_cost_usd = ai_usage_monthly.total_cost_usd + v_total_cost,
        success_count = ai_usage_monthly.success_count + CASE WHEN p_success THEN 1 ELSE 0 END,
        error_count = ai_usage_monthly.error_count + CASE WHEN p_success THEN 0 ELSE 1 END,
        updated_at = NOW();
    
    RETURN v_request_id;
END;
$$ LANGUAGE plpgsql;

-- ============================================================================
-- QUOTA MANAGEMENT FUNCTIONS
-- ============================================================================

-- Function to reset monthly quotas
CREATE OR REPLACE FUNCTION reset_monthly_quotas()
RETURNS INTEGER AS $$
DECLARE
    v_count INTEGER;
BEGIN
    UPDATE user_quotas
    SET 
        tokens_used = 0,
        requests_used = 0,
        cost_used_usd = 0.0,
        current_period_start = CURRENT_DATE,
        current_period_end = (CURRENT_DATE + INTERVAL '1 month')::DATE,
        updated_at = NOW()
    WHERE current_period_end <= CURRENT_DATE;
    
    GET DIAGNOSTICS v_count = ROW_COUNT;
    
    -- Log audit event
    INSERT INTO audit_logs (action, resource_type, metadata)
    VALUES ('quota_reset', 'system', jsonb_build_object('users_reset', v_count));
    
    RETURN v_count;
END;
$$ LANGUAGE plpgsql;

-- Function to get user's remaining quota
CREATE OR REPLACE FUNCTION get_remaining_quota(p_user_id BIGINT)
RETURNS TABLE (
    tokens_remaining BIGINT,
    requests_remaining INTEGER,
    cost_remaining_usd DECIMAL,
    usage_percentage DECIMAL
) AS $$
BEGIN
    RETURN QUERY
    SELECT 
        CASE 
            WHEN q.monthly_token_limit IS NULL THEN NULL
            ELSE GREATEST(0, q.monthly_token_limit - q.tokens_used)
        END as tokens_remaining,
        CASE 
            WHEN q.monthly_request_limit IS NULL THEN NULL
            ELSE GREATEST(0, q.monthly_request_limit - q.requests_used)
        END as requests_remaining,
        CASE 
            WHEN q.monthly_cost_limit_usd IS NULL THEN NULL
            ELSE GREATEST(0, q.monthly_cost_limit_usd - q.cost_used_usd)
        END as cost_remaining_usd,
        CASE 
            WHEN q.monthly_token_limit IS NULL OR q.monthly_token_limit = 0 THEN 0
            ELSE ROUND((q.tokens_used::DECIMAL / q.monthly_token_limit * 100), 2)
        END as usage_percentage
    FROM user_quotas q
    WHERE q.user_id = p_user_id;
END;
$$ LANGUAGE plpgsql STABLE;

-- ============================================================================
-- SESSION MANAGEMENT FUNCTIONS
-- ============================================================================

-- Function to end inactive sessions
CREATE OR REPLACE FUNCTION end_inactive_sessions(p_inactive_hours INTEGER DEFAULT 24)
RETURNS INTEGER AS $$
DECLARE
    v_count INTEGER;
BEGIN
    UPDATE agent_sessions
    SET 
        is_active = false,
        ended_at = NOW()
    WHERE 
        is_active = true
        AND ended_at IS NULL
        AND last_activity_at < (NOW() - (p_inactive_hours || ' hours')::INTERVAL);
    
    GET DIAGNOSTICS v_count = ROW_COUNT;
    
    RETURN v_count;
END;
$$ LANGUAGE plpgsql;

-- ============================================================================
-- CLEANUP FUNCTIONS
-- ============================================================================

-- Function to cleanup expired tokens
CREATE OR REPLACE FUNCTION cleanup_expired_tokens()
RETURNS INTEGER AS $$
DECLARE
    v_count INTEGER;
BEGIN
    DELETE FROM access_tokens
    WHERE expires_at < NOW()
    AND revoked_at IS NULL;
    
    GET DIAGNOSTICS v_count = ROW_COUNT;
    
    DELETE FROM password_reset_tokens
    WHERE expires_at < NOW()
    AND used_at IS NULL;
    
    DELETE FROM email_verification_tokens
    WHERE expires_at < NOW()
    AND used_at IS NULL;
    
    RETURN v_count;
END;
$$ LANGUAGE plpgsql;

-- Function to cleanup old audit logs
CREATE OR REPLACE FUNCTION cleanup_old_audit_logs(p_days_to_keep INTEGER DEFAULT 90)
RETURNS INTEGER AS $$
DECLARE
    v_count INTEGER;
BEGIN
    DELETE FROM audit_logs
    WHERE created_at < (NOW() - (p_days_to_keep || ' days')::INTERVAL);
    
    GET DIAGNOSTICS v_count = ROW_COUNT;
    
    RETURN v_count;
END;
$$ LANGUAGE plpgsql;

-- ============================================================================
-- ANALYTICS FUNCTIONS
-- ============================================================================

-- Function to get user activity summary
CREATE OR REPLACE FUNCTION get_user_activity_summary(
    p_user_id BIGINT,
    p_days INTEGER DEFAULT 30
)
RETURNS TABLE (
    total_requests INTEGER,
    total_tokens BIGINT,
    total_cost_usd DECIMAL,
    active_sessions INTEGER,
    total_messages INTEGER,
    avg_session_length_minutes DECIMAL
) AS $$
BEGIN
    RETURN QUERY
    SELECT 
        COALESCE(SUM(d.request_count), 0)::INTEGER as total_requests,
        COALESCE(SUM(d.total_tokens), 0) as total_tokens,
        COALESCE(SUM(d.total_cost_usd), 0.0) as total_cost_usd,
        COUNT(DISTINCT s.id)::INTEGER as active_sessions,
        COALESCE(SUM(s.message_count), 0)::INTEGER as total_messages,
        ROUND(AVG(
            EXTRACT(EPOCH FROM (COALESCE(s.ended_at, NOW()) - s.started_at)) / 60
        ), 2) as avg_session_length_minutes
    FROM users u
    LEFT JOIN ai_usage_daily d ON u.id = d.user_id 
        AND d.date >= CURRENT_DATE - p_days
    LEFT JOIN agent_sessions s ON u.id = s.user_id 
        AND s.started_at >= CURRENT_DATE - p_days
    WHERE u.id = p_user_id
    GROUP BY u.id;
END;
$$ LANGUAGE plpgsql STABLE;

-- Function to get top models by usage
CREATE OR REPLACE FUNCTION get_top_models_by_usage(
    p_limit INTEGER DEFAULT 10,
    p_days INTEGER DEFAULT 30
)
RETURNS TABLE (
    model_name VARCHAR,
    provider_name VARCHAR,
    total_requests BIGINT,
    total_tokens BIGINT,
    total_cost_usd DECIMAL,
    avg_latency_ms INTEGER
) AS $$
BEGIN
    RETURN QUERY
    SELECT 
        r.model_name,
        p.display_name as provider_name,
        COUNT(*)::BIGINT as total_requests,
        SUM(r.total_tokens)::BIGINT as total_tokens,
        SUM(r.total_cost_usd) as total_cost_usd,
        AVG(r.latency_ms)::INTEGER as avg_latency_ms
    FROM ai_usage_requests r
    JOIN ai_providers p ON r.provider_id = p.id
    WHERE r.created_at >= CURRENT_DATE - p_days
    AND r.success = true
    GROUP BY r.model_name, p.display_name
    ORDER BY total_requests DESC
    LIMIT p_limit;
END;
$$ LANGUAGE plpgsql STABLE;

-- ============================================================================
-- SCHEDULED JOBS (to be run via cron or pg_cron)
-- ============================================================================

-- Daily cleanup job
CREATE OR REPLACE FUNCTION daily_maintenance()
RETURNS VOID AS $$
BEGIN
    PERFORM cleanup_expired_tokens();
    PERFORM end_inactive_sessions(24);
    RAISE NOTICE 'Daily maintenance completed';
END;
$$ LANGUAGE plpgsql;

-- Monthly quota reset job
CREATE OR REPLACE FUNCTION monthly_maintenance()
RETURNS VOID AS $$
BEGIN
    PERFORM reset_monthly_quotas();
    RAISE NOTICE 'Monthly maintenance completed';
END;
$$ LANGUAGE plpgsql;

-- ============================================================================
-- COMMENTS
-- ============================================================================

COMMENT ON FUNCTION create_user_with_profile IS 'Create a new user with profile and default quota';
COMMENT ON FUNCTION check_and_consume_quota IS 'Check if user has quota available and consume it';
COMMENT ON FUNCTION record_ai_usage IS 'Record AI usage and update daily/monthly aggregations';
COMMENT ON FUNCTION reset_monthly_quotas IS 'Reset all user quotas at the start of the month';
COMMENT ON FUNCTION get_remaining_quota IS 'Get user remaining quota and usage percentage';
COMMENT ON FUNCTION end_inactive_sessions IS 'End sessions that have been inactive for specified hours';
COMMENT ON FUNCTION cleanup_expired_tokens IS 'Delete expired access tokens and verification tokens';
COMMENT ON FUNCTION cleanup_old_audit_logs IS 'Delete audit logs older than specified days';
COMMENT ON FUNCTION get_user_activity_summary IS 'Get user activity summary for specified period';
COMMENT ON FUNCTION get_top_models_by_usage IS 'Get most popular AI models by usage';
COMMENT ON FUNCTION daily_maintenance IS 'Run daily maintenance tasks';
COMMENT ON FUNCTION monthly_maintenance IS 'Run monthly maintenance tasks (quota reset)';

