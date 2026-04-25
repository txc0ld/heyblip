-- 002_push_notifications.sql
-- Additive migration for HEY-1321 push notifications. Safe to re-run.
--
-- 1. device_tokens gains APNs routing flags (sandbox) + diagnostics
--    (locale, app_version, last_registered_at).
-- 2. notification_prefs table holds per-user push filters (toggles, quiet
--    hours, per-channel and per-friend mutes).

-- device_tokens: APNs routing + client diagnostics
ALTER TABLE device_tokens
  ADD COLUMN IF NOT EXISTS locale VARCHAR(32),
  ADD COLUMN IF NOT EXISTS app_version VARCHAR(32),
  ADD COLUMN IF NOT EXISTS sandbox BOOLEAN NOT NULL DEFAULT FALSE,
  ADD COLUMN IF NOT EXISTS last_registered_at TIMESTAMPTZ NOT NULL DEFAULT NOW();

-- notification_prefs: per-user push filters
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
