-- FestiChat user database schema (Neon Postgres)
-- Run this against your Neon database to initialize tables.

CREATE TABLE IF NOT EXISTS users (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    email_hash VARCHAR(64) UNIQUE NOT NULL,
    username VARCHAR(32) UNIQUE NOT NULL,
    is_verified BOOLEAN DEFAULT FALSE,
    message_balance INTEGER DEFAULT 0,
    last_active_at TIMESTAMPTZ,
    created_at TIMESTAMPTZ DEFAULT NOW(),
    updated_at TIMESTAMPTZ DEFAULT NOW()
);

-- Public keys for remote friend requests (BDEV: add-friend-by-username)
ALTER TABLE users ADD COLUMN IF NOT EXISTS noise_public_key BYTEA;
ALTER TABLE users ADD COLUMN IF NOT EXISTS signing_public_key BYTEA;

CREATE INDEX IF NOT EXISTS idx_users_email_hash ON users(email_hash);
CREATE INDEX IF NOT EXISTS idx_users_username ON users(username);
CREATE INDEX IF NOT EXISTS idx_users_username_lower ON users (LOWER(username));

-- Auto-update updated_at timestamp
CREATE OR REPLACE FUNCTION update_updated_at_column()
RETURNS TRIGGER AS $$
BEGIN
    NEW.updated_at = NOW();
    RETURN NEW;
END;
$$ language 'plpgsql';

CREATE TRIGGER update_users_updated_at
    BEFORE UPDATE ON users
    FOR EACH ROW
    EXECUTE FUNCTION update_updated_at_column();
