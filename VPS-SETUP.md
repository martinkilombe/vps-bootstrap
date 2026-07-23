# VPS Setup Runbook

Work through this **phase by phase, in order**. Every phase has a
verification step — run it before moving on. Several failure modes in
here look fine from the surface (config file reads correctly, command
exits 0, UI shows green) while being silently broken underneath; the
verification steps exist specifically to catch those, not as busywork.

Placeholders used throughout: `<VPS_IP>`, `<USER>` (the non-root sudo
user you create in Phase 2), `<TAILSCALE_IP>`, `<HOSTNAME>`. Replace with
real values for the box you're setting up — never commit real values
back into this repo.

---

## Phase 0 — Prerequisites

- A freshly created Ubuntu VPS (22.04 or 24.04 LTS) with root or a
  cloud-init default user, and its public IP.
- A local SSH keypair for this box specifically — **don't reuse a key
  across boxes.** `ssh-keygen -t ed25519 -C "<hostname>-<year>"`.
- Somewhere to store a backup copy of that key that isn't this laptop
  (password manager, gopass, etc.) — see the note in Phase 3 about
  verifying multiline secrets actually round-trip correctly.
- If you plan to gate any admin UI (Portainer, monitoring, etc.) behind
  it: a Tailscale account, and the box will need to join that tailnet.

**Secrets convention used in this doc**: real secrets (sudo passwords,
API tokens, SSH private keys) are never written into files that get
committed anywhere — they live in a password manager or `gopass`. If
using `gopass` for a multiline secret (an SSH private key spans multiple
lines), **do not** pipe it in directly:

```sh
# Unreliable — has been observed to silently truncate multiline input
# to just the first line, with exit 0 and no error:
gopass insert -m personal/vps/some-key < ~/.ssh/some_key
```

Base64-encode first instead, and always verify by reading it back and
decoding it in a real terminal before trusting it as a real backup:

```sh
base64 < ~/.ssh/some_key | gopass insert -f personal/vps/some-key
# verify immediately:
gopass show -o personal/vps/some-key | base64 -d | diff - ~/.ssh/some_key
```

---

## Phase 1 — First login and OS update

```sh
ssh root@<VPS_IP>   # or the cloud-init default user, e.g. ubuntu/admin
apt update && apt full-upgrade -y
# reboot if a kernel update was applied:
[ -f /var/run/reboot-required ] && reboot
```

**Verify**: reconnect after any reboot, then confirm no pending restart
flag remains: `[ -f /var/run/reboot-required ] && echo "still pending"`
should print nothing.

---

## Phase 2 — Non-root sudo user

```sh
adduser <USER>              # set a strong password when prompted
usermod -aG sudo <USER>
```

Decide **now**, deliberately, whether this user gets NOPASSWD sudo
(`echo "<USER> ALL=(ALL) NOPASSWD: ALL" | sudo tee /etc/sudoers.d/<USER>-nopasswd && visudo -c`).
This is a real convenience-vs-friction tradeoff, not a default to copy
without thinking — NOPASSWD sudo means anyone with SSH key access to
this account has unconfirmed root. Fine for a single-admin hobby/small
box where the SSH key is already the real security boundary; worth a
second thought for anything more sensitive.

If the image ships a default cloud-init user (`ubuntu`, `admin`, etc.)
that you won't use, plan to lock it out entirely in Phase 3 rather than
leaving it as a second way in.

**Verify**: `id <USER>` shows the `sudo` group; if NOPASSWD was set,
`sudo -l -U <USER>` shows `NOPASSWD: ALL`.

---

## Phase 3 — SSH key auth + hardening

This is the highest-blast-radius phase in this whole doc. Do not
collapse these steps into one unattended action, and do not disable
password auth until key auth is independently confirmed working from a
**separate** connection.

**3.1 — Add your public key**

