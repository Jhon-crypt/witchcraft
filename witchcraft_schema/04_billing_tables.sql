-- ============================================================================
-- Witchcraft Quota Tables (Free Tier Only)
-- Track usage quotas for open-source models
-- NOTE: No billing/payments - all users get free quotas
-- ============================================================================

-- ============================================================================
-- QUOTA TIERS TABLE
-- Define available quota tiers (all free)
-- ============================================================================
CREATE TABLE quota_tiers (
    id SERIAL PRIMARY KEY,
    name VARCHAR(100) NOT NULL UNIQUE, -- 'standard', 'contributor', 'supporter', 'unlimited'
    display_name VARCHAR(100) NOT NULL,
    description TEXT,
    
    -- Quotas (no pricing, just limits)
    monthly_token_limit BIGINT, -- NULL = unlimited
    monthly_request_limit INTEGER, -- NULL = unlimited
    daily_request_limit INTEGER, -- Daily rate limit
    
    -- Features
    features JSONB, -- JSON array of feature flags
    
    -- Status
    is_active BOOLEAN NOT NULL DEFAULT true,
    is_default BOOLEAN NOT NULL DEFAULT false, -- Default tier for new users
    
    -- Display order
    sort_order INTEGER NOT NULL DEFAULT 0,
    
    -- Timestamps
    created_at TIMESTAMP WITH TIME ZONE NOT NULL DEFAULT NOW(),
    updated_at TIMESTAMP WITH TIME ZONE NOT NULL DEFAULT NOW()
);

-- Insert default free tiers
INSERT INTO quota_tiers (name, display_name, description, monthly_token_limit, monthly_request_limit, daily_request_limit, is_default, sort_order, features) VALUES
('standard', 'Standard', 'Default quota for all users', 500000, 1000, 50, true, 1, '["ollama_models", "basic_features"]'::jsonb),
('contributor', 'Contributor', 'For open-source contributors', 2000000, 5000, 200, false, 2, '["all_models", "priority_queue", "contributor_badge"]'::jsonb),
('supporter', 'Supporter', 'For community supporters', 5000000, 10000, 500, false, 3, '["all_models", "priority_queue", "supporter_badge", "early_access"]'::jsonb),
('unlimited', 'Unlimited', 'For admins and special cases', NULL, NULL, NULL, false, 4, '["unlimited", "admin_features"]'::jsonb);

-- ============================================================================
-- USER QUOTA ASSIGNMENTS TABLE
-- Track which quota tier each user has (no billing)
-- ============================================================================
CREATE TABLE user_quota_assignments (
    id BIGSERIAL PRIMARY KEY,
    user_id UUID NOT NULL REFERENCES users(id) ON DELETE CASCADE,
    tier_id INTEGER NOT NULL REFERENCES quota_tiers(id),
    
    -- Assignment reason
    reason VARCHAR(255), -- 'default', 'contributor', 'admin_override', 'community_supporter'
    assigned_by UUID REFERENCES users(id), -- Admin who assigned (if manual)
    
    -- Status
    is_active BOOLEAN NOT NULL DEFAULT true,
    
    -- Timestamps
    created_at TIMESTAMP WITH TIME ZONE NOT NULL DEFAULT NOW(),
    updated_at TIMESTAMP WITH TIME ZONE NOT NULL DEFAULT NOW(),
    
    UNIQUE(user_id, tier_id)
);

-- Indexes for user_quota_assignments table
CREATE INDEX idx_user_quota_assignments_user_id ON user_quota_assignments(user_id);
CREATE INDEX idx_user_quota_assignments_tier_id ON user_quota_assignments(tier_id);
CREATE INDEX idx_user_quota_assignments_active ON user_quota_assignments(user_id, is_active) WHERE is_active = true;

