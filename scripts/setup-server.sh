#!/usr/bin/env bash
# One-shot server setup for an already-provisioned VM with Docker installed.
# Safe to re-run: every step checks before it changes anything.
#
#   git clone https://github.com/daphnecharles/sparx-contact-sync ~/n8n-stack
#   cd ~/n8n-stack && bash scripts/setup-server.sh automate.sparxlabs.io you@yourcompany.com
#
# The second argument is the Let's Encrypt contact email (expiry warnings go there).
#
# Steps: swap → VM firewall ports → .env with generated secrets → DNS check → launch.
set -euo pipefail
cd "$(dirname "$0")/.."

DOMAIN="${1:-automate.sparxlabs.io}"
ACME_EMAIL="${2:-}"
CADDY_IMAGE="caddy:2.11.7"

DOCKER="docker"
if ! docker info >/dev/null 2>&1; then DOCKER="sudo docker"; fi

step() { printf '\n\033[1m== %s\033[0m\n' "$*"; }

# ---------------------------------------------------------------- 1. swap
step "1/5 Swap"
if [ -z "$(swapon --show --noheadings)" ]; then
  echo "No swap found — adding a 2G /swapfile"
  sudo fallocate -l 2G /swapfile
  sudo chmod 600 /swapfile
  sudo mkswap /swapfile
  sudo swapon /swapfile
  grep -q '^/swapfile ' /etc/fstab || echo '/swapfile none swap sw 0 0' | sudo tee -a /etc/fstab >/dev/null
else
  echo "Swap already present"
fi
free -h

# ---------------------------------------------------------------- 2. firewall
step "2/5 VM firewall (ports 80/443)"
# Oracle's Ubuntu images REJECT everything but SSH in iptables. This opens 80/443
# on the VM itself; the VCN security list in the Oracle console must allow them too.
changed=0
for rule in "-p tcp --dport 80" "-p tcp --dport 443" "-p udp --dport 443"; do
  # shellcheck disable=SC2086
  if ! sudo iptables -C INPUT $rule -j ACCEPT 2>/dev/null; then
    sudo iptables -I INPUT 1 $rule -j ACCEPT; changed=1
  fi
done
if [ "$changed" = 1 ]; then
  if command -v netfilter-persistent >/dev/null; then sudo netfilter-persistent save
  else echo "WARNING: netfilter-persistent not installed; rules will reset on reboot (sudo apt-get install -y iptables-persistent)"; fi
fi
echo "OK"

# ---------------------------------------------------------------- 3. .env
step "3/5 .env"
if [ -f .env ]; then
  echo ".env already exists — leaving it untouched"
else
  if [ -z "$ACME_EMAIL" ]; then read -rp "Email for Let's Encrypt notices: " ACME_EMAIL; fi
  pw="$(openssl rand -base64 24 | tr -d '/+=' | cut -c1-24)"
  hash="$($DOCKER run --rm "$CADDY_IMAGE" caddy hash-password --plaintext "$pw")"
  cat > .env <<EOF
N8N_DOMAIN=${DOMAIN}
ACME_EMAIL=${ACME_EMAIL}
BASIC_AUTH_USER=admin
BASIC_AUTH_HASH='${hash}'
N8N_ENCRYPTION_KEY=$(openssl rand -hex 32)
TIMEZONE=America/New_York
WEBHOOK_SHARED_SECRET=$(openssl rand -hex 24)
# Fill these in before activating the workflows (then: docker compose up -d)
KIT_SEQUENCE_ID=
SUBSTACK_PUBLISHER_EMAILS=
EOF
  chmod 600 .env
  cat <<EOF

  ┌──────────────────────────────────────────────────────────────┐
  │ Browser login (shown ONCE — save it in the password manager) │
  │   user:     admin                                            │
  │   password: ${pw}                         │
  └──────────────────────────────────────────────────────────────┘
  Also copy .env itself into the password manager — N8N_ENCRYPTION_KEY
  is required to restore credentials from a backup.
EOF
fi

# ---------------------------------------------------------------- 4. DNS
step "4/5 DNS"
public_ip="$(curl -fsS --max-time 5 https://ifconfig.me 2>/dev/null || true)"
resolved="$( (dig +short "$DOMAIN" A 2>/dev/null || getent ahostsv4 "$DOMAIN" | awk '{print $1}') | grep -E '^[0-9.]+$' | head -1 || true)"
echo "VM public IP:   ${public_ip:-unknown}"
echo "${DOMAIN} → ${resolved:-<not resolving>}"
if [ -z "$resolved" ] || { [ -n "$public_ip" ] && [ "$resolved" != "$public_ip" ]; }; then
  echo "STOP: DNS does not point at this VM yet. Fix the A record, wait, and re-run this script."
  echo "      (Launching now would make Caddy's certificate request fail.)"
  exit 1
fi

# ---------------------------------------------------------------- 5. launch
step "5/5 Launch"
$DOCKER compose pull
$DOCKER compose up -d
echo "Waiting for the certificate (up to 2 minutes)…"
for _ in $(seq 1 24); do
  if $DOCKER compose logs caddy 2>&1 | grep -c "certificate obtained successfully" >/dev/null; then
    echo "Certificate obtained."; break
  fi
  sleep 5
done
$DOCKER compose ps
echo
echo "Next: open https://${DOMAIN} — log in with the admin password above, then"
echo "create the n8n owner account (first visit only). Logs: $DOCKER compose logs -f"
