-- ============================================================================
-- Witchcraft Row Level Security (RLS) Policies
-- Secure data access at the database level
-- ============================================================================

-- ============================================================================
-- ENABLE RLS ON ALL TABLES
-- ============================================================================

ALTER TABLE users ENABLE ROW LEVEL SECURITY;
ALTER TABLE user_profiles ENABLE ROW LEVEL SECURITY;
ALTER TABLE access_tokens ENABLE ROW LEVEL SECURITY;
ALTER TABLE password_reset_tokens ENABLE ROW LEVEL SECURITY;
ALTER TABLE email_verification_tokens ENABLE ROW LEVEL SECURITY;
ALTER TABLE audit_logs ENABLE ROW LEVEL SECURITY;

ALTER TABLE ai_providers ENABLE ROW LEVEL SECURITY;
ALTER TABLE ai_models ENABLE ROW LEVEL SECURITY;
ALTER TABLE ai_usage_requests ENABLE ROW LEVEL SECURITY;
ALTER TABLE ai_usage_daily ENABLE ROW LEVEL SECURITY;
ALTER TABLE ai_usage_monthly ENABLE ROW LEVEL SECURITY;

ALTER TABLE agent_sessions ENABLE ROW LEVEL SECURITY;
ALTER TABLE agent_messages ENABLE ROW LEVEL SECURITY;
ALTER TABLE agent_tool_calls ENABLE ROW LEVEL SECURITY;
ALTER TABLE agent_feedback ENABLE ROW LEVEL SECURITY;
ALTER TABLE agent_session_stats ENABLE ROW LEVEL SECURITY;

ALTER TABLE subscription_tiers ENABLE ROW LEVEL SECURITY;
ALTER TABLE user_subscriptions ENABLE ROW LEVEL SECURITY;
ALTER TABLE user_quotas ENABLE ROW LEVEL SECURITY;
ALTER TABLE payment_history ENABLE ROW LEVEL SECURITY;
ALTER TABLE usage_alerts ENABLE ROW LEVEL SECURITY;

-- ============================================================================
-- HELPER FUNCTIONS FOR RLS
-- ============================================================================

-- Get current user ID from JWT or session
CREATE OR REPLACE FUNCTION auth.user_id() 
RETURNS BIGINT AS $$
    SELECT NULLIF(current_setting('request.jwt.claims', true)::json->>'user_id', '')::BIGINT;
$$ LANGUAGE SQL STABLE;

-- Check if current user is admin
CREATE OR REPLACE FUNCTION auth.is_admin() 
RETURNS BOOLEAN AS $$
    SELECT EXISTS (
        SELECT 1 FROM users 
        WHERE id = auth.user_id() 
        AND is_admin = true 
        AND is_active = true
    );
$$ LANGUAGE SQL STABLE SECURITY DEFINER;

-- Check if user owns the resource
CREATE OR REPLACE FUNCTION auth.owns_resource(resource_user_id BIGINT) 
RETURNS BOOLEAN AS $$
    SELECT resource_user_id = auth.user_id();
$$ LANGUAGE SQL STABLE;

-- ============================================================================
-- USERS TABLE POLICIES
-- ============================================================================

-- Users can view their own profile
CREATE POLICY users_select_own 
    ON users FOR SELECT 
    USING (id = auth.user_id());

-- Admins can view all users
CREATE POLICY users_select_admin 
    ON users FOR SELECT 
    USING (auth.is_admin());

-- Users can update their own profile (except admin flag)
CREATE POLICY users_update_own 
    ON users FOR UPDATE 
    USING (id = auth.user_id())
    WITH CHECK (
        id = auth.user_id() 
        AND is_admin = (SELECT is_admin FROM users WHERE id = auth.user_id())
    );

-- Only admins can insert users (or use service role)
CREATE POLICY users_insert_admin 
    ON users FOR INSERT 
    WITH CHECK (auth.is_admin());

-- Admins can update any user
CREATE POLICY users_update_admin 
    ON users FOR UPDATE 
    USING (auth.is_admin());

-- Admins can delete users (soft delete)
CREATE POLICY users_delete_admin 
    ON users FOR DELETE 
    USING (auth.is_admin());

-- ============================================================================
-- USER PROFILES TABLE POLICIES
-- ============================================================================

