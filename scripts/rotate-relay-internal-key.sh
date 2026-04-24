#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat <<'EOF'
Usage: rotate-relay-internal-key.sh [--dry-run] [--confirm]
Generates a new INTERNAL_API_KEY and writes it to both blip-auth and blip-relay
workers via `wrangler secret put`. Requires wrangler logged in.
EOF
  exit "${1:-0}"
}

DRY_RUN=true
[ "${1:-}" = "--help" ] && usage 0
for arg in "$@"; do
  case "$arg" in
    --dry-run) DRY_RUN=true ;;
    --confirm) DRY_RUN=false ;;
    --help) usage 0 ;;
    *) usage 1 ;;
  esac
done

NEW_KEY=$(openssl rand -base64 32 | tr -d '=\n')
echo "Generated 32-byte INTERNAL_API_KEY (redacted)"
echo "Hash preview: $(printf '%s' "$NEW_KEY" | sha256sum | cut -c1-12)"

if $DRY_RUN; then
  echo "DRY RUN — re-run with --confirm to actually rotate."
  exit 0
fi

command -v wrangler >/dev/null 2>&1 || { echo "wrangler CLI not found" >&2; exit 2; }

echo "Writing to blip-auth..."
printf '%s' "$NEW_KEY" | wrangler secret put INTERNAL_API_KEY --name blip-auth

echo "Writing to blip-relay..."
printf '%s' "$NEW_KEY" | wrangler secret put INTERNAL_API_KEY --name blip-relay

echo "Rotation complete. Run 'wrangler tail' on both workers for 10 min to confirm."