```sh
su - <USER>
mkdir -p ~/.ssh && chmod 700 ~/.ssh
echo "<your-public-key-contents>" >> ~/.ssh/authorized_keys
chmod 600 ~/.ssh/authorized_keys
exit
```

**3.2 — Confirm key login works, from a fresh terminal, before changing
anything else**:

```sh
ssh -i ~/.ssh/<key> <USER>@<VPS_IP>
```

Don't proceed to 3.3 until this succeeds and you still have your
original root/cloud-init session open as a fallback.

**3.3 — Harden sshd**

Create `/etc/ssh/sshd_config.d/00-hardening.conf` (see the naming note
below — this is deliberate, not arbitrary):

```
PasswordAuthentication no
PermitRootLogin no
KbdInteractiveAuthentication no
```

```sh
sudo sshd -t                      # syntax check — must be clean
sudo systemctl reload ssh         # reload, not restart — keeps existing sessions alive if something's wrong
```

> **Gotcha — file naming actually matters here.** Ubuntu's
> `/etc/ssh/sshd_config` includes `sshd_config.d/*.conf` as its first
> directive, and sshd applies **first-match-wins per keyword**, in
> lexical filename order, across all included files. Cloud-init drops
> its own config as `50-cloud-init.conf`, which on some images sets
> `PasswordAuthentication yes`. A hand-written file named plain
> `hardening.conf` sorts *after* `50-cloud-init.conf` alphabetically —
> so cloud-init's `yes` silently wins, even though `hardening.conf`
> reads correctly and `grep` shows exactly what you expect. This has
> happened in practice: a box ran for a full day genuinely still
> accepting password SSH auth despite a seemingly-correct hardening
> file, caught only by the protocol-level check below. Naming the file
> `00-hardening.conf` (or any prefix that sorts before `50-`) avoids
> this by construction. If you ever find a losing config, fix it by
> renaming your file to sort first — don't edit the cloud-init-owned
> file directly, since cloud-init can regenerate it on a future run and
> silently reintroduce the bug.

**3.4 — Verify. Do not skip. Do not trust `grep` or `cat` on the config
file — they show what's written, not what's effective.**

Check the *merged* config sshd actually computed:

```sh
sudo sshd -T | grep -i passwordauthentication
sudo sshd -T | grep -i permitrootlogin
```

Then check at the protocol level — what the daemon actually offers a
connecting client, independent of config-parsing reasoning:

```sh
ssh -v -o BatchMode=yes -o PreferredAuthentications=password <USER>@<VPS_IP> exit 2>&1 \
  | grep "Authentications that can continue"
```

This should show only `publickey`. If it still shows `password` in the
list, the override problem above is happening — check `sshd -T` against
each file in `/etc/ssh/sshd_config.d/` to find which one is winning.

Also confirm key login still works and root login is refused, each from
a **fresh** connection:

```sh
ssh -i ~/.ssh/<key> <USER>@<VPS_IP>            # should succeed
ssh root@<VPS_IP>                              # should be refused
```

