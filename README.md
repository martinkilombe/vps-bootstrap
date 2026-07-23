# vps-bootstrap

A reusable, provider-agnostic runbook for taking a fresh Ubuntu VPS from
"just created" to hardened-and-ready: SSH key-only access, firewall,
Docker, and optional Portainer / monitoring. Distilled from two real
deployments (a Contabo box running a live Odoo/POS stack, and an Oracle
free-tier box running Uptime Kuma as an external watchdog) — every
gotcha called out in `VPS-SETUP.md` actually happened on one of those two
boxes, it isn't theoretical.

## How to use this

Read `VPS-SETUP.md` and work through it **phase by phase, in order**.
Each phase has:
- the commands to run
- a verification step to run immediately after — **do not skip these and
  move to the next phase on faith.** Several phases here look correct
  from output/config alone while being silently wrong underneath (see the
  SSH phase in particular).

This is written so another AI agent (or you) can drive a brand-new VPS
through it interactively, pausing at each verification checkpoint rather
than running everything unattended. The SSH hardening phase especially
should never be run as a single unattended step — locking in key-only
access before independently confirming key auth already works is the
classic way to lock yourself out permanently.

## What's generic vs. what isn't

This repo intentionally contains **no IPs, hostnames, domains, usernames
beyond a placeholder, or secret values.** It's a reusable procedure, not
a record of any specific box. Box-specific state (what's actually
deployed, current IPs, decisions made for that instance) belongs in that
project's own runbook — e.g. this pattern was extracted out of
`deployment.md` in the Odoo project repo, which remains the source of
truth for that specific instance's live status.

## Contents

- `VPS-SETUP.md` — the runbook itself.
- `scripts/docker-install.sh` — Docker Engine install from the official
  repo, including the GPG fingerprint verification step. Idempotent, safe
  to re-run.
- `scripts/base-hardening.sh` — `ufw` + `fail2ban` + swapfile. Idempotent,
  safe to re-run. Deliberately does **not** touch SSH config — that stays
  manual, see above. (Docker's own log rotation is handled inside
  `docker-install.sh`, not this script.)

## Scope

Covers a single VPS, key-only SSH, Docker, and optionally Portainer and
an on-box monitoring stack (Beszel-pattern: hub + agent + socket-proxy).

**Does not cover, deliberately:**
- Setting up a *second*, independent box for external uptime monitoring
  (something that can tell you the first box is fully down) — that's a
  genuinely different pattern requiring separate infrastructure, noted
  in `VPS-SETUP.md` as a pointer, not built out here.
- **Application-data backup/disaster-recovery** (database dumps,
  filestore archives, off-site object storage). This doc hardens and
  provisions the box — it says nothing about backing up whatever you
  deploy on top of it. Treat that as a separate, mandatory task for
  anything holding real data; don't mistake "this VPS is set up" for
  "this VPS's data is safe."
- Automatic OS security updates (`unattended-upgrades`) — genuinely
  undecided, not just out of scope. Neither of the two real boxes this
  runbook is based on has it configured yet. It's a real tradeoff (patched
  automatically vs. an update landing unattended on a box running live
  services) worth deciding deliberately per box rather than defaulting
  either way — flagged here rather than silently assumed.