-- ============================================================================
-- USER QUOTAS TABLE
-- Track current quota limits and usage for each user
-- ============================================================================
CREATE TABLE user_quotas (
    user_id UUID PRIMARY KEY REFERENCES users(id) ON DELETE CASCADE,
    
    -- Current limits (from quota tier or custom)
    monthly_token_limit BIGINT, -- NULL = unlimited
    monthly_request_limit INTEGER, -- NULL = unlimited
    daily_request_limit INTEGER, -- Daily rate limit
    
    -- Custom allowances (admin overrides)
    custom_token_allowance BIGINT, -- Additional tokens beyond tier
    custom_request_allowance INTEGER, -- Additional requests beyond tier
    
    -- Current period tracking
    current_period_start DATE NOT NULL,
    current_period_end DATE NOT NULL,
    
    -- Usage tracking (reset monthly)
    tokens_used BIGINT NOT NULL DEFAULT 0,
    requests_used INTEGER NOT NULL DEFAULT 0,
    
    -- Daily usage tracking (reset daily)
    daily_requests_used INTEGER NOT NULL DEFAULT 0,
    last_daily_reset DATE NOT NULL DEFAULT CURRENT_DATE,
    
    -- Timestamps
    created_at TIMESTAMP WITH TIME ZONE NOT NULL DEFAULT NOW(),
    updated_at TIMESTAMP WITH TIME ZONE NOT NULL DEFAULT NOW(),
    
    CONSTRAINT valid_quota_period CHECK (current_period_end > current_period_start)
);

-- Indexes for user_quotas table
CREATE INDEX idx_user_quotas_period_end ON user_quotas(current_period_end);
CREATE INDEX idx_user_quotas_daily_reset ON user_quotas(last_daily_reset);

-- ============================================================================
-- PAYMENT HISTORY TABLE
-- NOT NEEDED - Witchcraft is free, no payments
-- ============================================================================

-- This table is not needed since Witchcraft uses free open-source models
-- and doesn't charge users. If you decide to add optional donations or
-- support features in the future, you can uncomment and modify this table.

-- ============================================================================
-- USAGE ALERTS TABLE
-- Track quota usage alerts sent to users
-- ============================================================================
CREATE TABLE usage_alerts (
    id BIGSERIAL PRIMARY KEY,
    user_id UUID NOT NULL REFERENCES users(id) ON DELETE CASCADE,
    
    -- Alert type
    alert_type VARCHAR(50) NOT NULL, -- 'quota_warning', 'quota_exceeded', 'rate_limit'
    
    -- Alert details
    threshold_percentage INTEGER, -- e.g., 80 for 80% usage warning
    current_usage_percentage INTEGER,
    
    -- Alert message
    title VARCHAR(255) NOT NULL,
    message TEXT NOT NULL,
    
    -- Alert status
    is_read BOOLEAN NOT NULL DEFAULT false,
    is_dismissed BOOLEAN NOT NULL DEFAULT false,
    
    -- Timestamps
    created_at TIMESTAMP WITH TIME ZONE NOT NULL DEFAULT NOW(),
    read_at TIMESTAMP WITH TIME ZONE,
    dismissed_at TIMESTAMP WITH TIME ZONE,
    
    -- Additional metadata
    metadata JSONB
);

-- Indexes for usage_alerts table
CREATE INDEX idx_usage_alerts_user_id ON usage_alerts(user_id);
CREATE INDEX idx_usage_alerts_type ON usage_alerts(alert_type);
CREATE INDEX idx_usage_alerts_unread ON usage_alerts(user_id, is_read) WHERE is_read = false;
CREATE INDEX idx_usage_alerts_created_at ON usage_alerts(created_at DESC);

-- ============================================================================
-- FUNCTIONS AND TRIGGERS
-- ============================================================================

-- Update updated_at timestamp automatically
CREATE TRIGGER update_quota_tiers_updated_at
    BEFORE UPDATE ON quota_tiers
    FOR EACH ROW
    EXECUTE FUNCTION update_updated_at_column();

CREATE TRIGGER update_user_quota_assignments_updated_at
    BEFORE UPDATE ON user_quota_assignments
    FOR EACH ROW
    EXECUTE FUNCTION update_updated_at_column();

