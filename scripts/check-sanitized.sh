#!/usr/bin/env bash
# Static leak check on the repo content, no access to the host needed.
# Runs in CI; the same patterns are used by export.sh after an export.
# Prints file:line only, never the matched content. Exits 1 on any finding.
#
# Usage: scripts/check-sanitized.sh [repo root]
set -euo pipefail

ROOT="$(cd "${1:-$(dirname "$0")/..}" && pwd)"
LEAK=0
EX=(--exclude-dir=.git --exclude=export.sh --exclude=check-sanitized.sh)

report() { # <label> <grep output>
  [ -z "$2" ] && return 0
  printf '%s\n' "$2" | cut -d: -f1,2 | sed "s|^$ROOT/|  ✗ $1: |"
  LEAK=1
}
scan() { # <label> <grep -E pattern> [extra grep args...] -- <paths...>
  local label="$1" pattern="$2"; shift 2
  local args=() paths=()
  while [ "$#" -gt 0 ] && [ "$1" != "--" ]; do args+=("$1"); shift; done
  shift
  for p in "$@"; do [ -e "$p" ] && paths+=("$p"); done
  [ "${#paths[@]}" -eq 0 ] && return 0
  report "$label" "$(grep -rnIE "${EX[@]}" ${args[@]+"${args[@]}"} -- "$pattern" "${paths[@]}" || true)"
}

EMAIL_RE='[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}'

# E-mails: docs and .env.example only hold placeholders (example.com)
scan "e-mail" "$EMAIL_RE" --exclude='*.md' --exclude='.env.example' -- "$ROOT"
# Literal secret values in configs (comments and .env.example excluded)
scan "literal secret?" '^[^#]*(TOKEN|_KEY|PASSWORD|SECRET|PASS)[A-Z_]*[=:][[:space:]]*[^$[:space:]{"]' \
  --exclude='.env.example' --exclude='*.md' -- "$ROOT/services" "$ROOT/proxmox" "$ROOT/host"
# Known key formats
scan "key pattern" '-----BEGIN|sk-or-|sk-[A-Za-z0-9]{20}|eyJ[A-Za-z0-9_-]{20,}|[0-9]{8,10}:AA[A-Za-z0-9_-]{30}|[a-f0-9]{64}' -- "$ROOT"
# Hardware identifiers: exported MACs are masked as XX:XX:XX:XX:XX:XX tail
scan "real MAC address" '([0-9A-Fa-f]{2}:){5}[0-9A-Fa-f]{2}' -- "$ROOT"
scan "disk serial" 'ata-[A-Za-z0-9_-]+|_WD-[A-Z0-9]{6,}|nvme-[A-Za-z0-9_]+_[A-Z0-9]{8,}' -- "$ROOT"
# Local host domain (e.g. pve.<name>.local)
scan "local domain" '\.(local|lan|home|internal)\b' -- "$ROOT/host" "$ROOT/proxmox" "$ROOT/services"

# Forbidden files
report "forbidden file" "$(find "$ROOT" -path "$ROOT/.git" -prune -o -type f \( -name '.env' -o -name '*.env' \
  -o -name '*.pem' -o -name '*.key' -o -name 'token' -o -name 'credentials*.json' \) -print | sed 's/$/:-/')"

if [ "$LEAK" -ne 0 ]; then echo "FAIL: potential leak, do not merge."; exit 1; fi
echo "OK: no leak pattern found."
