# Witchcraft Database Quick Start Guide

Get your Witchcraft authentication and usage tracking up and running in 15 minutes.

## Prerequisites

- Supabase account (free tier works)
- Node.js backend for authentication
- Basic SQL knowledge

## Step 1: Create Supabase Project (2 minutes)

1. Go to https://supabase.com
2. Click "New Project"
3. Fill in:
   - **Name**: `witchcraft-db`
   - **Database Password**: (generate a strong password)
   - **Region**: (choose closest to your users)
4. Wait for project to be created
5. Save these values:
   - **Project URL**: `https://xxx.supabase.co`
   - **Anon Key**: `eyJhbGc...`
   - **Service Role Key**: `eyJhbGc...` (keep secret!)

## Step 2: Run Database Migrations (5 minutes)

1. In Supabase dashboard, go to **SQL Editor**
2. Run each file in order (copy/paste and click "Run"):

```
✅ 01_core_tables.sql        (Users, auth, profiles)
✅ 02_ai_usage_tables.sql    (AI tracking)
✅ 03_agent_sessions.sql     (Agent conversations)
✅ 04_billing_tables.sql     (Subscriptions, quotas)
✅ 05_indexes.sql            (Performance)
✅ 06_rls_policies.sql       (Security)
✅ 07_functions.sql          (Helper functions)
```

**Tip**: If you get errors, make sure you ran the previous files first!

## Step 3: Create Your Auth Backend (5 minutes)

### Option A: Node.js/Express Example

```bash
npm install express @supabase/supabase-js bcrypt jsonwebtoken
```

```javascript
// server.js
const express = require('express');
const { createClient } = require('@supabase/supabase-js');
const bcrypt = require('bcrypt');
const crypto = require('crypto');

const app = express();
app.use(express.json());

const supabase = createClient(
  process.env.SUPABASE_URL,
  process.env.SUPABASE_SERVICE_KEY
);

// Register endpoint
app.post('/auth/register', async (req, res) => {
  try {
    const { email, password, name } = req.body;
    const passwordHash = await bcrypt.hash(password, 10);
    
    const { data: userId } = await supabase.rpc('create_user_with_profile', {
      p_email: email,
      p_password_hash: passwordHash,
      p_name: name
    });
    
    res.json({ userId, message: 'User created successfully' });
  } catch (error) {
    res.status(400).json({ error: error.message });
  }
});

// Login endpoint
app.post('/auth/login', async (req, res) => {
  try {
    const { email, password } = req.body;
    
    const { data: user } = await supabase
      .from('users')
      .select('id, email, password_hash, is_active')
      .eq('email', email.toLowerCase())
      .is('deleted_at', null)
      .single();
    
    if (!user || !(await bcrypt.compare(password, user.password_hash))) {
      return res.status(401).json({ error: 'Invalid credentials' });
    }
    
    if (!user.is_active) {
      return res.status(403).json({ error: 'Account inactive' });
    }
    
    // Generate token
    const accessToken = crypto.randomBytes(32).toString('hex');
    const tokenHash = crypto.createHash('sha256').update(accessToken).digest('hex');
    
    await supabase.from('access_tokens').insert({
      user_id: user.id,
      token_hash: tokenHash
    });
    
    await supabase
      .from('users')
      .update({ last_login_at: new Date().toISOString() })
      .eq('id', user.id);
    
    res.json({ accessToken, userId: user.id, email: user.email });
  } catch (error) {
    res.status(400).json({ error: error.message });
  }
});

// Validate token endpoint
app.get('/auth/validate', async (req, res) => {
  try {
    const token = req.headers.authorization?.replace('Bearer ', '');
    if (!token) {
      return res.status(401).json({ error: 'No token provided' });
    }
    
    const tokenHash = crypto.createHash('sha256').update(token).digest('hex');
    
    const { data: accessToken } = await supabase
      .from('access_tokens')
      .select('user_id, users(id, email, name, is_admin)')
      .eq('token_hash', tokenHash)
      .is('revoked_at', null)
      .gt('expires_at', new Date().toISOString())
      .single();
    
    if (!accessToken) {
      return res.status(401).json({ error: 'Invalid token' });
    }
    
    res.json({ user: accessToken.users });
  } catch (error) {
    res.status(401).json({ error: 'Invalid token' });
  }
});

app.listen(3000, () => console.log('Auth server running on port 3000'));
```