-- Users can view and update their own profile
CREATE POLICY user_profiles_own 
    ON user_profiles FOR ALL 
    USING (user_id = auth.user_id())
    WITH CHECK (user_id = auth.user_id());

-- Admins can view all profiles
CREATE POLICY user_profiles_admin 
    ON user_profiles FOR SELECT 
    USING (auth.is_admin());

-- ============================================================================
-- ACCESS TOKENS TABLE POLICIES
-- ============================================================================

-- Users can view their own tokens
CREATE POLICY access_tokens_select_own 
    ON access_tokens FOR SELECT 
    USING (user_id = auth.user_id());

-- Users can delete (revoke) their own tokens
CREATE POLICY access_tokens_delete_own 
    ON access_tokens FOR DELETE 
    USING (user_id = auth.user_id());

-- Admins can view and manage all tokens
CREATE POLICY access_tokens_admin 
    ON access_tokens FOR ALL 
    USING (auth.is_admin());

-- ============================================================================
-- AI PROVIDERS AND MODELS POLICIES
-- ============================================================================

-- Everyone can view active providers and models
CREATE POLICY ai_providers_select_all 
    ON ai_providers FOR SELECT 
    USING (is_active = true);

CREATE POLICY ai_models_select_all 
    ON ai_models FOR SELECT 
    USING (is_active = true);

-- Only admins can modify providers and models
CREATE POLICY ai_providers_admin 
    ON ai_providers FOR ALL 
    USING (auth.is_admin());

CREATE POLICY ai_models_admin 
    ON ai_models FOR ALL 
    USING (auth.is_admin());

-- ============================================================================
-- AI USAGE TRACKING POLICIES
-- ============================================================================

-- Users can view their own AI usage
CREATE POLICY ai_usage_requests_select_own 
    ON ai_usage_requests FOR SELECT 
    USING (user_id = auth.user_id());

-- Users can insert their own AI usage (via service)
CREATE POLICY ai_usage_requests_insert_own 
    ON ai_usage_requests FOR INSERT 
    WITH CHECK (user_id = auth.user_id());

-- Admins can view all AI usage
CREATE POLICY ai_usage_requests_admin 
    ON ai_usage_requests FOR SELECT 
    USING (auth.is_admin());

-- Daily and monthly aggregations
CREATE POLICY ai_usage_daily_own 
    ON ai_usage_daily FOR SELECT 
    USING (user_id = auth.user_id());

CREATE POLICY ai_usage_monthly_own 
    ON ai_usage_monthly FOR SELECT 
    USING (user_id = auth.user_id());

CREATE POLICY ai_usage_daily_admin 
    ON ai_usage_daily FOR ALL 
    USING (auth.is_admin());

CREATE POLICY ai_usage_monthly_admin 
    ON ai_usage_monthly FOR ALL 
    USING (auth.is_admin());

-- ============================================================================
-- AGENT SESSIONS POLICIES
-- ============================================================================

-- Users can manage their own sessions
CREATE POLICY agent_sessions_own 
    ON agent_sessions FOR ALL 
    USING (user_id = auth.user_id())
    WITH CHECK (user_id = auth.user_id());

-- Admins can view all sessions
CREATE POLICY agent_sessions_admin 
    ON agent_sessions FOR SELECT 
    USING (auth.is_admin());

-- Users can manage their own messages
CREATE POLICY agent_messages_own 
    ON agent_messages FOR ALL 
    USING (user_id = auth.user_id())
    WITH CHECK (user_id = auth.user_id());

-- Admins can view all messages
CREATE POLICY agent_messages_admin 
    ON agent_messages FOR SELECT 
    USING (auth.is_admin());

-- Users can manage their own tool calls
CREATE POLICY agent_tool_calls_own 
    ON agent_tool_calls FOR ALL 
    USING (user_id = auth.user_id())
    WITH CHECK (user_id = auth.user_id());

-- Users can manage their own feedback
CREATE POLICY agent_feedback_own 
    ON agent_feedback FOR ALL 
    USING (user_id = auth.user_id())
    WITH CHECK (user_id = auth.user_id());

-- Admins can view all feedback
CREATE POLICY agent_feedback_admin 
    ON agent_feedback FOR SELECT 
    USING (auth.is_admin());