**3.5 — Lock out any unused default account** (e.g. cloud-init's
`ubuntu` user, if you're not using it):

```sh
sudo passwd -l ubuntu
sudo rm -f /home/ubuntu/.ssh/authorized_keys
```

> **Don't stop at `passwd -l` alone** — it locks *password* login for
> that account, but has no effect on SSH *key* login. If the
> provider's cloud-init put its initial key into
> `/home/ubuntu/.ssh/authorized_keys` (common — it's usually the same
> key you supplied when creating the VPS), that account can still SSH
> in with it even after `passwd -l`, since key auth never reads
> `/etc/shadow` at all. Removing (or emptying) that account's own
> `authorized_keys` file is the step that actually closes it —
> touching `/root/.ssh/authorized_keys` instead does nothing for the
> `ubuntu` account, since accounts don't share that file.

Verify — key auth, not just password auth, must fail:

```sh
ssh -o PreferredAuthentications=publickey -o PubkeyAuthentication=yes ubuntu@<VPS_IP>
```
Should be refused. A plain `ssh ubuntu@<VPS_IP>` alone isn't a strong
enough check here, since with password auth already off globally
(3.3), it would *look* refused either way — this needs to specifically
attempt key auth to prove the removed `authorized_keys` is what's
stopping it.

**3.6 — Back up the key** using the gopass base64 pattern from Phase 0,
or your password manager's file-attachment feature. Verify the backup by
actually restoring it to a scratch path and diffing, not by trusting a
successful save. A backup key that was never verified to round-trip
correctly is not a real backup — this has silently failed in practice
before (see Phase 0's gotcha).

---

## Phase 4 — Firewall + fail2ban + swapfile

Use `scripts/base-hardening.sh` from this repo (pass any extra ports to
open beyond 22, e.g. `./scripts/base-hardening.sh 80 443` for a box that
will serve public HTTP/S), or run the equivalent manually:

```sh
sudo apt install -y ufw fail2ban
sudo ufw default deny incoming
sudo ufw default allow outgoing
sudo ufw allow 22/tcp
# allow 80/443 here too if this box will serve public HTTP(S):
sudo ufw allow 80/tcp
sudo ufw allow 443/tcp
sudo ufw enable
```

> **Note**: some providers' images (Oracle's stock Ubuntu image, for
> one) don't ship `ufw` preinstalled — they use hand-rolled
> `iptables-persistent`/`netfilter-persistent` rules instead, already
> doing default-deny. Installing `ufw` via apt will remove those
> packages and take over the same job automatically — fine, but verify
> connectivity from a **fresh second session** immediately after
> `ufw enable`, before closing your existing session, on any box where
> you're not sure what the starting firewall state was.

fail2ban:

```sh
sudo tee /etc/fail2ban/jail.local >/dev/null <<'EOF'
[sshd]
enabled = true
maxretry = 5
findtime = 600
bantime = 3600
EOF
sudo systemctl enable --now fail2ban
```

> **Gotcha to remember for later phases**: Docker rewrites `iptables`
> rules directly for any container port published with `-p`, and this
> bypasses `ufw` entirely — a `ufw deny` rule does **not** stop a
> Docker-published port from being reachable. The actual control for
> anything Docker publishes is which **host IP** it's bound to
> (`127.0.0.1:PORT:PORT` or a specific interface IP like a Tailscale
> address), not `ufw`. Keep this in mind for every phase from here on
> that involves `docker run -p` or a compose `ports:` block.

Swapfile (2G, `swappiness=10` — worth adding even on boxes with plenty
of RAM, cheap insurance; essential on small/free-tier boxes):

```sh
sudo fallocate -l 2G /swapfile
sudo chmod 600 /swapfile
sudo mkswap /swapfile
sudo swapon /swapfile
echo '/swapfile none swap sw 0 0' | sudo tee -a /etc/fstab
echo 'vm.swappiness=10' | sudo tee -a /etc/sysctl.conf
sudo sysctl -p
```

**Verify**:

```sh
sudo ufw status verbose      # confirms default-deny + allowed ports
sudo systemctl status fail2ban --no-pager
sudo fail2ban-client status sshd
swapon --show                # confirms swap active
```

If you used `scripts/base-hardening.sh`, all three (ufw, fail2ban,
swap) are covered by that one run — no need to also do this section
manually. Running both is harmless (the script detects existing swap
and skips it) but redundant.

---

## Phase 5 — Docker Engine

Use `scripts/docker-install.sh` from this repo — it installs from
Docker's official apt repo (following the method documented at
docs.docker.com, not a third-party curl-pipe-bash script), prints the
downloaded GPG key's fingerprint for you to independently check before
trusting it, and sets log rotation automatically. It's idempotent, so
safe to run even if Docker's already installed (it'll just fix up log
rotation if that's missing).