### Run Your Server

```bash
# Create .env file
echo "SUPABASE_URL=https://xxx.supabase.co" > .env
echo "SUPABASE_SERVICE_KEY=your-service-key" >> .env

# Start server
node server.js
```

## Step 4: Test Your Setup (3 minutes)

```bash
# Test registration
curl -X POST http://localhost:3000/auth/register \
  -H "Content-Type: application/json" \
  -d '{"email":"test@example.com","password":"test123","name":"Test User"}'

# Test login
curl -X POST http://localhost:3000/auth/login \
  -H "Content-Type: application/json" \
  -d '{"email":"test@example.com","password":"test123"}'

# Test validation (use token from login response)
curl http://localhost:3000/auth/validate \
  -H "Authorization: Bearer YOUR_TOKEN_HERE"
```

## Step 5: Configure Witchcraft Client

Update Witchcraft to use your auth endpoint:

```bash
# Set environment variable
export WITCHCRAFT_AUTH_ENDPOINT="http://localhost:3000/auth"
```

Or in your Witchcraft config:

```json
{
  "auth": {
    "endpoint": "http://localhost:3000/auth"
  }
}
```

## Verify Everything Works

### Check Database

In Supabase SQL Editor:

```sql
-- Check users
SELECT id, email, name, created_at FROM users;

-- Check quotas
SELECT user_id, monthly_token_limit, tokens_used FROM user_quotas;

-- Check subscription tiers
SELECT name, display_name, price_usd_monthly FROM subscription_tiers;
```

### Check Auth Flow

1. ✅ Register a user
2. ✅ Login with credentials
3. ✅ Validate token
4. ✅ Check user appears in database

## Common Issues

### "relation does not exist"
- **Fix**: Run the SQL files in order (01, 02, 03, etc.)

### "permission denied"
- **Fix**: Use the **Service Role Key**, not the Anon Key

### "password hash invalid"
- **Fix**: Make sure you're using `bcrypt.hash()` with 10+ rounds

### "token validation fails"
- **Fix**: Check that you're hashing the token with SHA-256 before lookup

## Next Steps

1. **Add AI Usage Tracking**: See `API_INTEGRATION_EXAMPLES.md`
2. **Set up Billing**: Configure Stripe integration
3. **Enable Email**: Add SMTP for verification emails
4. **Deploy**: Move to production (Railway, Vercel, etc.)
5. **Monitor**: Set up Supabase alerts for quota limits

## Production Checklist

Before going live:

- [ ] Enable RLS policies (already done in step 2)
- [ ] Use HTTPS for all endpoints
- [ ] Set up rate limiting
- [ ] Configure CORS properly
- [ ] Add email verification
- [ ] Set up monitoring/logging
- [ ] Configure backups
- [ ] Add error tracking (Sentry)
- [ ] Set up cron jobs for maintenance
- [ ] Test quota limits
- [ ] Add password reset flow

## Support

- **Supabase Docs**: https://supabase.com/docs
- **Witchcraft Issues**: GitHub repository
- **Database Schema**: See `README.md` for detailed documentation

## Example Production Stack

```
┌─────────────────┐
│  Witchcraft App │
└────────┬────────┘
         │
         ↓
┌─────────────────┐
│  Your Auth API  │  (Railway/Vercel)
│  Node.js/Express│
└────────┬────────┘
         │
         ↓
┌─────────────────┐
│  Supabase DB    │  (Managed PostgreSQL)
└─────────────────┘
```

**Estimated Costs**:
- Supabase Free: $0/month (500MB database, 50K auth users)
- Railway/Vercel: $5-20/month
- **Total**: $5-20/month for small-medium usage

---

**You're all set!** 🎉

Your Witchcraft authentication and usage tracking is now ready to use.


