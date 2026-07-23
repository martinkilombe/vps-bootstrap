#!/usr/bin/env bash
# Installs Docker Engine from Docker's official apt repository on
# Ubuntu, following the method documented at
# https://docs.docker.com/engine/install/ubuntu/ (checked 2026-07-23) —
# not a third-party curl-pipe-bash script.
#
# Safe to re-run (idempotent) — skips steps that are already done.
set -euo pipefail

if command -v docker >/dev/null 2>&1; then
  echo "Docker already installed: $(docker --version)"
else
  echo "==> Removing any conflicting distro-packaged Docker bits"
  for pkg in docker.io docker-doc docker-compose docker-compose-v2 podman-docker containerd runc; do
    sudo apt-get remove -y "$pkg" >/dev/null 2>&1 || true
  done

  echo "==> Installing prerequisites"
  sudo apt-get update
  sudo apt-get install -y ca-certificates curl

  echo "==> Adding Docker's official GPG key"
  sudo install -m 0755 -d /etc/apt/keyrings
  sudo curl -fsSL https://download.docker.com/linux/ubuntu/gpg -o /etc/apt/keyrings/docker.asc
  sudo chmod a+r /etc/apt/keyrings/docker.asc

  echo "==> Fingerprint of the key just downloaded — CHECK THIS MANUALLY"
  echo "    against https://docs.docker.com/engine/install/ubuntu/ before"
  echo "    trusting it. As of this script being written, Docker's own"
  echo "    install page does NOT publish a fingerprint to diff against on"
  echo "    that page directly — if that's still true when you run this,"
  echo "    cross-check the key some other independent way (e.g. Docker's"
  echo "    official GitHub org, or a second unrelated source) rather than"
  echo "    trusting a single download unverified. Do not skip this just"
  echo "    because it's inconvenient — that defeats the point."
  gpg --show-keys --with-fingerprint /etc/apt/keyrings/docker.asc

  echo "==> Adding Docker's apt repository (deb822 format, per current docs)"
  ARCH="$(dpkg --print-architecture)"
  CODENAME="$(. /etc/os-release && echo "${UBUNTU_CODENAME:-$VERSION_CODENAME}")"
  sudo tee /etc/apt/sources.list.d/docker.sources >/dev/null <<EOF
Types: deb
URIs: https://download.docker.com/linux/ubuntu
Suites: ${CODENAME}
Components: stable
Architectures: ${ARCH}
Signed-By: /etc/apt/keyrings/docker.asc
EOF

  echo "==> Installing Docker Engine"
  sudo apt-get update
  sudo apt-get install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin

  echo "==> Enabling Docker on boot"
  sudo systemctl enable --now docker
fi

echo "==> Setting log rotation (10m x 3 files) if not already configured"
DAEMON_JSON=/etc/docker/daemon.json
if [ ! -f "$DAEMON_JSON" ] || ! grep -q '"max-size"' "$DAEMON_JSON" 2>/dev/null; then
  sudo tee "$DAEMON_JSON" >/dev/null <<'EOF'
{
  "log-driver": "json-file",
  "log-opts": { "max-size": "10m", "max-file": "3" }
}
EOF
  sudo systemctl restart docker
else
  echo "Log rotation already configured, leaving as-is."
fi

echo "==> Verifying"
docker run --rm hello-world
echo "==> Done. Confirm you actually checked the GPG fingerprint above, not just glanced at it."
