-- Blip user database schema (Neon Postgres)
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

-- Push notification device tokens
CREATE TABLE IF NOT EXISTS device_tokens (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    user_id UUID NOT NULL REFERENCES users(id) ON DELETE CASCADE,
    token VARCHAR(200) NOT NULL,
    platform VARCHAR(10) NOT NULL DEFAULT 'ios',
    bundle_id VARCHAR(100) NOT NULL DEFAULT 'au.heyblip.Blip',
    created_at TIMESTAMPTZ DEFAULT NOW(),
    updated_at TIMESTAMPTZ DEFAULT NOW(),
    UNIQUE(token)
);

CREATE INDEX IF NOT EXISTS idx_device_tokens_user_id ON device_tokens(user_id);

ALTER TABLE users ADD COLUMN IF NOT EXISTS peer_id_hex VARCHAR(16);
CREATE INDEX IF NOT EXISTS idx_users_peer_id_hex ON users(peer_id_hex);

-- HEY-1321 push notifications: APNs routing + client diagnostics on device_tokens
ALTER TABLE device_tokens
  ADD COLUMN IF NOT EXISTS locale VARCHAR(32),
  ADD COLUMN IF NOT EXISTS app_version VARCHAR(32),
  ADD COLUMN IF NOT EXISTS sandbox BOOLEAN NOT NULL DEFAULT FALSE,
  ADD COLUMN IF NOT EXISTS last_registered_at TIMESTAMPTZ NOT NULL DEFAULT NOW();

-- Per-user push preferences (toggles, quiet hours, per-channel/friend mutes)
CREATE TABLE IF NOT EXISTS notification_prefs (
    user_id UUID PRIMARY KEY REFERENCES users(id) ON DELETE CASCADE,
    dm_enabled BOOLEAN NOT NULL DEFAULT TRUE,
    friend_requests_enabled BOOLEAN NOT NULL DEFAULT TRUE,
    group_mentions_enabled BOOLEAN NOT NULL DEFAULT TRUE,
    voice_notes_enabled BOOLEAN NOT NULL DEFAULT TRUE,
    quiet_hours_start_utc INT,
    quiet_hours_end_utc INT,
    utc_offset_seconds INT NOT NULL DEFAULT 0,
    muted_channels JSONB NOT NULL DEFAULT '[]'::jsonb,
    muted_friends JSONB NOT NULL DEFAULT '[]'::jsonb,
    updated_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

CREATE INDEX IF NOT EXISTS notification_prefs_updated_idx ON notification_prefs(updated_at);
