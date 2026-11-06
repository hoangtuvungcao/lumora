#!/usr/bin/env bash
# One-command Lumora relay install on a fresh Linux VPS (Debian/Ubuntu/Fedora/...).
#
#   git clone <lumora repo> && cd lumora/relay/vps && sudo ./install-vps.sh
#
# Non-interactive: DOMAIN=relay.example.com sudo -E ./install-vps.sh
# Installs Docker if missing, writes .env, builds and starts relay + Caddy,
# and prints the wss:// URL to paste into the app (Settings -> Network -> Relays).
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$HERE"

say()  { printf '\033[1;32m==>\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33m!!\033[0m %s\n' "$*" >&2; }
die()  { printf '\033[1;31mxx\033[0m %s\n' "$*" >&2; exit 1; }

SUDO=""
if [ "$(id -u)" -ne 0 ]; then
  command -v sudo >/dev/null || die "run as root (or install sudo)"
  SUDO="sudo"
fi

[ -f ../../core/Cargo.toml ] || die "core/ workspace not found next to relay/ — run this from a full checkout of the Lumora repository"

# --- Docker ----------------------------------------------------------------
if ! command -v docker >/dev/null 2>&1; then
  say "Installing Docker (get.docker.com)"
  curl -fsSL https://get.docker.com | $SUDO sh
  $SUDO systemctl enable --now docker 2>/dev/null || true
fi
$SUDO docker compose version >/dev/null 2>&1 || die "docker compose plugin missing (install docker-compose-plugin)"

# --- Domain ----------------------------------------------------------------
PUBLIC_IP="$(curl -4 -fsS --max-time 5 https://api.ipify.org 2>/dev/null || true)"
if [ -z "${DOMAIN:-}" ] && [ -f .env ]; then
  DOMAIN="$(grep -E '^DOMAIN=' .env | head -1 | cut -d= -f2- || true)"
  [ "$DOMAIN" = "relay.example.com" ] && DOMAIN=""
fi
if [ -z "${DOMAIN:-}" ]; then
  SUGGEST=""
  [ -n "$PUBLIC_IP" ] && SUGGEST="${PUBLIC_IP}.sslip.io"
  echo "Domain name for this relay (DNS A/AAAA record must point to this server)."
  [ -n "$SUGGEST" ] && echo "No domain? Press Enter to use ${SUGGEST} (free wildcard DNS)."
  read -rp "Domain: " DOMAIN </dev/tty || true
  DOMAIN="${DOMAIN:-$SUGGEST}"
fi
[ -n "$DOMAIN" ] || die "a domain is required for automatic HTTPS"
DOMAIN="${DOMAIN#https://}"; DOMAIN="${DOMAIN#wss://}"; DOMAIN="${DOMAIN%%/*}"

if command -v getent >/dev/null && [ -n "$PUBLIC_IP" ]; then
  RESOLVED="$(getent ahostsv4 "$DOMAIN" 2>/dev/null | awk 'NR==1{print $1}')"
  if [ -n "$RESOLVED" ] && [ "$RESOLVED" != "$PUBLIC_IP" ]; then
    warn "$DOMAIN resolves to $RESOLVED but this server looks like $PUBLIC_IP — certificate issuance may fail"
  elif [ -z "$RESOLVED" ]; then
    warn "$DOMAIN does not resolve yet — Caddy will keep retrying until DNS is set"
  fi
fi

# --- .env ------------------------------------------------------------------
if [ -f .env ]; then
  sed -i.bak "s|^DOMAIN=.*|DOMAIN=${DOMAIN}|" .env
  grep -q '^DOMAIN=' .env || echo "DOMAIN=${DOMAIN}" >> .env
else
  sed "s|^DOMAIN=.*|DOMAIN=${DOMAIN}|" .env.example > .env
fi
chmod 600 .env
say "Wrote $HERE/.env (DOMAIN=$DOMAIN)"

# --- Firewall (only if ufw is active) ---------------------------------------
if command -v ufw >/dev/null && $SUDO ufw status 2>/dev/null | grep -q "Status: active"; then
  say "Opening firewall ports 80/tcp 443/tcp 443/udp 3478/udp"
  for p in 80/tcp 443/tcp 443/udp 3478/udp; do $SUDO ufw allow "$p" >/dev/null; done
fi

# --- Start -----------------------------------------------------------------
say "Building and starting (first build takes a few minutes)"
$SUDO docker compose up -d --build

say "Waiting for https://$DOMAIN/health"
for _ in $(seq 1 60); do
  if curl -fsS --max-time 5 "https://$DOMAIN/health" >/dev/null 2>&1; then
    OK=1; break
  fi
  sleep 5
done
if [ "${OK:-0}" != 1 ]; then
  warn "relay not reachable over HTTPS yet; check: docker compose logs -f caddy relay"
fi

echo
say "Relay URL (paste into the app):"
echo
echo "    wss://${DOMAIN}/ws"
echo
echo "STUN server:  ${DOMAIN}:$(grep -E '^STUN_PORT=' .env | cut -d= -f2- || echo 3478)"
echo "Health:       https://${DOMAIN}/health"
echo "Logs:         cd $HERE && docker compose logs -f"
echo "Update:       git pull && docker compose up -d --build"
