#!/usr/bin/env bash
# ufw + fail2ban + a swapfile. Deliberately does NOT touch SSH config —
# that stays a manual, checkpointed process (see VPS-SETUP.md Phase 3),
# since it's the one step here where a bug can lock you out remotely.
#
# Safe to re-run (idempotent) — skips steps that are already done.
#
# Usage: ./base-hardening.sh [extra-tcp-port ...]
#   e.g. ./base-hardening.sh 80 443
# 22/tcp is always allowed. No other ports are opened unless passed in.
set -euo pipefail

EXTRA_PORTS=("$@")

echo "==> Installing ufw and fail2ban"
sudo apt-get update
sudo apt-get install -y ufw fail2ban

echo "==> Configuring ufw"
sudo ufw default deny incoming
sudo ufw default allow outgoing
sudo ufw allow 22/tcp
for port in "${EXTRA_PORTS[@]}"; do
  echo "    allowing ${port}/tcp"
  sudo ufw allow "${port}/tcp"
done
sudo ufw --force enable

echo "==> Configuring fail2ban (sshd jail)"
sudo tee /etc/fail2ban/jail.local >/dev/null <<'EOF'
[sshd]
enabled = true
maxretry = 5
findtime = 600
bantime = 3600
EOF
sudo systemctl enable --now fail2ban
sudo systemctl restart fail2ban

echo "==> Swapfile (2G, swappiness=10) if not already present"
if [ -f /swapfile ] || swapon --show | grep -q .; then
  echo "Swap already active, skipping."
else
  sudo fallocate -l 2G /swapfile
  sudo chmod 600 /swapfile
  sudo mkswap /swapfile
  sudo swapon /swapfile
  grep -q '/swapfile' /etc/fstab || echo '/swapfile none swap sw 0 0' | sudo tee -a /etc/fstab
  grep -q 'vm.swappiness' /etc/sysctl.conf || echo 'vm.swappiness=10' | sudo tee -a /etc/sysctl.conf
  sudo sysctl -p
fi

echo "==> Verifying"
sudo ufw status verbose
sudo fail2ban-client status sshd
swapon --show
echo "==> Done."
