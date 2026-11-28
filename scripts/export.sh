#!/usr/bin/env bash
# Re-exports the homelab configuration into this repo.
# - Read-only on the infra: cat / pct list / qm list / qm config only.
# - Secret files (.env, caddy.env, cloudflared token) are never read;
#   only variable NAMES are compared with the .env.example files.
# - Domain, e-mail and MAC addresses are replaced or masked.
# - Exits 1 if a secret, the real domain, an e-mail, a MAC or a disk serial remains.
#
# Usage: scripts/export.sh        (PVE=root@IP to target another host)
set -euo pipefail

PVE="${PVE:-root@192.168.1.200}"
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SOCK="${TMPDIR:-/tmp}/homelab-export-$$.sock"
SSH=(ssh -o BatchMode=yes -o ControlMaster=auto -o ControlPath="$SOCK" -o ControlPersist=60)
trap '"${SSH[@]}" -O exit "$PVE" 2>/dev/null || true' EXIT

r()   { "${SSH[@]}" "$PVE" "$1" </dev/null; }   # stdin closed: safe inside while-read loops
get() { r "pct exec $1 -- cat $2"; }
warn() { printf '  ⚠ %s\n' "$*"; WARN=$((WARN+1)); }
WARN=0

# Real domain: only used to detect and replace it, never written to the repo
CADDYFILE="$(get 100 /etc/caddy/Caddyfile)"
DOMAIN_REAL="$(printf '%s\n' "$CADDYFILE" | sed -nE 's/^\*\.([A-Za-z0-9.-]+)[[:space:]]*\{.*/\1/p' | head -1)"
if [ -z "$DOMAIN_REAL" ] || [[ "$DOMAIN_REAL" == *'{$'* ]]; then
  # Caddyfile already uses {$DOMAIN}: read only the DOMAIN= line, never the token
  DOMAIN_REAL="$(r "pct exec 100 -- sed -n 's/^DOMAIN=//p' /etc/caddy/caddy.env" | tr -d '\"\r')"
fi
[ -n "$DOMAIN_REAL" ] || { echo "Domaine introuvable (Caddyfile ni caddy.env), abandon."; exit 1; }
D_RE="${DOMAIN_REAL//./\\.}"
EMAIL_RE='[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}'

anon_caddy() { sed -E "s/$EMAIL_RE/{\$ACME_EMAIL}/g; s/$D_RE/{\$DOMAIN}/g"; }
anon()       { sed -E "s/$EMAIL_RE/\${ACME_EMAIL}/g; s/$D_RE/\${DOMAIN}/g; s/$MAC_RE/\1XX:XX:XX/g"; }

# Keep the vendor prefix (BC:24:11 = Proxmox), mask the rest
MAC_RE='(([0-9A-Fa-f]{2}:){3})[0-9A-Fa-f]{2}:[0-9A-Fa-f]{2}:[0-9A-Fa-f]{2}'
# Host local domain (e.g. pve.<name>.local): must never be exported
LOCAL_DOMAIN="$(r 'hostname -d' | tr -d '\r')"

echo "== Hôte"
mkdir -p "$ROOT"/host "$ROOT"/proxmox/{lxc,vm}
r 'cat /etc/network/interfaces'      > "$ROOT/host/interfaces"
r 'cat /etc/pve/storage.cfg'         > "$ROOT/host/storage.cfg"
if r 'crontab -l 2>/dev/null || true' | grep -v '^#' | grep -q .; then
  warn "crontab root non vide : à documenter"
fi
# PVE >= 7.1 stores backup jobs in jobs.cfg; vzdump.cron is the legacy location
if r 'grep -hE "^vzdump:" /etc/pve/jobs.cfg 2>/dev/null; grep -vhE "^(#|PATH|\s*$)" /etc/pve/vzdump.cron 2>/dev/null; true' | grep -q .; then
  echo "  vzdump : des tâches existent (voir l'UI)"
else
  warn "aucune tâche vzdump (pas de sauvegarde PVE)"
fi