CREATE TRIGGER update_user_quotas_updated_at
    BEFORE UPDATE ON user_quotas
    FOR EACH ROW
    EXECUTE FUNCTION update_updated_at_column();

-- Function to check and create usage alerts
CREATE OR REPLACE FUNCTION check_quota_usage()
RETURNS TRIGGER AS $$
DECLARE
    usage_percentage INTEGER;
    alert_threshold INTEGER;
BEGIN
    -- Check token usage if there's a limit
    IF NEW.monthly_token_limit IS NOT NULL AND NEW.monthly_token_limit > 0 THEN
        usage_percentage := (NEW.tokens_used * 100 / NEW.monthly_token_limit)::INTEGER;
        
        -- Alert at 80%, 90%, and 100%
        FOR alert_threshold IN SELECT unnest(ARRAY[80, 90, 100]) LOOP
            IF usage_percentage >= alert_threshold AND 
               NOT EXISTS (
                   SELECT 1 FROM usage_alerts 
                   WHERE user_id = NEW.user_id 
                   AND alert_type = 'quota_warning'
                   AND threshold_percentage = alert_threshold
                   AND created_at >= NEW.current_period_start
               ) THEN
                INSERT INTO usage_alerts (user_id, alert_type, threshold_percentage, current_usage_percentage, title, message)
                VALUES (
                    NEW.user_id,
                    CASE WHEN alert_threshold = 100 THEN 'quota_exceeded' ELSE 'quota_warning' END,
                    alert_threshold,
                    usage_percentage,
                    format('Token Quota %s%%', alert_threshold),
                    format('You have used %s%% of your monthly token quota (%s / %s tokens)', 
                           usage_percentage, NEW.tokens_used, NEW.monthly_token_limit)
                );
            END IF;
        END LOOP;
    END IF;
    
    -- Check daily rate limit
    IF NEW.daily_request_limit IS NOT NULL AND NEW.daily_request_limit > 0 THEN
        IF NEW.daily_requests_used >= NEW.daily_request_limit AND 
           NOT EXISTS (
               SELECT 1 FROM usage_alerts 
               WHERE user_id = NEW.user_id 
               AND alert_type = 'rate_limit'
               AND created_at::DATE = CURRENT_DATE
           ) THEN
            INSERT INTO usage_alerts (user_id, alert_type, threshold_percentage, current_usage_percentage, title, message)
            VALUES (
                NEW.user_id,
                'rate_limit',
                100,
                100,
                'Daily Rate Limit Reached',
                format('You have reached your daily request limit of %s requests. Limit resets tomorrow.', 
                       NEW.daily_request_limit)
            );
        END IF;
    END IF;
    
    RETURN NEW;
END;
$$ LANGUAGE plpgsql;

-- Trigger to check quota usage
CREATE TRIGGER check_quota_usage_on_update
    AFTER UPDATE OF tokens_used, requests_used, daily_requests_used ON user_quotas
    FOR EACH ROW
    EXECUTE FUNCTION check_quota_usage();

-- ============================================================================
-- COMMENTS
-- ============================================================================

COMMENT ON TABLE quota_tiers IS 'Available quota tiers (all free - no billing)';
COMMENT ON TABLE user_quota_assignments IS 'User quota tier assignments';
COMMENT ON TABLE user_quotas IS 'Current quota limits and usage for each user';
COMMENT ON TABLE usage_alerts IS 'Quota usage alerts sent to users';

COMMENT ON COLUMN user_quotas.custom_token_allowance IS 'Additional tokens beyond tier (admin override)';
COMMENT ON COLUMN user_quotas.tokens_used IS 'Tokens used in current period (resets monthly)';
COMMENT ON COLUMN user_quotas.daily_requests_used IS 'Requests used today (resets daily)';
COMMENT ON COLUMN usage_alerts.threshold_percentage IS 'Percentage threshold that triggered the alert (80, 90, 100)';

