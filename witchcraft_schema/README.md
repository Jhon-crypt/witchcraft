# Witchcraft Supabase Database Schema

This directory contains the Supabase database schema for Witchcraft's authentication and usage tracking system.

## Overview

Witchcraft uses Supabase as the database layer with custom authentication handled by your backend endpoint. The schema is designed to track:

- **User Management**: Email/password authentication (handled by your endpoint)
- **Access Tokens**: Secure session management
- **AI Usage Tracking**: Model usage, token consumption, and costs
- **Agent Sessions**: Track agent conversations and interactions
- **Billing**: Usage-based billing and quotas

## Architecture

```
    Witchcraft Client
        ↓
    Supabase Auth (Authentication)
        ↓
    Supabase DB (Storage + Usage Tracking)
```

**Supabase handles everything:**
- ✅ User registration (email/password)
- ✅ Email verification
- ✅ Password reset
- ✅ JWT token management
- ✅ Session management
- ✅ OAuth providers (Google, GitHub, etc.)
- ✅ Magic links

## Files

- `00_supabase_auth_setup.sql` - **RUN THIS FIRST** - Supabase Auth integration
- `01_core_tables.sql` - User profiles and audit logs
- `02_ai_usage_tables.sql` - AI model usage and tracking (open-source models)
- `03_agent_sessions.sql` - Agent conversation tracking
- `04_quota_tables.sql` - Free quota tiers and usage limits (no billing)
- `05_indexes.sql` - Performance indexes
- `06_rls_policies.sql` - Row Level Security policies
- `07_functions.sql` - Helper functions and triggers

## Setup Instructions

### 1. Create Supabase Project

1. Go to https://supabase.com
2. Create a new project
3. Note your project URL and anon key

### 2. Enable Email Auth

In Supabase Dashboard:
1. Go to **Authentication** > **Providers**
2. Enable **Email** provider
3. Configure email settings:
   - Confirm email: **Required**
   - Secure email change: **Enabled**

### 3. Run Migrations

Execute the SQL files **in order** in your Supabase SQL Editor:

```sql
-- IMPORTANT: Run in this exact order!
-- 00_supabase_auth_setup.sql  ← RUN THIS FIRST!
-- 01_core_tables.sql
-- 02_ai_usage_tables.sql
-- 03_agent_sessions.sql
-- 04_quota_tables.sql
-- 05_indexes.sql
-- 06_rls_policies.sql
-- 07_functions.sql
```

### 4. Configure Witchcraft Client

Set environment variables:

```bash
export SUPABASE_URL="https://your-project.supabase.co"
export SUPABASE_ANON_KEY="your-anon-key"
```

In your Witchcraft client code:

```javascript
import { createClient } from '@supabase/supabase-js'

const supabase = createClient(
  process.env.SUPABASE_URL,
  process.env.SUPABASE_ANON_KEY
)

// Sign up
const { data, error } = await supabase.auth.signUp({
  email: 'user@example.com',
  password: 'password123'
})

// Sign in
const { data, error } = await supabase.auth.signInWithPassword({
  email: 'user@example.com',
  password: 'password123'
})

// Get current user
const { data: { user } } = await supabase.auth.getUser()
```

## Security Notes

- ✅ **Supabase Auth handles password hashing** - bcrypt by default
- ✅ **JWT tokens** - Secure, short-lived (1 hour), auto-refreshed
- ✅ **RLS enabled** - Users can only access their own data
- ✅ **Email verification** - Confirm user emails before full access
- ✅ **Rate limiting** - Built into Supabase Auth
- ✅ **HTTPS only** - All Supabase endpoints use HTTPS

## Key Features

### User Management
- Email/password authentication
- User profiles and metadata
- Admin flags
- Account creation tracking

### AI Usage Tracking
- Per-request tracking (model, tokens, cost)
- Aggregated daily/monthly stats
- Provider-specific tracking (OpenAI, Anthropic, Ollama, etc.)
- Agent mode tracking (Understand, Debug, Implement)

### Billing
- Usage-based quotas
- Monthly allowances
- Cost tracking per user
- Subscription tiers

### Agent Sessions
- Conversation tracking
- Message history
- Agent mode per session
- Performance metrics

## Example Queries

### Get User's Monthly AI Usage

```sql
SELECT 
    provider,
    model,
    SUM(total_tokens) as total_tokens,
    SUM(cost_usd) as total_cost
FROM ai_usage_daily
WHERE user_id = $1
  AND date >= date_trunc('month', CURRENT_DATE)
GROUP BY provider, model;
```

### Get Active Sessions

```sql
SELECT 
    s.*,
    u.email,
    COUNT(m.id) as message_count
FROM agent_sessions s
JOIN users u ON s.user_id = u.id
LEFT JOIN agent_messages m ON s.id = m.session_id
WHERE s.ended_at IS NULL
GROUP BY s.id, u.email;
```

### Check User Quota

```sql
SELECT 
    u.email,
    q.monthly_token_limit,
    COALESCE(SUM(d.total_tokens), 0) as tokens_used,
    q.monthly_token_limit - COALESCE(SUM(d.total_tokens), 0) as tokens_remaining
FROM users u
JOIN user_quotas q ON u.id = q.user_id
LEFT JOIN ai_usage_daily d ON u.id = d.user_id 
    AND d.date >= date_trunc('month', CURRENT_DATE)
WHERE u.id = $1
GROUP BY u.id, u.email, q.monthly_token_limit;
```

## Support

For issues or questions, refer to the Witchcraft documentation or open an issue on GitHub.

