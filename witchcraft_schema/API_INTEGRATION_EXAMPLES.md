# Witchcraft API Integration Examples

This document provides examples of how to integrate your authentication backend with the Witchcraft Supabase database.

## Authentication Endpoint Examples

### 1. User Registration

```typescript
// POST /api/auth/register
import { createClient } from '@supabase/supabase-js';
import bcrypt from 'bcrypt';

const supabase = createClient(process.env.SUPABASE_URL, process.env.SUPABASE_SERVICE_KEY);

export async function registerUser(email: string, password: string, name?: string) {
  // Hash password
  const passwordHash = await bcrypt.hash(password, 10);
  
  // Call Supabase function to create user
  const { data, error } = await supabase.rpc('create_user_with_profile', {
    p_email: email.toLowerCase(),
    p_password_hash: passwordHash,
    p_name: name
  });
  
  if (error) throw error;
  
  const userId = data;
  
  // Generate email verification token
  const verificationToken = crypto.randomBytes(32).toString('hex');
  const tokenHash = crypto.createHash('sha256').update(verificationToken).digest('hex');
  
  await supabase.from('email_verification_tokens').insert({
    user_id: userId,
    token_hash: tokenHash
  });
  
  // Send verification email (implement your email service)
  await sendVerificationEmail(email, verificationToken);
  
  return { userId, message: 'User created. Please verify your email.' };
}
```

### 2. User Login

```typescript
// POST /api/auth/login
import crypto from 'crypto';

export async function loginUser(email: string, password: string, ipAddress?: string, userAgent?: string) {
  // Get user by email
  const { data: user, error } = await supabase
    .from('users')
    .select('id, email, password_hash, is_active, email_verified')
    .eq('email', email.toLowerCase())
    .is('deleted_at', null)
    .single();
  
  if (error || !user) {
    // Log failed attempt
    await supabase.from('audit_logs').insert({
      action: 'login_failed',
      ip_address: ipAddress,
      user_agent: userAgent,
      metadata: { email, reason: 'user_not_found' }
    });
    throw new Error('Invalid credentials');
  }
  
  // Verify password
  const isValid = await bcrypt.compare(password, user.password_hash);
  
  if (!isValid) {
    await supabase.from('audit_logs').insert({
      user_id: user.id,
      action: 'login_failed',
      ip_address: ipAddress,
      user_agent: userAgent,
      metadata: { reason: 'invalid_password' }
    });
    throw new Error('Invalid credentials');
  }
  
  if (!user.is_active) {
    throw new Error('Account is inactive');
  }
  
  if (!user.email_verified) {
    throw new Error('Please verify your email first');
  }
  
  // Generate access token
  const accessToken = crypto.randomBytes(32).toString('hex');
  const tokenHash = crypto.createHash('sha256').update(accessToken).digest('hex');
  
  // Store token in database
  const { data: tokenData } = await supabase
    .from('access_tokens')
    .insert({
      user_id: user.id,
      token_hash: tokenHash,
      ip_address: ipAddress,
      user_agent: userAgent
    })
    .select('id')
    .single();
  
  // Update last login
  await supabase
    .from('users')
    .update({ last_login_at: new Date().toISOString() })
    .eq('id', user.id);
  
  // Log successful login
  await supabase.from('audit_logs').insert({
    user_id: user.id,
    action: 'login',
    ip_address: ipAddress,
    user_agent: userAgent
  });
  
  return {
    accessToken,
    userId: user.id,
    email: user.email
  };
}
```

### 3. Token Validation

```typescript
// Middleware to validate access token
export async function validateToken(token: string) {
  const tokenHash = crypto.createHash('sha256').update(token).digest('hex');
  
  const { data: accessToken, error } = await supabase
    .from('access_tokens')
    .select(`
      id,
      user_id,
      users (
        id,
        email,
        name,
        is_active,
        is_admin
      )
    `)
    .eq('token_hash', tokenHash)
    .is('revoked_at', null)
    .gt('expires_at', new Date().toISOString())
    .single();
  
  if (error || !accessToken) {
    throw new Error('Invalid or expired token');
  }
  
  // Update last used
  await supabase
    .from('access_tokens')
    .update({ last_used_at: new Date().toISOString() })
    .eq('id', accessToken.id);
  
  return accessToken.users;
}
```

## AI Usage Tracking Examples

### 4. Record AI Request

```typescript
// POST /api/ai/track-usage
export async function trackAIUsage(
  userId: number,
  provider: string,
  model: string,
  agentMode: 'understand' | 'debug' | 'implement',
  promptTokens: number,
  completionTokens: number,
  inputCostUsd: number,
  outputCostUsd: number,
  latencyMs?: number,
  sessionId?: number,
  success: boolean = true,
  errorMessage?: string
) {
  // Get provider and model IDs
  const { data: providerData } = await supabase
    .from('ai_providers')
    .select('id')
    .eq('name', provider)
    .single();
  
  const { data: modelData } = await supabase
    .from('ai_models')
    .select('id')
    .eq('model_name', model)
    .eq('provider_id', providerData.id)
    .single();
  
  // Check quota before recording
  const { data: canProceed } = await supabase.rpc('check_and_consume_quota', {
    p_user_id: userId,
    p_tokens: promptTokens + completionTokens,
    p_cost_usd: inputCostUsd + outputCostUsd
  });
  
  if (!canProceed) {
    throw new Error('Quota exceeded');
  }
  
  // Record usage
  const { data: requestId } = await supabase.rpc('record_ai_usage', {
    p_user_id: userId,
    p_provider_id: providerData.id,
    p_model_id: modelData?.id,
    p_model_name: model,
    p_agent_mode: agentMode,
    p_prompt_tokens: promptTokens,
    p_completion_tokens: completionTokens,
    p_input_cost_usd: inputCostUsd,
    p_output_cost_usd: outputCostUsd,
    p_latency_ms: latencyMs,
    p_session_id: sessionId,
    p_success: success,
    p_error_message: errorMessage
  });
  
  return requestId;
}
```

