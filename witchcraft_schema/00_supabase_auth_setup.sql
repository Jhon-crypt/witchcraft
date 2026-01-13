-- ============================================================================
-- Witchcraft Supabase Auth Setup
-- Configure Supabase's built-in authentication system
-- ============================================================================

-- ============================================================================
-- IMPORTANT: Supabase Auth Configuration
-- ============================================================================

-- Supabase Auth handles:
-- ✅ User registration (email/password)
-- ✅ Email verification
-- ✅ Password reset
-- ✅ Session management (JWT tokens)
-- ✅ OAuth providers (Google, GitHub, etc.)
-- ✅ Magic links
-- ✅ Phone authentication

-- Users are stored in: auth.users (managed by Supabase)
-- Sessions are stored in: auth.sessions (managed by Supabase)

-- ============================================================================
-- EXTEND SUPABASE AUTH USERS
-- Link our custom users table to Supabase auth.users
-- ============================================================================

-- Drop the old users table structure and recreate to link with Supabase Auth
DROP TABLE IF EXISTS users CASCADE;

CREATE TABLE users (
    -- Use Supabase auth.users.id as primary key (UUID)
    id UUID PRIMARY KEY REFERENCES auth.users(id) ON DELETE CASCADE,
    
    -- User information (synced from auth.users)
    email VARCHAR(255) NOT NULL UNIQUE,
    name VARCHAR(255),
    
    -- User status
    is_active BOOLEAN NOT NULL DEFAULT true,
    is_admin BOOLEAN NOT NULL DEFAULT false,
    
    -- Metadata
    metrics_id UUID NOT NULL DEFAULT uuid_generate_v4() UNIQUE,
    created_at TIMESTAMP WITH TIME ZONE NOT NULL DEFAULT NOW(),
    updated_at TIMESTAMP WITH TIME ZONE NOT NULL DEFAULT NOW(),
    last_login_at TIMESTAMP WITH TIME ZONE,
    
    -- Terms and conditions
    accepted_tos_at TIMESTAMP WITH TIME ZONE,
    
    -- Soft delete
    deleted_at TIMESTAMP WITH TIME ZONE
);

-- ============================================================================
-- TRIGGER: Auto-create user profile when Supabase user signs up
-- ============================================================================

CREATE OR REPLACE FUNCTION public.handle_new_user()
RETURNS TRIGGER AS $$
BEGIN
    -- Insert into our users table
    INSERT INTO public.users (id, email, name, created_at)
    VALUES (
        NEW.id,
        NEW.email,
        COALESCE(NEW.raw_user_meta_data->>'name', NEW.raw_user_meta_data->>'full_name'),
        NEW.created_at
    );
    
    -- Create user profile
    INSERT INTO public.user_profiles (user_id)
    VALUES (NEW.id);
    
    -- Create default quota (free tier)
    INSERT INTO public.user_quotas (
        user_id,
        monthly_token_limit,
        monthly_request_limit,
        current_period_start,
        current_period_end
    )
    SELECT 
        NEW.id,
        monthly_token_limit,
        monthly_request_limit,
        CURRENT_DATE,
        (CURRENT_DATE + INTERVAL '1 month')::DATE
    FROM subscription_tiers
    WHERE name = 'free';
    
    -- Log audit event
    INSERT INTO public.audit_logs (user_id, action, resource_type, resource_id)
    VALUES (NEW.id, 'user_created', 'user', NEW.id);
    
    RETURN NEW;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;

-- Trigger on Supabase auth.users table
DROP TRIGGER IF EXISTS on_auth_user_created ON auth.users;
CREATE TRIGGER on_auth_user_created
    AFTER INSERT ON auth.users
    FOR EACH ROW
    EXECUTE FUNCTION public.handle_new_user();

-- ============================================================================
-- TRIGGER: Sync user updates from auth.users
-- ============================================================================

CREATE OR REPLACE FUNCTION public.handle_user_update()
RETURNS TRIGGER AS $$
BEGIN
    -- Update email if changed
    IF NEW.email IS DISTINCT FROM OLD.email THEN
        UPDATE public.users
        SET email = NEW.email, updated_at = NOW()
        WHERE id = NEW.id;
    END IF;
    
    -- Update name if changed in metadata
    IF NEW.raw_user_meta_data->>'name' IS DISTINCT FROM OLD.raw_user_meta_data->>'name' THEN
        UPDATE public.users
        SET name = COALESCE(NEW.raw_user_meta_data->>'name', NEW.raw_user_meta_data->>'full_name'),
            updated_at = NOW()
        WHERE id = NEW.id;
    END IF;
    
    RETURN NEW;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;