```sh
./scripts/docker-install.sh
```

> **On the fingerprint check**: as of when this doc was written,
> Docker's own install page doesn't publish a fingerprint on that page
> to diff against directly — the script prints what it downloaded and
> tells you to check it, but you may need to cross-reference via a
> second independent source (Docker's official GitHub org, etc.) rather
> than a single page. Don't skip this step just because it's
> inconvenient — a substituted key here means every `apt install
> docker-ce` afterward trusts whatever the attacker signed.

If running the equivalent manually instead of using the script, don't
forget the log-rotation step — container logs can silently fill the
disk without it:

```sh
sudo tee /etc/docker/daemon.json >/dev/null <<'EOF'
{
  "log-driver": "json-file",
  "log-opts": { "max-size": "10m", "max-file": "3" }
}
EOF
sudo systemctl restart docker
```

Optionally add your user to the `docker` group for convenience (no
sudo password needed for `docker` commands):

```sh
sudo usermod -aG docker <USER>
```

> Be aware this is **not** a real privilege reduction — docker-group
> membership is root-equivalent (you can bind-mount `/` into a
> container and do anything). It's a convenience step, not a security
> boundary. Only add it if `<USER>` already has full sudo anyway.

**Verify**:

```sh
docker run --rm hello-world
sudo systemctl is-enabled docker     # should say "enabled"
cat /etc/docker/daemon.json          # confirm log rotation applied
docker info | grep -A2 "Logging Driver"
```

---

## Phase 6 — Tailscale (optional, recommended if gating admin UIs)

Skip this phase entirely if this box will only ever serve public traffic
with no admin UI to protect.

```sh
curl -fsSL https://tailscale.com/install.sh | sh
sudo tailscale up
```

> This is the curl-pipe-shell pattern this doc otherwise avoids (see the
> Docker phase) — called out explicitly rather than silently used. The
> difference: this is Tailscale's own primary documented install
> method, fetched from `tailscale.com` itself rather than a third
> party — not the same trust profile as an arbitrary blog's install
> script, though still worth being deliberate about. Tailscale's docs
> do also offer a manual apt-repository method for anyone who'd rather
> avoid `curl | sh` entirely (linked from their install docs as
> "Tailscale Packages - stable track") — worth using that instead on
> anything higher-stakes than a hobby box; not detailed here since it
> wasn't independently verified against the primary source at the time
> of writing this doc.

Follow the printed auth URL to add this box to your tailnet.

**Verify**:

```sh
tailscale status              # shows this box + others on the tailnet
tailscale ip -4                # note this — it's <TAILSCALE_IP> for later phases
```

From another device already on the tailnet, confirm you can reach this
box's Tailscale IP and that the **public** IP does *not* expose whatever
you're about to bind to it (verified per-service in later phases, not
here — there's nothing bound yet).

---

## Phase 7 — Portainer (optional)

**Decision criteria — don't install this by default.** Portainer earns
its place when a box runs **multiple** Docker stacks and benefits from
GitOps-style "pull & redeploy" workflows. For a box with a single
purpose (one compose stack, rarely touched), Portainer is just extra RAM
overhead and another Tailscale-gated admin surface to maintain — skip
it.

If it's warranted:

```sh
docker volume create portainer_data
docker run -d \
  -p <TAILSCALE_IP>:9443:9443 \
  --name portainer \
  --restart=always \
  -v /var/run/docker.sock:/var/run/docker.sock \
  -v portainer_data:/data \
  portainer/portainer-ce:lts
```

Binding `-p <TAILSCALE_IP>:9443:9443` (a specific interface IP, not a
bare port) is what actually restricts reachability — see the Docker/ufw
note in Phase 4. Do **not** publish this to `0.0.0.0` or a bare
`-p 9443:9443`.

Note the raw `/var/run/docker.sock` mount here — unlike the
socket-proxy pattern in Phase 8, Portainer legitimately needs full
Docker API access to do its job (managing any container/volume/network
on the box). That's inherent to what Portainer is, not a shortcut being
taken; it means anyone who can reach Portainer's admin UI has
root-equivalent control of the host, which is exactly why it stays
Tailscale-gated rather than public.

The initial admin-setup screen times out quickly. If it does,
`docker restart portainer` resets the timer, and the fresh setup token
is in `docker logs portainer` (use the most recent one logged).

**Verify**:

```sh
# on the VPS:
ss -tln | grep 9443          # should show <TAILSCALE_IP>:9443 only, never 0.0.0.0
```

```sh
# from your Mac/laptop, with Tailscale connected:
curl -k https://<TAILSCALE_IP>:9443     # should get a real response
# then disconnect Tailscale and try the public IP:
curl -k https://<VPS_IP>:9443           # should time out
```
Browsers default to `http://` for a bare `IP:port` — Portainer's 9443 is
HTTPS-only, so typing the address without `https://` produces a
"Client sent an HTTP request to an HTTPS server" error. Not a bug.

If using a Git-based stack pulling from a private repo, use a
fine-grained, single-repo, read-only Personal Access Token (or deploy
key, if the Portainer edition/version supports an SSH key field for
this) — least privilege, scoped to exactly that repo.

---

## Phase 8 — Monitoring (optional)

**Decision criteria**: worth adding once there's something real running
on the box you'd want to know is unhealthy (CPU/RAM/disk, or per-
container status). Skip for a box that's still empty.