-- Session stats follow session permissions
CREATE POLICY agent_session_stats_own 
    ON agent_session_stats FOR SELECT 
    USING (
        EXISTS (
            SELECT 1 FROM agent_sessions 
            WHERE id = agent_session_stats.session_id 
            AND user_id = auth.user_id()
        )
    );

-- ============================================================================
-- BILLING AND SUBSCRIPTION POLICIES
-- ============================================================================

-- Everyone can view subscription tiers
CREATE POLICY subscription_tiers_select_all 
    ON subscription_tiers FOR SELECT 
    USING (is_active = true AND is_public = true);

-- Admins can manage tiers
CREATE POLICY subscription_tiers_admin 
    ON subscription_tiers FOR ALL 
    USING (auth.is_admin());

-- Users can view their own subscription
CREATE POLICY user_subscriptions_select_own 
    ON user_subscriptions FOR SELECT 
    USING (user_id = auth.user_id());

-- Admins can manage all subscriptions
CREATE POLICY user_subscriptions_admin 
    ON user_subscriptions FOR ALL 
    USING (auth.is_admin());

-- Users can view their own quota
CREATE POLICY user_quotas_select_own 
    ON user_quotas FOR SELECT 
    USING (user_id = auth.user_id());

-- Admins can manage all quotas
CREATE POLICY user_quotas_admin 
    ON user_quotas FOR ALL 
    USING (auth.is_admin());

-- Users can view their own payment history
CREATE POLICY payment_history_select_own 
    ON payment_history FOR SELECT 
    USING (user_id = auth.user_id());

-- Admins can view all payments
CREATE POLICY payment_history_admin 
    ON payment_history FOR ALL 
    USING (auth.is_admin());

-- Users can view and manage their own alerts
CREATE POLICY usage_alerts_own 
    ON usage_alerts FOR ALL 
    USING (user_id = auth.user_id())
    WITH CHECK (user_id = auth.user_id());

-- ============================================================================
-- AUDIT LOGS POLICIES
-- ============================================================================

-- Users can view their own audit logs
CREATE POLICY audit_logs_select_own 
    ON audit_logs FOR SELECT 
    USING (user_id = auth.user_id());

-- Admins can view all audit logs
CREATE POLICY audit_logs_admin 
    ON audit_logs FOR SELECT 
    USING (auth.is_admin());

-- System can insert audit logs
CREATE POLICY audit_logs_insert_system 
    ON audit_logs FOR INSERT 
    WITH CHECK (true);

-- ============================================================================
-- PASSWORD RESET AND EMAIL VERIFICATION POLICIES
-- ============================================================================

-- These tables should only be accessed by service role
-- Users don't directly query these tables

CREATE POLICY password_reset_tokens_service 
    ON password_reset_tokens FOR ALL 
    USING (auth.is_admin());

CREATE POLICY email_verification_tokens_service 
    ON email_verification_tokens FOR ALL 
    USING (auth.is_admin());

-- ============================================================================
-- GRANT PERMISSIONS TO AUTHENTICATED USERS
-- ============================================================================

-- Grant basic permissions to authenticated users
GRANT USAGE ON SCHEMA public TO authenticated;
GRANT SELECT ON ALL TABLES IN SCHEMA public TO authenticated;
GRANT INSERT, UPDATE, DELETE ON ALL TABLES IN SCHEMA public TO authenticated;
GRANT USAGE ON ALL SEQUENCES IN SCHEMA public TO authenticated;

-- Grant permissions to service role (bypasses RLS)
GRANT ALL ON ALL TABLES IN SCHEMA public TO service_role;
GRANT ALL ON ALL SEQUENCES IN SCHEMA public TO service_role;

-- ============================================================================
-- COMMENTS
-- ============================================================================

COMMENT ON POLICY users_select_own ON users IS 'Users can view their own profile';
COMMENT ON POLICY users_select_admin ON users IS 'Admins can view all users';
COMMENT ON POLICY ai_usage_requests_select_own ON ai_usage_requests IS 'Users can view their own AI usage';
COMMENT ON POLICY agent_sessions_own ON agent_sessions IS 'Users can manage their own agent sessions';
COMMENT ON POLICY user_subscriptions_select_own ON user_subscriptions IS 'Users can view their own subscription';
COMMENT ON POLICY audit_logs_select_own ON audit_logs IS 'Users can view their own audit logs';