echo "== LXC"
LXC="$(r 'pct list' | awk 'NR>1{print $1" "$NF}')"
rm -f "$ROOT"/proxmox/lxc/*.conf
while read -r id name; do
  r "cat /etc/pve/lxc/$id.conf" | anon > "$ROOT/proxmox/lxc/$id-$name.conf"
  echo "  $id-$name.conf"
done <<< "$LXC"

echo "== VM"
rm -f "$ROOT"/proxmox/vm/*.conf
VMS="$(r 'qm list' | awk 'NR>1{print $1" "$2}')"
if [ -z "$VMS" ]; then echo "  aucune VM"; else
  while read -r id name; do
    r "qm config $id" | anon > "$ROOT/proxmox/vm/$id-$name.conf"; echo "  $id-$name.conf"
  done <<< "$VMS"
fi

echo "== Services"
S="$ROOT/services"; mkdir -p "$S"/{caddy,cloudflared,n8n,nextcloud}
printf '%s\n' "$CADDYFILE" | anon_caddy                              > "$S/caddy/Caddyfile"
get 100 /etc/systemd/system/caddy.service.d/override.conf | anon     > "$S/caddy/override.conf"
for u in cloudflared.service cloudflared-update.service cloudflared-update.timer; do
  get 101 /etc/systemd/system/$u                                     > "$S/cloudflared/$u"
done
get 102 /opt/n8n/docker-compose.yml | anon                           > "$S/n8n/docker-compose.yml"
get 103 /opt/nextcloud/docker-compose.yml | anon                     > "$S/nextcloud/docker-compose.yml"

echo "== Variables d'environnement (noms uniquement)"
names_remote() { r "pct exec $1 -- sed -nE 's/^([A-Za-z_][A-Za-z0-9_]*)=.*/\\1/p' $2" | sort -u; }
names_example() { sed -nE 's/^([A-Za-z_][A-Za-z0-9_]*)=.*/\1/p' "$1" | sort -u; }
check_env() { # <lxc id> <remote env file> <.env.example>
  local missing; missing="$(comm -23 <(names_remote "$1" "$2") <(names_example "$3"))"
  if [ -z "$missing" ]; then
    echo "  $3 : à jour"
  else
    warn "$(basename "$(dirname "$3")") : variables absentes de .env.example → ${missing//$'\n'/ }"
  fi
}
check_env 100 /etc/caddy/caddy.env      "$S/caddy/.env.example"
check_env 102 /opt/n8n/.env             "$S/n8n/.env.example"
check_env 103 /opt/nextcloud/.env       "$S/nextcloud/.env.example"

echo "== Nouveaux invités sans dossier services/"
while read -r id name; do
  [ -d "$S/$name" ] || warn "LXC $id ($name) : pas de dossier services/$name"
done <<< "$LXC"

echo "== Contrôle anti-fuite"
LEAK=0
# Prints file:line only, never the matched content
report() { [ -z "$2" ] && return 0; printf '%s\n' "$2" | cut -d: -f1,2 | sed "s|^$ROOT/|  ✗ $1 : |"; LEAK=1; }
EX=(--exclude-dir=.git --exclude=export.sh --exclude=check-sanitized.sh)
# Host-specific values: only known here, so not covered by check-sanitized.sh
report "domaine réel" "$(grep -rnIF "${EX[@]}" -- "$DOMAIN_REAL" "$ROOT" || true)"
if [ -n "$LOCAL_DOMAIN" ]; then
  report "domaine local" "$(grep -rnIF "${EX[@]}" -- "$LOCAL_DOMAIN" "$ROOT" || true)"
fi
# Generic patterns (e-mails, MACs, disk serials, literal secrets, key formats, forbidden files): same check as CI
"$ROOT/scripts/check-sanitized.sh" "$ROOT" || LEAK=1
if command -v gitleaks >/dev/null; then
  gitleaks dir --redact -v "$ROOT" || LEAK=1
else
  echo "  (gitleaks absent : brew install gitleaks)"
fi

echo
if [ "$LEAK" -ne 0 ]; then echo "ÉCHEC : fuite potentielle, NE PAS COMMITER."; exit 1; fi
echo "OK : aucun secret détecté. $WARN avertissement(s). Vérifie 'git diff' avant de commiter."
