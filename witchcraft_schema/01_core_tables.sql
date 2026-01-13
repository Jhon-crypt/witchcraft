-- ============================================================================
-- Witchcraft Core Tables
-- Users, Authentication, and Access Tokens
-- ============================================================================

-- Enable UUID extension
CREATE EXTENSION IF NOT EXISTS "uuid-ossp";

-- ============================================================================
-- USERS TABLE
-- Extended user data linked to Supabase auth.users
-- NOTE: Run 00_supabase_auth_setup.sql FIRST to set up Supabase Auth integration
-- ============================================================================

-- This table is created in 00_supabase_auth_setup.sql
-- It links to Supabase's auth.users table via UUID foreign key

-- CREATE TABLE users (
--     id UUID PRIMARY KEY REFERENCES auth.users(id) ON DELETE CASCADE,
--     email VARCHAR(255) NOT NULL UNIQUE,
--     name VARCHAR(255),
--     is_active BOOLEAN NOT NULL DEFAULT true,
--     is_admin BOOLEAN NOT NULL DEFAULT false,
--     metrics_id UUID NOT NULL DEFAULT uuid_generate_v4() UNIQUE,
--     created_at TIMESTAMP WITH TIME ZONE NOT NULL DEFAULT NOW(),
--     updated_at TIMESTAMP WITH TIME ZONE NOT NULL DEFAULT NOW(),
--     last_login_at TIMESTAMP WITH TIME ZONE,
--     accepted_tos_at TIMESTAMP WITH TIME ZONE,
--     deleted_at TIMESTAMP WITH TIME ZONE
-- );

-- If you haven't run 00_supabase_auth_setup.sql, uncomment and run this:
-- (But it's better to run 00_supabase_auth_setup.sql first for proper Supabase Auth integration)

-- Indexes for users table
CREATE INDEX idx_users_email ON users(email) WHERE deleted_at IS NULL;
CREATE INDEX idx_users_metrics_id ON users(metrics_id);
CREATE INDEX idx_users_created_at ON users(created_at);
CREATE INDEX idx_users_is_active ON users(is_active) WHERE is_active = true;

-- ============================================================================
-- ACCESS TOKENS TABLE
-- NOT NEEDED - Supabase Auth handles JWT tokens and sessions
-- ============================================================================

-- Supabase Auth automatically manages:
-- - JWT access tokens (stored in auth.sessions)
-- - Refresh tokens
-- - Token expiration
-- - Token revocation

-- If you need custom API tokens (e.g., for CLI tools), you can create a separate table:
-- But for web/mobile apps, use Supabase Auth's built-in JWT tokens

-- ============================================================================
-- USER PROFILES TABLE
-- Extended user information and preferences
-- NOTE: This is created in 00_supabase_auth_setup.sql with UUID
-- ============================================================================

-- This table is created in 00_supabase_auth_setup.sql
-- Uncomment if you haven't run that file:

-- CREATE TABLE user_profiles (
--     user_id UUID PRIMARY KEY REFERENCES users(id) ON DELETE CASCADE,
    
    -- Profile information
    avatar_url TEXT,
    bio TEXT,
    company VARCHAR(255),
    location VARCHAR(255),
    website TEXT,
    
    -- Preferences
    theme VARCHAR(50) DEFAULT 'system', -- 'light', 'dark', 'system'
    language VARCHAR(10) DEFAULT 'en',
    timezone VARCHAR(100),
    
    -- Notifications
    email_notifications BOOLEAN DEFAULT true,
    marketing_emails BOOLEAN DEFAULT false,
    
    -- Metadata
    created_at TIMESTAMP WITH TIME ZONE NOT NULL DEFAULT NOW(),
    updated_at TIMESTAMP WITH TIME ZONE NOT NULL DEFAULT NOW()
);

-- ============================================================================
-- PASSWORD RESET AND EMAIL VERIFICATION
-- NOT NEEDED - Supabase Auth handles these automatically
-- ============================================================================

-- Supabase Auth automatically provides:
-- - Password reset emails with secure tokens
-- - Email verification emails
-- - Magic link authentication
-- - Token expiration and security

-- Configure email templates in: Supabase Dashboard > Authentication > Email Templates

-- ============================================================================
-- AUDIT LOG TABLE
-- Track important user actions
-- ============================================================================
CREATE TABLE audit_logs (
    id BIGSERIAL PRIMARY KEY,
    user_id BIGINT REFERENCES users(id) ON DELETE SET NULL,
    
    -- Action details
    action VARCHAR(100) NOT NULL, -- 'login', 'logout', 'password_change', 'email_change', etc.
    resource_type VARCHAR(100), -- 'user', 'session', 'ai_request', etc.
    resource_id BIGINT,
    
    -- Request metadata
    ip_address INET,
    user_agent TEXT,
    
    -- Additional data (JSON)
    metadata JSONB,
    
    -- Timestamp
    created_at TIMESTAMP WITH TIME ZONE NOT NULL DEFAULT NOW()
);

-- Indexes for audit_logs table
CREATE INDEX idx_audit_logs_user_id ON audit_logs(user_id);
CREATE INDEX idx_audit_logs_action ON audit_logs(action);
CREATE INDEX idx_audit_logs_created_at ON audit_logs(created_at DESC);
CREATE INDEX idx_audit_logs_resource ON audit_logs(resource_type, resource_id);

-- ============================================================================
-- TRIGGERS
-- ============================================================================

-- Update updated_at timestamp automatically
CREATE OR REPLACE FUNCTION update_updated_at_column()
RETURNS TRIGGER AS $$
BEGIN
    NEW.updated_at = NOW();
    RETURN NEW;
END;
$$ LANGUAGE plpgsql;

CREATE TRIGGER update_users_updated_at
    BEFORE UPDATE ON users
    FOR EACH ROW
    EXECUTE FUNCTION update_updated_at_column();

CREATE TRIGGER update_user_profiles_updated_at
    BEFORE UPDATE ON user_profiles
    FOR EACH ROW
    EXECUTE FUNCTION update_updated_at_column();

-- ============================================================================
-- COMMENTS
-- ============================================================================

COMMENT ON TABLE users IS 'Core user accounts with email/password authentication';
COMMENT ON TABLE access_tokens IS 'Authentication tokens for session management';
COMMENT ON TABLE user_profiles IS 'Extended user profile information and preferences';
COMMENT ON TABLE password_reset_tokens IS 'Tokens for password reset functionality';
COMMENT ON TABLE email_verification_tokens IS 'Tokens for email verification';
COMMENT ON TABLE audit_logs IS 'Audit trail of important user actions';

COMMENT ON COLUMN users.password_hash IS 'Bcrypt or Argon2 hash of user password';
COMMENT ON COLUMN users.metrics_id IS 'UUID for analytics tracking (anonymous)';
COMMENT ON COLUMN access_tokens.token_hash IS 'SHA-256 hash of the actual access token';
COMMENT ON COLUMN access_tokens.impersonated_user_id IS 'For admin support - which user is being impersonated';

