# Rotating `INTERNAL_API_KEY` (auth ↔ relay)

`INTERNAL_API_KEY` is the shared secret on the `X-Internal-Key` header that
authenticates auth → relay internal calls (and the other direction). Both
workers must hold the same value — a rotation that desyncs the two will break
internal pushes.

## When to rotate

- **Suspected leak** (key checked into git, shared over an insecure channel,
  ex-employee access, anomalous traffic): rotate immediately.
- **Scheduled**: quarterly, or whenever the team's secret-hygiene review
  happens — whichever is sooner.

## Steps

An automation script lives at
[`scripts/rotate-relay-internal-key.sh`](../scripts/rotate-relay-internal-key.sh).
It automates steps 1–3 and supports `--dry-run` (default) and `--confirm`
flags. It requires a logged-in `wrangler` session.

### Manual steps (what the script does)

1. Generate 32 random bytes:
   ```bash
   openssl rand -base64 32
   ```
2. Write the new value to the auth worker:
   ```bash
   wrangler secret put INTERNAL_API_KEY --name blip-auth
   # paste the value from step 1
   ```
3. Write the **same** value to the relay worker:
   ```bash
   wrangler secret put INTERNAL_API_KEY --name blip-relay
   # paste the same value
   ```
4. Verify with a curl smoke test against the relay's internal endpoint:
   ```bash
   curl -X POST "$RELAY_INTERNAL_URL/internal/push" \
     -H "X-Internal-Key: <NEW_KEY>" \
     -H "Content-Type: application/json" \
     -d '{"recipientPeerIdHex":"0011223344556677","senderPeerIdHex":"AABBCCDDEEFF0011","type":"dm","threadId":"00000000-0000-0000-0000-000000000001","badgeCount":1}'
   ```
   Expect a `200` response and a push arriving on the test device.
5. Observe both workers for 10 minutes after the rotation:
   ```bash
   wrangler tail blip-auth  --format pretty
   wrangler tail blip-relay --format pretty
   ```
   No `401 Unauthorized` storms on either side = clean rollover.

### Using the script

```bash
# default — generates a new key, prints a sha256 preview, does NOT write
./scripts/rotate-relay-internal-key.sh --dry-run

# actually rotate both workers
./scripts/rotate-relay-internal-key.sh --confirm
```

The script never prints the raw key to stdout — only a 12-char sha256 preview
so you can correlate with telemetry.

## Rollback

If step 5 shows auth errors, the workers are out of sync. Re-run the script
(or manual steps 2–3) with the **previous** key to roll back. Wrangler keeps
the last-set value, so a second rotation to the old key restores service.
