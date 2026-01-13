# Witchcraft Database Schema Overview

## Database Structure

```
┌─────────────────────────────────────────────────────────────────┐
│                     WITCHCRAFT DATABASE                          │
└─────────────────────────────────────────────────────────────────┘

┌──────────────────────┐
│   AUTHENTICATION     │
├──────────────────────┤
│ • users              │ ← Core user accounts
│ • user_profiles      │ ← Extended user info
│ • access_tokens      │ ← Session management
│ • password_reset_*   │ ← Password recovery
│ • email_verify_*     │ ← Email verification
│ • audit_logs         │ ← Security tracking
└──────────────────────┘
         ↓
┌──────────────────────┐
│   AI USAGE TRACKING  │
├──────────────────────┤
│ • ai_providers       │ ← OpenAI, Anthropic, etc.
│ • ai_models          │ ← GPT-4, Claude, etc.
│ • ai_usage_requests  │ ← Individual requests
│ • ai_usage_daily     │ ← Daily aggregations
│ • ai_usage_monthly   │ ← Monthly aggregations
└──────────────────────┘
         ↓
┌──────────────────────┐
│   AGENT SESSIONS     │
├──────────────────────┤
│ • agent_sessions     │ ← Conversation sessions
│ • agent_messages     │ ← Chat messages
│ • agent_tool_calls   │ ← Tool executions
│ • agent_feedback     │ ← User feedback
│ • agent_session_stats│ ← Pre-computed stats
└──────────────────────┘
         ↓
┌──────────────────────┐
│   BILLING & QUOTAS   │
├──────────────────────┤
│ • subscription_tiers │ ← Free, Pro, Team, etc.
│ • user_subscriptions │ ← User's current plan
│ • user_quotas        │ ← Usage limits
│ • payment_history    │ ← Transaction log
│ • usage_alerts       │ ← Quota warnings
└──────────────────────┘
```

## Key Relationships

### User → AI Usage
```
users (1) ──→ (many) ai_usage_requests
users (1) ──→ (many) ai_usage_daily
users (1) ──→ (many) ai_usage_monthly
```

### User → Agent Sessions
```
users (1) ──→ (many) agent_sessions
agent_sessions (1) ──→ (many) agent_messages
agent_sessions (1) ──→ (many) agent_tool_calls
agent_messages (1) ──→ (0..1) ai_usage_requests
```

### User → Billing
```
users (1) ──→ (0..1) user_subscriptions
users (1) ──→ (1) user_quotas
users (1) ──→ (many) payment_history
subscription_tiers (1) ──→ (many) user_subscriptions
```

### AI Providers → Models → Usage
```
ai_providers (1) ──→ (many) ai_models
ai_models (1) ──→ (many) ai_usage_requests
```

## Table Sizes (Estimated for 1000 Active Users)

| Table | Rows/Month | Storage | Notes |
|-------|-----------|---------|-------|
| users | 1,000 | 1 MB | Grows slowly |
| access_tokens | 3,000 | 500 KB | ~3 tokens/user |
| ai_usage_requests | 500,000 | 100 MB | ~500 requests/user |
| ai_usage_daily | 30,000 | 5 MB | 30 days × 1000 users |
| ai_usage_monthly | 1,000 | 200 KB | 1/user/month |
| agent_sessions | 10,000 | 2 MB | ~10 sessions/user |
| agent_messages | 200,000 | 50 MB | ~20 messages/session |
| audit_logs | 50,000 | 10 MB | Security events |
| **TOTAL** | **~790K rows** | **~170 MB/month** | |

## Data Flow

### 1. User Registration Flow
```
1. POST /auth/register
   ↓
2. create_user_with_profile()
   ↓
3. INSERT users
   ↓
4. INSERT user_profiles
   ↓
5. INSERT user_quotas (free tier)
   ↓
6. INSERT audit_logs (user_created)
```

### 2. AI Request Flow
```
1. User makes AI request in Witchcraft
   ↓
2. check_and_consume_quota()
   ↓
3. Call AI provider (OpenAI/Anthropic/Ollama)
   ↓
4. record_ai_usage()
   ↓
5. INSERT ai_usage_requests
   ↓
6. UPSERT ai_usage_daily (aggregate)
   ↓
7. UPSERT ai_usage_monthly (aggregate)
   ↓
8. UPDATE user_quotas (tokens_used)
```

### 3. Agent Session Flow
```
1. User starts agent conversation
   ↓
2. INSERT agent_sessions
   ↓
3. User sends message
   ↓
4. INSERT agent_messages (role: user)
   ↓
5. AI generates response
   ↓
6. record_ai_usage() → ai_usage_requests
   ↓
7. INSERT agent_messages (role: assistant)
   ↓
8. UPDATE agent_sessions (message_count, totals)
```

## Indexes Strategy

### High-Performance Queries
- User's recent activity: `idx_ai_usage_user_recent`
- Active sessions: `idx_agent_sessions_user_active`
- Quota checks: `idx_quotas_approaching_limit`
- Token validation: `idx_access_tokens_token_hash`

### Analytics Queries
- Provider comparison: `idx_ai_usage_provider_comparison`
- Model popularity: `idx_model_popularity`
- Cost analysis: `idx_ai_usage_monthly_cost`

### Security Queries
- Failed logins: `idx_audit_logs_failed_logins`
- Expired tokens: `idx_access_tokens_expired`
- Security events: `idx_audit_logs_security`

## Row Level Security (RLS)

