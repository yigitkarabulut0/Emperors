#!/usr/bin/env bash
# Put the game server on a fresh Hetzner box and keep it there.
#
# Builds ON the server rather than locally. The Dockerfile is multi-stage and
# self-contained, the box has more CPU than the laptop, and it removes the whole
# class of failure where an image built on Apple Silicon dies with "exec format
# error" on an amd64 VPS.
#
# The domain is <ip-with-dashes>.sslip.io, which resolves to the IP with no DNS
# setup at all -- and, being a real name, lets Caddy issue a real Let's Encrypt
# certificate. That is not optional even in development: iOS App Transport
# Security refuses self-signed certs, so the phone would not talk to us at all.
#
# Usage: scripts/deploy-hetzner.sh <server-ip> [ssh-user]
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
IP="${1:?usage: deploy-hetzner.sh <server-ip> [ssh-user]}"
USER="${2:-root}"
KEY="$HOME/.ssh/emperors_deploy"
DOMAIN="${IP//./-}.sslip.io"
REMOTE="/opt/emperors"
VERSION="$(git -C "$(cd "$(dirname "$0")/.." && pwd)" rev-parse --short HEAD)"
SSH=(ssh -i "$KEY" -o StrictHostKeyChecking=accept-new -o ConnectTimeout=15 "$USER@$IP")

[ -f "$ROOT/infra/secrets.env" ] || { echo "infra/secrets.env is missing" >&2; exit 1; }
[ -f "$KEY" ] || { echo "no deploy key at $KEY" >&2; exit 1; }

echo "==> $USER@$IP  ->  https://$DOMAIN"

echo "==> installing docker if it is not there"
"${SSH[@]}" 'command -v docker >/dev/null || (
  export DEBIAN_FRONTEND=noninteractive
  apt-get update -qq
  apt-get install -y -qq ca-certificates curl rsync >/dev/null
  install -m 0755 -d /etc/apt/keyrings
  curl -fsSL https://download.docker.com/linux/ubuntu/gpg -o /etc/apt/keyrings/docker.asc
  chmod a+r /etc/apt/keyrings/docker.asc
  echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.asc] https://download.docker.com/linux/ubuntu $(. /etc/os-release && echo $VERSION_CODENAME) stable" > /etc/apt/sources.list.d/docker.list
  apt-get update -qq
  apt-get install -y -qq docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin >/dev/null
) && docker --version'

echo "==> copying the source"
"${SSH[@]}" "mkdir -p $REMOTE"
rsync -az --delete -e "ssh -i $KEY -o StrictHostKeyChecking=accept-new" \
  --exclude '.git' --exclude 'client' --exclude 'art' --exclude 'admin/node_modules' \
  --exclude 'proof' --exclude 'build' \
  "$ROOT/server" "$ROOT/infra" "$USER@$IP:$REMOTE/"

echo "==> writing the environment"
"${SSH[@]}" "cd $REMOTE/infra && printf 'EMPERORS_DOMAIN=%s\nCADDY_EMAIL=%s\nEMPERORS_VERSION=%s\n' \
  '$DOMAIN' '${CADDY_EMAIL:-admin@$DOMAIN}' '$VERSION' > .env"

echo "==> building (first build pulls the Go toolchain, so it is slow)"
# Tagged with the commit AND latest. compose asks for the commit tag, and without
# that tag existing locally it tries to pull from a registry nothing was pushed
# to and fails with "denied".
"${SSH[@]}" "cd $REMOTE && docker build -f infra/Dockerfile \
  --build-arg TARGETARCH=amd64 --build-arg VERSION=$VERSION \
  -t ghcr.io/yigitkarabulut0/emperors-api:$VERSION \
  -t ghcr.io/yigitkarabulut0/emperors-api:latest ."

echo "==> migrating the database"
"${SSH[@]}" "cd $REMOTE/infra && docker run --rm --env-file secrets.env \
  --entrypoint /migrate ghcr.io/yigitkarabulut0/emperors-api:latest up"

echo "==> starting"
# Caddy really does come from Docker Hub; only the API image is built here.
"${SSH[@]}" "docker pull -q caddy:2.11-alpine"
"${SSH[@]}" "cd $REMOTE/infra && docker compose up -d --remove-orphans && sleep 5 && docker compose ps"

echo "==> waiting for the certificate (Let's Encrypt takes a few seconds)"
for i in $(seq 1 30); do
  code="$(curl -s -o /dev/null -w '%{http_code}' --max-time 8 "https://$DOMAIN/healthz" || true)"
  [ "$code" = "200" ] && { echo "    healthy over TLS"; break; }
  sleep 5
done

echo
echo "API   https://$DOMAIN"
echo "check https://$DOMAIN/healthz"