Pattern: **hub + agent + socket-proxy**, using
[Beszel](https://beszel.dev) as the reference implementation (any
similar hub/agent tool follows the same shape).

```yaml
services:
  beszel:
    image: henrygd/beszel:latest
    container_name: beszel
    restart: unless-stopped
    ports:
      - "<TAILSCALE_IP>:8090:8090"
    volumes:
      - beszel_data:/beszel_data
      - beszel_socket:/beszel_socket

  beszel-agent:
    image: henrygd/beszel-agent:latest
    container_name: beszel-agent
    restart: unless-stopped
    network_mode: host          # needed for real host network-interface stats
    volumes:
      - beszel_socket:/beszel_socket
    environment:
      LISTEN: /beszel_socket/beszel.sock
      HUB_URL: http://<TAILSCALE_IP>:8090
      TOKEN: <generated-by-hub-add-system-dialog>
      KEY: <generated-by-hub-add-system-dialog>
      DOCKER_HOST: tcp://127.0.0.1:2375   # points the agent at socket-proxy, not the raw socket
    depends_on:
      - socket-proxy

  socket-proxy:
    image: lscr.io/linuxserver/socket-proxy:latest
    container_name: socket-proxy
    restart: unless-stopped
    read_only: true
    tmpfs:
      - /run
    ports:
      - "127.0.0.1:2375:2375"   # host loopback only — see reasoning below
    environment:
      CONTAINERS: 1            # only what's actually needed — leave everything else at default-deny
    volumes:
      - /var/run/docker.sock:/var/run/docker.sock:ro

volumes:
  beszel_data:
  beszel_socket:
```