-- Trigger on Supabase auth.users table
DROP TRIGGER IF EXISTS on_auth_user_updated ON auth.users;
CREATE TRIGGER on_auth_user_updated
    AFTER UPDATE ON auth.users
    FOR EACH ROW
    EXECUTE FUNCTION public.handle_user_update();

-- ============================================================================
-- FUNCTION: Get current authenticated user ID
-- ============================================================================

CREATE OR REPLACE FUNCTION auth.user_id()
RETURNS UUID AS $$
    SELECT auth.uid();
$$ LANGUAGE SQL STABLE;

-- ============================================================================
-- FUNCTION: Check if current user is admin
-- ============================================================================

CREATE OR REPLACE FUNCTION auth.is_admin()
RETURNS BOOLEAN AS $$
    SELECT EXISTS (
        SELECT 1 FROM public.users
        WHERE id = auth.uid()
        AND is_admin = true
        AND is_active = true
    );
$$ LANGUAGE SQL STABLE SECURITY DEFINER;

-- ============================================================================
-- UPDATE USER PROFILES TABLE
-- ============================================================================

-- Drop and recreate user_profiles to use UUID
DROP TABLE IF EXISTS user_profiles CASCADE;

CREATE TABLE user_profiles (
    user_id UUID PRIMARY KEY REFERENCES users(id) ON DELETE CASCADE,
    
    -- Profile information
    avatar_url TEXT,
    bio TEXT,
    company VARCHAR(255),
    location VARCHAR(255),
    website TEXT,
    
    -- Preferences
    theme VARCHAR(50) DEFAULT 'system',
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
-- REMOVE CUSTOM AUTH TABLES (Supabase handles these)
-- ============================================================================

-- We don't need these anymore - Supabase Auth handles them:
-- DROP TABLE IF EXISTS access_tokens CASCADE;
-- DROP TABLE IF EXISTS password_reset_tokens CASCADE;
-- DROP TABLE IF EXISTS email_verification_tokens CASCADE;

-- Note: Keep audit_logs for tracking user actions

-- ============================================================================
-- SUPABASE AUTH CONFIGURATION
-- ============================================================================

-- Configure in Supabase Dashboard > Authentication > Settings:

-- Email Auth:
-- ✅ Enable Email provider
-- ✅ Confirm email: Required
-- ✅ Secure email change: Enabled

-- Email Templates:
-- Customize the email templates for:
-- - Confirmation email
-- - Password reset
-- - Magic link
-- - Email change

-- JWT Settings:
-- - JWT expiry: 3600 (1 hour)
-- - Refresh token expiry: 2592000 (30 days)

-- Security:
-- - Enable CAPTCHA for sign-ups (optional)
-- - Rate limiting: Enabled
-- - Password requirements: Minimum 6 characters

-- ============================================================================
-- OAUTH PROVIDERS (Optional)
-- ============================================================================

-- You can enable OAuth providers in Supabase Dashboard:
-- - Google
-- - GitHub
-- - GitLab
-- - Bitbucket
-- - Azure
-- - Apple
-- - Discord
-- - Facebook
-- - Twitter
-- etc.

-- ============================================================================
-- COMMENTS
-- ============================================================================

COMMENT ON TABLE users IS 'Extended user data linked to Supabase auth.users';
COMMENT ON FUNCTION handle_new_user IS 'Auto-create user profile when Supabase user signs up';
COMMENT ON FUNCTION handle_user_update IS 'Sync user data from Supabase auth.users';
COMMENT ON FUNCTION auth.user_id IS 'Get current authenticated user UUID from Supabase Auth';
COMMENT ON FUNCTION auth.is_admin IS 'Check if current user is admin';

-- ============================================================================
-- TESTING
-- ============================================================================

-- After running this script, test with Supabase Auth:

-- 1. Sign up a user via Supabase Auth:
--    supabase.auth.signUp({ email: 'test@example.com', password: 'password123' })

-- 2. Check that user was created:
--    SELECT * FROM auth.users;
--    SELECT * FROM public.users;
--    SELECT * FROM public.user_profiles;
--    SELECT * FROM public.user_quotas;

-- 3. Sign in:
--    supabase.auth.signInWithPassword({ email: 'test@example.com', password: 'password123' })

-- 4. Get current user:
--    SELECT auth.uid(); -- Returns current user UUID
--    SELECT * FROM users WHERE id = auth.uid();