### 5. Get User Usage Summary

```typescript
// GET /api/user/usage-summary
export async function getUserUsageSummary(userId: number, days: number = 30) {
  const { data, error } = await supabase.rpc('get_user_activity_summary', {
    p_user_id: userId,
    p_days: days
  });
  
  if (error) throw error;
  
  return data[0];
}
```

### 6. Check Remaining Quota

```typescript
// GET /api/user/quota
export async function getRemainingQuota(userId: number) {
  const { data, error } = await supabase.rpc('get_remaining_quota', {
    p_user_id: userId
  });
  
  if (error) throw error;
  
  return data[0];
}
```

## Agent Session Examples

### 7. Create Agent Session

```typescript
// POST /api/agent/session
export async function createAgentSession(
  userId: number,
  agentMode: 'understand' | 'debug' | 'implement',
  projectPath?: string,
  projectName?: string
) {
  const { data, error } = await supabase
    .from('agent_sessions')
    .insert({
      user_id: userId,
      agent_mode: agentMode,
      project_path: projectPath,
      project_name: projectName
    })
    .select()
    .single();
  
  if (error) throw error;
  
  return data;
}
```

### 8. Add Message to Session

```typescript
// POST /api/agent/message
export async function addMessage(
  sessionId: number,
  userId: number,
  role: 'user' | 'assistant' | 'system',
  content: string,
  aiRequestId?: number,
  tokens?: number,
  costUsd?: number
) {
  // Get next sequence number
  const { data: lastMessage } = await supabase
    .from('agent_messages')
    .select('sequence_number')
    .eq('session_id', sessionId)
    .order('sequence_number', { ascending: false })
    .limit(1)
    .single();
  
  const sequenceNumber = (lastMessage?.sequence_number || 0) + 1;
  
  const { data, error } = await supabase
    .from('agent_messages')
    .insert({
      session_id: sessionId,
      user_id: userId,
      role,
      content,
      ai_request_id: aiRequestId,
      tokens,
      cost_usd: costUsd,
      sequence_number: sequenceNumber
    })
    .select()
    .single();
  
  if (error) throw error;
  
  return data;
}
```

## Witchcraft Client Configuration

### 9. Environment Variables

```bash
# .env file for your backend
SUPABASE_URL=https://your-project.supabase.co
SUPABASE_SERVICE_KEY=your-service-role-key
SUPABASE_ANON_KEY=your-anon-key

# Your auth endpoint
WITCHCRAFT_AUTH_ENDPOINT=https://your-api.com/auth

# Email service (optional)
SMTP_HOST=smtp.gmail.com
SMTP_PORT=587
SMTP_USER=your-email@gmail.com
SMTP_PASS=your-app-password
```

### 10. Witchcraft Client Settings

Update Witchcraft to point to your auth endpoint:

```rust
// In crates/client/src/client.rs
// Update the authentication URL to point to your endpoint

pub static WITCHCRAFT_AUTH_URL: LazyLock<String> = LazyLock::new(|| {
    std::env::var("WITCHCRAFT_AUTH_ENDPOINT")
        .unwrap_or_else(|_| "https://your-api.com/auth".to_string())
});
```

## Cron Jobs Setup

### 11. Daily Maintenance (Run at 2 AM)

```sql
-- Using pg_cron extension
SELECT cron.schedule('daily-maintenance', '0 2 * * *', 'SELECT daily_maintenance()');
```

### 12. Monthly Quota Reset (Run on 1st of each month)

```sql
SELECT cron.schedule('monthly-quota-reset', '0 0 1 * *', 'SELECT monthly_maintenance()');
```

## Testing

### 13. Test User Creation

```typescript
// Test script
async function testUserFlow() {
  // Register
  const { userId } = await registerUser('test@example.com', 'password123', 'Test User');
  console.log('User created:', userId);
  
  // Login
  const { accessToken } = await loginUser('test@example.com', 'password123');
  console.log('Access token:', accessToken);
  
  // Validate token
  const user = await validateToken(accessToken);
  console.log('Validated user:', user);
  
  // Track AI usage
  const requestId = await trackAIUsage(
    userId,
    'ollama',
    'llama2',
    'understand',
    100,
    50,
    0.0,
    0.0,
    1500,
    null,
    true
  );
  console.log('AI request tracked:', requestId);
  
  // Check quota
  const quota = await getRemainingQuota(userId);
  console.log('Remaining quota:', quota);
}
```

## Security Best Practices

1. **Always hash passwords** with bcrypt (10+ rounds)
2. **Use HTTPS** for all API endpoints
3. **Validate input** on all endpoints
4. **Rate limit** authentication endpoints
5. **Use service role key** only on backend
6. **Enable RLS** in Supabase
7. **Rotate tokens** regularly (30-day expiry)
8. **Log security events** in audit_logs
9. **Monitor failed login attempts**
10. **Use prepared statements** to prevent SQL injection

## Next Steps

1. Deploy your authentication backend
2. Configure Supabase project
3. Run all SQL migration files
4. Set up cron jobs for maintenance
5. Update Witchcraft client configuration
6. Test the complete flow
7. Monitor usage and performance

For more information, see the main README.md file.