**Wiring the agent to the proxy — the part it's easy to get wrong**:
`beszel-agent` runs under `network_mode: host`, which means it does **not**
participate in Docker's normal bridge networking or container-name DNS at
all — it shares the host's network namespace directly. That means a
regular Docker Compose network (e.g. a shared user-defined bridge) between
`beszel-agent` and `socket-proxy` **would not work** — they're not on the
same network stack. The only way for the agent to reach the proxy is via a
real port published to the host, over loopback:
`socket-proxy` publishes `127.0.0.1:2375:2375`, and the agent is told
`DOCKER_HOST: tcp://127.0.0.1:2375` explicitly (Beszel's agent mounts
`/var/run/docker.sock` directly by default — this env var is what
redirects it to the proxy instead). Confirmed against the exact
[henrygd/beszel discussion #1818](https://github.com/henrygd/beszel/discussions/1818)
this pattern comes from, not assumed.

Key design choices, and why:

- **Hub and agent talk over a shared Unix-socket volume**, not the
  network, when they're co-located on the same box — avoids opening the
  hub/agent protocol port at all. If `HUB_URL` is needed for anything,
  it must be the literal Tailscale IP, not `localhost` — an IP-scoped
  published port isn't reachable via loopback from a different network
  namespace (e.g. the agent under `network_mode: host` has its own
  view).
- **Docker stats go through `socket-proxy`, never a raw
  `/var/run/docker.sock` mount into the monitoring agent.** A `:ro`
  bind mount of the Docker socket does **not** meaningfully restrict
  it — sockets communicate via `send()`/`recv()`, not the
  `read()`/`write()` syscalls the `:ro` mount flag governs, so a
  container with "read-only" socket access can still issue the full
  Docker API (root-equivalent on the host: create a privileged
  container, mount `/`, done). `socket-proxy` with an explicit
  allow-list (`CONTAINERS=1` only, everything else default-deny) is the
  actual control. This is a maintainer-recommended pattern for Beszel
  specifically, not invented here.
- **Why the hub is on the Tailscale IP but `socket-proxy` is on
  `127.0.0.1`, not the same address** — these look inconsistent but
  aren't: the hub's *web UI* is meant to be reached by you, from other
  devices on the tailnet, so it's bound to the Tailscale IP on purpose.
  `socket-proxy` is the opposite case — nothing should ever reach the
  Docker-API proxy except the agent on this same box, not even other
  Tailscale peers, so `127.0.0.1` (host loopback only) is the *more*
  restrictive and correct choice there, not an oversight.
- **`read_only: true` + a `tmpfs: - /run` mount on socket-proxy**: this
  image's internal haproxy process needs a writable `/run` for its own
  runtime config even with everything else read-only. Without the
  tmpfs mount, the container crash-loops with
  `mkdir: can't create directory '/run/haproxy': Read-only file
  system`. If you hit an unexplained crash-loop on a `read_only: true`
  container, check whether it needs a scratch directory like this
  before assuming the image is broken.
- **Bootstrap order**: agent's `TOKEN`/`KEY` don't exist until the hub
  generates them. Bring up `socket-proxy` + `beszel` (hub) first, use
  the hub's "Add System" dialog to generate credentials (for
  local-socket mode, set Host/IP to the socket path,
  `/beszel_socket/beszel.sock`, not a real address), *then* start
  `beszel-agent` with those values filled in.
- **Bind the hub to the Tailscale IP**, same reasoning and same
  verification pattern as Portainer in Phase 7 — `ss -tln` should show
  it bound only to `<TAILSCALE_IP>`, never `0.0.0.0`, and a public-IP
  curl should time out while a Tailscale-IP curl succeeds.