### Principle: Users Own Their Data

```sql
-- Users can only see their own data
CREATE POLICY users_select_own ON users
    FOR SELECT USING (id = auth.user_id());

-- Admins can see everything
CREATE POLICY users_select_admin ON users
    FOR SELECT USING (auth.is_admin());
```

### Protected Tables
- ✅ users, user_profiles, access_tokens
- ✅ ai_usage_requests, ai_usage_daily, ai_usage_monthly
- ✅ agent_sessions, agent_messages, agent_tool_calls
- ✅ user_subscriptions, user_quotas, payment_history
- ✅ audit_logs

### Public Tables (Read-Only)
- ai_providers (active providers only)
- ai_models (active models only)
- subscription_tiers (public tiers only)

## Maintenance Tasks

### Daily (2 AM)
```sql
SELECT daily_maintenance();
```
- Cleanup expired tokens
- End inactive sessions (24h+)
- Archive old audit logs

### Monthly (1st of month, midnight)
```sql
SELECT monthly_maintenance();
```
- Reset user quotas
- Generate monthly reports
- Update subscription statuses

### Manual (As Needed)
```sql
-- Cleanup old audit logs (90+ days)
SELECT cleanup_old_audit_logs(90);

-- Recompute session stats
REFRESH MATERIALIZED VIEW agent_session_stats;
```

## Performance Optimization

### Query Optimization
1. **Use indexes** for all WHERE clauses
2. **Limit results** with pagination
3. **Use aggregations** (daily/monthly) instead of raw data
4. **Cache frequently accessed data** (subscription tiers, models)

### Storage Optimization
1. **Partition large tables** by date (ai_usage_requests)
2. **Archive old data** (>1 year) to separate tables
3. **Compress audit logs** after 90 days
4. **Use JSONB** for flexible metadata

### Connection Pooling
```
Max connections: 100
Pool size: 20
Timeout: 30s
```

## Backup Strategy

### Supabase Automatic Backups
- **Daily backups**: Last 7 days
- **Point-in-time recovery**: Last 7 days
- **Manual backups**: Before major changes

### Critical Tables (Backup Priority)
1. **users** - User accounts
2. **user_subscriptions** - Billing data
3. **payment_history** - Financial records
4. **ai_usage_monthly** - Historical usage

## Monitoring

### Key Metrics to Track
- Active users (daily/monthly)
- AI requests per second
- Average response time
- Quota usage percentage
- Failed requests rate
- Database size growth
- Connection pool usage

### Alerts to Set Up
- 🔴 Quota exceeded (>100%)
- 🟡 Quota warning (>80%)
- 🔴 Failed login spike (>10/min)
- 🟡 High error rate (>5%)
- 🔴 Database size (>80% capacity)
- 🟡 Slow queries (>1s)

## Security Checklist

- [x] RLS enabled on all tables
- [x] Password hashing (bcrypt)
- [x] Token hashing (SHA-256)
- [x] Audit logging
- [x] Input validation
- [x] Rate limiting (implement in backend)
- [x] HTTPS only (implement in backend)
- [x] Token expiration (30 days)
- [x] Failed login tracking
- [x] Admin impersonation logging

## Scaling Considerations

### Up to 10K Users
- ✅ Current schema works well
- ✅ Supabase free/pro tier sufficient
- ✅ No partitioning needed

### 10K - 100K Users
- 📊 Partition ai_usage_requests by month
- 📊 Add read replicas for analytics
- 📊 Implement caching layer (Redis)
- 📊 Upgrade to Supabase Pro

### 100K+ Users
- 🚀 Consider dedicated PostgreSQL
- 🚀 Implement sharding by user_id
- 🚀 Separate analytics database
- 🚀 CDN for static assets
- 🚀 Load balancer for API

## Cost Estimation

### Supabase Costs (Monthly)

| Tier | Users | Storage | Requests | Cost |
|------|-------|---------|----------|------|
| Free | <500 | 500MB | 50K auth | $0 |
| Pro | <100K | 8GB | 100K auth | $25 |
| Team | <100K | 100GB | Unlimited | $599 |

### Backend Hosting (Monthly)

| Service | Cost | Notes |
|---------|------|-------|
| Railway | $5-20 | Scales automatically |
| Vercel | $20 | Serverless functions |
| AWS Lambda | $10-50 | Pay per request |

**Total Estimated Cost**: $5-70/month for small-medium usage

---

## Quick Reference

### Most Common Queries

```sql
-- Get user with quota
SELECT u.*, q.* FROM users u
JOIN user_quotas q ON u.id = q.user_id
WHERE u.email = 'user@example.com';

-- Get monthly usage
SELECT * FROM ai_usage_monthly
WHERE user_id = 123
AND year = 2026 AND month = 1;

-- Get active sessions
SELECT * FROM agent_sessions
WHERE user_id = 123 AND is_active = true
ORDER BY last_activity_at DESC;

-- Check quota remaining
SELECT * FROM get_remaining_quota(123);
```

### Most Common Functions

```sql
-- Create user
SELECT create_user_with_profile('email@example.com', 'hash', 'Name');

-- Record AI usage
SELECT record_ai_usage(user_id, provider_id, model_id, ...);

-- Check quota
SELECT check_and_consume_quota(user_id, tokens, cost);

-- Get activity summary
SELECT * FROM get_user_activity_summary(user_id, 30);
```

---

For detailed API integration examples, see `API_INTEGRATION_EXAMPLES.md`