**Alerting**: the simplest option is push notifications via
[ntfy](https://ntfy.sh) on the public `ntfy.sh` server. ntfy's own docs
are explicit that **the topic name is your password** on the public
server — anyone who knows the topic can read and post to it — so use a
long, random, unguessable topic (readable prefix + random hex suffix),
never a predictable one, and never commit it anywhere. Shoutrrr URL
format most hub tools expect: `ntfy://ntfy.sh/<topic>`.

> **Gotcha that applies to basically every monitoring/alerting tool,
> not just this one**: "the notification channel exists" and "the
> notification channel is attached to this specific check" are
> typically two separate save actions in these UIs, and it's easy for
> the second one to silently not stick. Don't trust the UI alone —
> verify the actual link. For a SQLite-backed tool, e.g.:
> `docker exec <container> sqlite3 /app/data/<db> "SELECT * FROM <join-table>;"`
> and confirm the row actually exists. This has caught a real case
> where both the monitor and the notification existed, looked fully
> configured, and no alert would have fired on a real outage because
> the join table linking them was empty.

**Verify**:

```sh
# on the VPS:
ss -tln | grep 8090      # bound to <TAILSCALE_IP> only
ss -tln | grep 2375      # bound to 127.0.0.1 only — never 0.0.0.0, never the Tailscale IP either
curl http://127.0.0.1:2375/containers/json   # should return real JSON — proves agent-to-proxy wiring works
```

```sh
# from another device:
curl http://<TAILSCALE_IP>:8090              # HTTP 200 from a Tailscale-connected device
curl http://<VPS_IP>:8090                    # should time out
curl http://<TAILSCALE_IP>:2375              # should also time out — 2375 must not be reachable from anywhere but the box itself
```

Check the hub UI shows real, moving **per-container** stats for the
containers you expect — not just host-level CPU/RAM and not just an
"Up" status. If per-container stats are missing/zero while host-level
stats work, that's the signature of the agent not actually reaching
`socket-proxy` (check `docker logs beszel-agent` for a connection
error to `127.0.0.1:2375`). Also send a real test notification to
confirm it actually arrives, not just that the save succeeded.

**Out of scope for this doc**: this pattern monitors the box *from
itself*. If the box goes fully down (power loss, kernel panic, network
outage), whatever's monitoring it goes down too and can never send that
alert. Catching that requires an **external** check from a genuinely
separate box/provider (e.g. a second free-tier VPS running an uptime
poller like Uptime Kuma, checking this box's public URL from outside).
That's a different bootstrap entirely — this doc covers setting up one
box, not a second independent one to watch it.

---

## Phase 9 — Housekeeping

Swapfile is covered in Phase 4 (via `scripts/base-hardening.sh` or the
manual commands there) — nothing further needed here.

**Ghostty terminal support** (only relevant if you SSH from Ghostty —
its terminfo entry isn't in stock Ubuntu, which breaks `clear`/`tput`/
full-screen apps with `TERM environment variable not set`-type errors):

```sh
infocmp -x xterm-ghostty | ssh <USER>@<VPS_IP> -- tic -x -
```

Verify: `infocmp xterm-ghostty` resolves on the VPS, and `clear` in a
fresh session produces a real ANSI clear rather than an error.

---

## Phase 10 — Definition of done

Don't consider the box finished until every one of these has actually
been run and its output checked, not just "steps completed":

- [ ] `sudo sshd -T | grep -i passwordauthentication` → `no`
- [ ] Protocol-level check confirms only `publickey` is offered (Phase
      3.4)
- [ ] Root SSH login refused, from a fresh connection
- [ ] Any unused default cloud-init account has **both** password
      locked *and* its own `authorized_keys` removed — `passwd -l`
      alone does not stop key-based login, verified with an explicit
      `PreferredAuthentications=publickey` attempt (Phase 3.5)
- [ ] `sudo ufw status verbose` shows default-deny + only the intended
      ports
- [ ] `fail2ban-client status sshd` shows the jail active
- [ ] `docker run --rm hello-world` succeeds; log rotation confirmed in
      `daemon.json`
- [ ] Backup SSH key exists somewhere off-box and has been **read back
      and diffed**, not just saved
- [ ] For every service bound to a Tailscale IP (Portainer,
      monitoring hub, etc.): `ss -tln` confirms it's bound to that IP
      specifically, and a public-IP curl from outside times out while a
      Tailscale-IP curl succeeds
- [ ] Monitoring (if installed): `socket-proxy`'s port is confirmed
      bound to `127.0.0.1` only (not the Tailscale IP, not `0.0.0.0`),
      and the hub UI shows real moving per-container stats, not just
      host-level stats
- [ ] Monitoring (if installed): a real test alert was received, and
      the notification-to-check link was verified directly (not just
      assumed from the UI)
- [ ] Swapfile active (`swapon --show`)
