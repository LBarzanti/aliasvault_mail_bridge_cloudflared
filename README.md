# AliasVault email without a public IP (Cloudflare Email Routing + tiny Rust bridge)

Receive email for your [AliasVault](https://docs.aliasvault.com/) aliases when your server has **no public IPv4 address** and you **don't want to rent a VPS** only exposing services through a **Cloudflare Tunnel**.

> **Unofficial community project.** Not affiliated with or endorsed by AliasVault. Use at your own risk and read the privacy trade-offs first.

## Contents

1. [Why this exists](#1-why-this-exists)
2. [How it works](#2-how-it-works)
3. [Prerequisites (you must already have these)](#3-prerequisites-you-must-already-have-these)
4. [Placeholders used in this guide](#4-placeholders-used-in-this-guide)
5. [Setup, step by step](#5-setup-step-by-step)
6. [Testing, bottom-up](#6-testing)
7. [What happens when something fails](#7-what-happens-when-something-fails)
8. [Maintenance](#8-maintenance)
9. [Privacy and trade-offs](#9-privacy-and-trade-offs)
10. [Security notes](#10-security-notes)
11. [Troubleshooting](#11-troubleshooting)
12. [Rollback](#12-rollback)
13. [Repository layout, status, license](#13-repository-layout-status-license)

---

## 1. Why this exists

AliasVault's built-in email server expects a **public IPv4 address with ports 25 and 587 forwarded to it**, plus an `A` record and an `MX` record pointing at that address ([AliasVault self-hosting docs](https://docs.aliasvault.com/installation/)).

That does not work if:

- you have no public IPv4 (CGNAT, some home or mobile connections), so an MX record has nowhere to point; and
- you publish your services through a Cloudflare Tunnel. A tunnel (or a proxied hostname) only carries HTTP/HTTPS, so inbound SMTP on port 25 cannot go through it.

This project works around that by letting **Cloudflare receive the mail for you** (Cloudflare Email Routing) and hand it to your server **over HTTPS, through the tunnel you already have**. A tiny bridge on your server then delivers it to AliasVault's own SMTP port, as if it came from a normal sender.

Receive only: this does not send mail, so you do **not** need SPF, DKIM or reverse DNS for a public mail server.

## 2. How it works

```
Sender ──SMTP──▶ Cloudflare Email Routing (MX records managed by Cloudflare)
                        │ catch-all rule
                        ▼
                  Email Worker (Cloudflare edge)
                        │ HTTPS POST: raw message + shared secret
                        ▼
              inbound.example.com  (public hostname of your existing tunnel)
                        │ cloudflared (outbound connection from your server)
                        ▼
              mail-bridge (Rust, systemd, 127.0.0.1:8087)
                        │ plain SMTP, loopback only
                        ▼
              127.0.0.1:2525 ──▶ port 25 of the AliasVault container

If the bridge or AliasVault is temporarily unreachable:
Worker ──▶ KV (raw message) + Queues (key + envelope) ──▶ delayed retries ──▶ same endpoint
```

Per-message flow:

1. A sender delivers mail for `anything@example.com` to Cloudflare (the MX records point there).
2. Email Routing's catch-all rule passes it to the Worker.
3. The Worker POSTs the raw message to `https://inbound.example.com/`, with the SMTP envelope sender/recipient and a shared secret in HTTP headers.
4. The tunnel carries the request to the bridge on your server.
5. The bridge checks the secret **before** allocating memory for the body, validates the addresses, and opens a real SMTP session to AliasVault on `127.0.0.1:2525`, using the original envelope.
6. AliasVault accepts the message (alias exists) or rejects it with a `5xx` (alias unknown, domain not configured, message too large).
7. The bridge answers HTTP `200` (delivered), `422` (permanent rejection) or `502` (temporary failure).
8. On `422` the Worker rejects the message immediately, so the sender gets a normal bounce. On temporary failures the Worker stores the raw message in KV and enqueues a retry in Queues (the sender gets no bounce).

Retry schedule: 3 min, 10 min, 30 min, 1 h, 2 h, 8 h (about 12 hours in total), then a dead-letter queue. The first delay is not shorter because KV is eventually consistent: a freshly written key can be invisible elsewhere for about a minute.

No router ports are opened. Your server only makes outbound connections, exactly like your other tunnels.

## 3. Prerequisites (you must already have these)

**This project does not install or configure any of the following.** Set them up first by following their own documentation, and make sure each one works before you continue.

### 3.1 On the server that runs AliasVault

| Requirement                                                          | Notes                                                                                                                                                                                                                                                                                                       | Documentation                                                                                                                                             |
| -------------------------------------------------------------------- | ----------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- | --------------------------------------------------------------------------------------------------------------------------------------------------------- |
| A Domain                                                             | there are plentry of services (including Cloudflare itself) that offer low-cost domains that can be freely transferred.                                                                                                                                                                                     | [Cloudflare](https://www.cloudflare.com/domains/) · [Ionos](https://www.ionos.com/domains/domain-names) · [Namecheap](https://www.namecheap.com/domains/) |
| **A Linux host** with admin rights and systemd                       | —                                                                                                                                                                                                                                                                                                           | —                                                                                                                                                         |
| **Docker Engine + Docker Compose**                                   | AliasVault runs in a container.                                                                                                                                                                                                                                                                             | [Install Docker Engine](https://docs.docker.com/engine/install/) · [Install Compose](https://docs.docker.com/compose/install/)                            |
| **AliasVault, already running and reachable**                        | The steps below were written for the **all-in-one Docker image** (`ghcr.io/aliasvault/aliasvault`) started with Docker Compose. The multi-container `install.sh` setup is **not** covered or tested here: it configures email differently (`./install.sh configure-email`) and publishes ports differently. | [AliasVault self-hosting](https://docs.aliasvault.com/installation/)                                                                                      |
| **`cloudflared`, installed and connected to a working tunnel**       | Native (systemd service) or in Docker, either is fine. You need to be able to add a **public hostname** to this tunnel.                                                                                                                                                                                     | [Cloudflare Tunnel docs](https://developers.cloudflare.com/tunnel/)                                                                                       |
| **Rust toolchain** (`cargo`, Rust 1.58 or newer) to build the bridge | Check with `cargo --version`. Install with `rustup` or your distribution's package (on Debian-based systems `sudo apt install cargo` may give an older version; check it). You can also build on another machine and copy the binary, but it must match the server's CPU architecture.                      | [Install Rust](https://www.rust-lang.org/tools/install)                                                                                                   |
| `openssl`, `wget`, `nc` (netcat)                                     | Used for generating the secret and for the tests. Usually already present.                                                                                                                                                                                                                                  | —                                                                                                                                                         |

### 3.2 On Cloudflare

| Requirement                                     | Notes                                                                                                   | Documentation                                                                                                                                             |
| ----------------------------------------------- | ------------------------------------------------------------------------------------------------------- | --------------------------------------------------------------------------------------------------------------------------------------------------------- |
| **A Cloudflare account**                        |                                                                                                         | [Cloudflare docs](https://developers.cloudflare.com/)                                                                                                     |
| **A domain whose DNS is managed by Cloudflare** | It will be used for the aliases (see the warning below).                                                | [Add a site](https://developers.cloudflare.com/fundamentals/manage-domains/add-site/)                                                                     |
| **Email Routing**                               | Free. Enabling it changes the domain's MX/TXT records.                                                  | [Email Routing](https://developers.cloudflare.com/email-routing/)                                                                                         |
| **Workers, KV and Queues**                      | Used for the Worker and its retries. Check the **current** plan limits yourself, they change over time. | [Workers](https://developers.cloudflare.com/workers/) · [KV](https://developers.cloudflare.com/kv/) · [Queues](https://developers.cloudflare.com/queues/) |

> **Warning about the domain.** Email Routing makes Cloudflare the mail receiver for the domain it is enabled on. This guide enables it on the **main domain** (`example.com`) and uses its catch-all rule. Do this only if you are **not** already receiving mail on that domain with another provider (Gmail, Outlook, …). If you are, use a domain dedicated to aliases instead.

### 3.3 On your own computer (not necessarily on the server)

| Requirement         | Notes                                                                                                                                           | Documentation                                                                                                                                   |
| ------------------- | ----------------------------------------------------------------------------------------------------------------------------------------------- | ----------------------------------------------------------------------------------------------------------------------------------------------- |
| **Node.js and npm** | Needed only to run Wrangler, which deploys the Worker and creates the KV namespace and the queues. Use a Node.js version supported by Wrangler. | [Download Node.js](https://nodejs.org/en/download) · [Install Wrangler](https://developers.cloudflare.com/workers/wrangler/install-and-update/) |
| **`git`**           | To clone this repository.                                                                                                                       | [Install Git](https://git-scm.com/downloads)                                                                                                    |

### 3.4 Before you continue, verify

```bash
docker compose ps                          # AliasVault is running
cargo --version                            # Rust >= 1.58
systemctl status cloudflared               # if cloudflared is native; otherwise check its container
```

Open your AliasVault web address through the tunnel and log in. If that does not work, fix it first: nothing below will help.

## 4. Placeholders used in this guide

Replace them everywhere with your own values.

| Placeholder           | Meaning                                                                                     |
| --------------------- | ------------------------------------------------------------------------------------------- |
| `example.com`         | Your domain, on Cloudflare, used for the aliases.                                           |
| `vault.example.com`   | The hostname for the AliasVault web interface and API.                                      |
| `inbound.example.com` | A **new** hostname on your existing (or new) tunnel that will receive mail from the Worker. |
| `192.168.x.x`         | The LAN IP of your server (only needed if `cloudflared` runs in Docker).                    |
| `<WEBHOOK_SECRET>`    | A random 64-character hex string generated in step 5.3. Never commit or share it.           |

## 5. Setup, step by step

Clone this repository on the server **and** on the computer where you will run Wrangler (or copy the `worker/` folder there):

```bash
git clone <this-repository-url>
cd aliasvault-cloudflare-mail-bridge
```

### 5.1 Back up

This step is only necessary if AliasVault was already in use.                                                On the server, in the directory containing your AliasVault compose file:

```bash
docker compose ps
cp docker-compose.yml docker-compose.yml.bak
sudo tar czf ~/aliasvault-backup-$(date +%F).tar.gz database secrets
```

Keep a copy of the backup off the server if you can. (Adjust the folder names if your volumes are mapped elsewhere.)

### 5.2 Configure AliasVault

Edit **your existing** compose file. Do not replace it with the example: only make these changes (the full example is in [`deploy/docker-compose.example.yml`](deploy/docker-compose.example.yml)).

1. Under `ports:` add the SMTP port, published **on loopback only** and on a high port:

   ```yaml
       ports:
         # ...your existing ports, unchanged...
         - "127.0.0.1:2525:25"
   ```

2. Under `environment:` enable email and declare your domain:

   ```yaml
         SUPPORT_EMAIL: "true"
         PRIVATE_EMAIL_DOMAINS: "example.com"
   ```

   (For several domains, check the AliasVault documentation for the exact list format.)

Apply and check:

```bash
docker compose up -d
docker compose ps
ss -ltnp | grep 2525        # must show 127.0.0.1:2525
```

Port 25 of AliasVault is never published on the LAN or the internet.

### 5.3 Build and install the bridge (on the server)

```bash
cd bridge
cargo build --release
sudo install -m 755 target/release/mail-bridge /usr/local/bin/mail-bridge
cd ..                              # back to the repository root
```

The bridge uses only Rust's standard library, so the build needs no network access for dependencies and very few consumption of resources.

Generate the shared secret and store it where only root can read it:

```bash
echo "WEBHOOK_SECRET=$(openssl rand -hex 32)" | sudo tee /etc/mail-bridge.env
sudo chmod 600 /etc/mail-bridge.env
sudo cat /etc/mail-bridge.env      # copy the value: you need it again in step 5.6
```

Do not paste the secret into chat, issues, repositories or anywhere unprotected.

### 5.4 Run the bridge as a systemd service

Decide which address the bridge listens on, depending on how `cloudflared` runs:

- **`cloudflared` runs natively on the server:** `LISTEN=127.0.0.1:8087` (the default in the unit file).
- **`cloudflared` runs in a Docker container:** `localhost` inside the container is not the server, so bind to the server's LAN IP, e.g. `LISTEN=192.168.1.50:8087`, and point the tunnel at that address in step 5.5.

Install the unit from [`deploy/mail-bridge.service`](deploy/mail-bridge.service) (edit the `LISTEN=` line if needed):

```bash
sudo cp deploy/mail-bridge.service /etc/systemd/system/mail-bridge.service
sudo systemctl daemon-reload
sudo systemctl enable --now mail-bridge
systemctl status mail-bridge
journalctl -u mail-bridge -f
```

You should see `listening on...`.

### 5.5 Add a hostname to your tunnel

Add `inbound.example.com` to the tunnel you already use. Depending on how it is managed:

**A) Tunnel managed from the Cloudflare dashboard** (Zero Trust → Networks → Tunnels → your tunnel → Public Hostname → Add): hostname `inbound.example.com`, service type `HTTP`, URL `localhost:8087` (or `192.168.1.50:8087` if `cloudflared` runs in Docker). Menu names change over time.

**B) Tunnel configured with a local `config.yml`:** add the entry **before** the final catch-all rule:

```yaml
ingress:
  - hostname: inbound.example.com
    service: http://localhost:8087
  # ...your existing rules...
  - service: http_status:404
```

then create the DNS record and restart:

```bash
cloudflared tunnel route dns <tunnel-name-or-id> inbound.example.com
sudo systemctl restart cloudflared
```

See the [Cloudflare Tunnel docs](https://developers.cloudflare.com/tunnel/) for details on either method.

### 5.6 Deploy the Worker (from your computer)

```bash
cd worker
npx wrangler login
npx wrangler kv namespace create aliasvault-mail-retry
npx wrangler queues create aliasvault-mail-retry
npx wrangler queues create aliasvault-mail-retry-dlq
```

`kv namespace create` prints an `id`. Create your configuration from the example and fill it in:

```bash
cp wrangler.toml.example wrangler.toml
```

Edit `wrangler.toml`:

- `INBOUND_URL` → `https://inbound.example.com/`
- `id` under `[[kv_namespaces]]` → the namespace id printed above.

Then deploy, set the secret, and deploy again (the secret is **not** written in `wrangler.toml`):

```bash
npx wrangler deploy
npx wrangler secret put WEBHOOK_SECRET     # paste the value from step 5.3
npx wrangler deploy
```

Do **not** enable the catch-all rule (next step) before this second deploy.

What the retry settings in `wrangler.toml` mean: the main queue has `max_retries = 6`, one message per batch, and a dead-letter queue. KV values expire after 7 days. If you change the delays or retries, keep the total within your plan's queue retention (24 hours on the free plan at the time of writing, verify it) and below the KV expiry.

### 5.7 Enable Email Routing and the catch-all rule

1. Cloudflare dashboard → your domain → **Email** → **Email Routing** (in newer dashboards: Compute → Email Service → Email Routing) → enable it for the domain.
2. Cloudflare proposes DNS records (MX and TXT for SPF/DKIM). **Review them before confirming**: this redirects the domain's incoming SMTP to Cloudflare. If you use the domain for mail elsewhere, stop here and see the warning in 3.2.
3. In **Routing rules**, edit the **Catch-all** rule: action **Send to a Worker**, destination `aliasvault-mail`, status **active**.

Do not create a literal rule for a single address: the catch-all must cover every `@example.com` address. If the dashboard differs from these names, follow the [Email Routing docs](https://developers.cloudflare.com/email-routing/).

### 5.8 Create an alias in AliasVault

1. Open `https://vault.example.com` and log in.
2. In the email settings, set `example.com` as the default email domain, or choose it when creating an alias.
3. Create an alias such as `test@example.com`.

## 6. Testing

An automatic script runs the tests in bottom-up order, starting with AliasVault's SMTP endpoint and then checking the bridge locally and through the public tunnel. It can be used with the reference setup of this guide or adapted to a different setup through interactive prompts or environment variables.

### 6.1 Run the tests

On the server, from the repository root (the alias from step 5.8 must already exist in AliasVault):

```bash
chmod +x scripts/test-setup.sh
sudo ./scripts/test-setup.sh
```

The script interactively asks for each configuration variable that is not already present in the environment. Enter the appropriate value when prompted. Variables already supplied through the environment are used without asking again.

The following configuration variables are requested:

- `DOMAIN`: your alias domain.

- `TEST_ALIAS`: the local part of an existing AliasVault alias.

- `PUBLIC_URL`: the public URL of the bridge through the tunnel. Leave empty to skip the public-endpoint test.

- `SMTP_ADDR`: AliasVault's SMTP address and port as published on the host (probably 127.0.0.1:2525).

- `BRIDGE_URL`: the local URL of the bridge.

- `SERVICE`: the systemd service name. Leave empty if the bridge is not managed by systemd.

- `CONTAINER`: the AliasVault container name. Leave empty to skip the container check.

**Webhook secret:** The script automatically looks for `WEBHOOK_SECRET` in `/etc/mail-bridge.env`. If the file is missing, unreadable, or does not contain the secret, it asks for the path to an alternative secret file. The secret is always read from a file, not from an environment variable.

The two optional-test timeouts have built-in defaults and are not requested:

- `WAIT_FULL_PATH`: 180 seconds (3 minutes).

- `WAIT_RETRY`: 720 seconds (12 minutes).

These timeout values can be overridden through environment variables.

`sudo` is needed to read the secret file, use `journalctl` and stop/start the service. When passing environment variables, put them after `sudo`, as in `sudo VAR=value ./scripts/test-setup.sh`.

The script prints `[ OK ]`, `[FAIL]` or `[SKIP]` for each check, with a hint when something fails, and exits with a non-zero status if any check failed.

| #   | What it checks                                                                                                                          | Expected                                        |
| --- | --------------------------------------------------------------------------------------------------------------------------------------- | ----------------------------------------------- |
| 1   | The `mail-bridge` service and the AliasVault container are running (when their checks are enabled); AliasVault answers on its SMTP port | Service and container active; SMTP banner `220` |
| 2   | The bridge on its local address: message with the right secret, then with a wrong one                                                   | `200`, then `401`                               |
| 3   | Same two checks through the public tunnel hostname (skipped if `PUBLIC_URL` is empty)                                                   | `200`, then `401`                               |
| 4   | A message to an alias that does not exist                                                                                               | `422` (permanent rejection, no retry)           |

Tests 2 and 3 deliver **real messages** to the alias (subject `bridge-test local/public <id>`), so check in the AliasVault app that they arrived. An HTTP `200` already proves that AliasVault accepted them over SMTP.

Two more checks need a real email from outside, so they are optional and interactive:

```bash
sudo ./scripts/test-setup.sh --full-pathsudo ./scripts/test-setup.sh --retry
```

The script asks for any configuration variables that have not been supplied through the environment before running the tests.

- `--full-path` checks the whole chain (Cloudflare → Worker → tunnel → bridge → AliasVault). Send an email to your alias from **another mail account** while it waits (up to 3 minutes by default). It watches the bridge's log for the delivery, so it needs `SERVICE` (systemd) to be set and `journalctl` to be available.

- `--retry` checks the retry mechanism. It stops the bridge, asks you to send an email (the sender must **not** get a bounce), restarts the bridge and waits for the Worker's first retry (about 3 minutes, plus margin; up to 12 minutes by default). It requires `SERVICE` (systemd), `systemctl` and `journalctl`. If you press Ctrl+C, the script restarts the bridge before exiting. Afterwards check in the AliasVault app that the message arrived, and in Cloudflare that the KV key under `incoming/` has been deleted.

### 6.2 Configuration and environment variables

At startup, the script interactively asks for every configuration variable that is not already set in the environment.

There are two exceptions:

- `SECRET_FILE` defaults to `/etc/mail-bridge.env`. The script checks this file automatically and asks for an alternative path only if it cannot read `WEBHOOK_SECRET` from it.

- The two timeout variables have built-in defaults of `180` and `720` seconds respectively, so they do not need to be entered.

You can either enter configuration values when prompted or provide them in advance as environment variables. Variables explicitly set to an empty string are treated as intentionally empty. This is useful for optional settings such as `PUBLIC_URL`, `SERVICE` and `CONTAINER`.

The reference setup uses the following values. **These are automatic defaults but can be changed**, except for `SECRET_FILE` and the two timeout variables.

| Variable         | Reference setup value                   | Change it when                                                                                                                                                                                                                    |
| ---------------- | --------------------------------------- | --------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `DOMAIN`         | Your actual domain, e.g. `mydomain.org` | **Always.** It is your alias domain, the one in `PRIVATE_EMAIL_DOMAINS` and Email Routing. Required.                                                                                                                              |
| `TEST_ALIAS`     | `test`                                  | Your test alias has another name. It must already exist in AliasVault. Required.                                                                                                                                                  |
| `PUBLIC_URL`     | `https://inbound.mydomain.org/`         | This is the public URL of the bridge through the tunnel. Leave empty to skip test 3.                                                                                                                                              |
| `SMTP_ADDR`      | `127.0.0.1:2525`                        | You published AliasVault's SMTP port 25 on another address or port in the compose file. Required.                                                                                                                                 |
| `BRIDGE_URL`     | `http://127.0.0.1:8087/`                | `LISTEN` in the systemd unit is different. Typical case: `cloudflared` runs in Docker and the bridge listens on the LAN IP, e.g. `http://192.168.1.50:8087/`. Required.                                                           |
| `SECRET_FILE`    | `/etc/mail-bridge.env`                  | The default path containing `WEBHOOK_SECRET`. The script uses this file first. If it is missing, unreadable or does not contain the secret, an alternative path is requested. Set this variable to use a different file directly. |
| `SERVICE`        | `mail-bridge`                           | The systemd unit has another name. Leave empty if the bridge is not run by systemd; the service check, `--full-path` and `--retry` are then skipped.                                                                              |
| `CONTAINER`      | `aliasvault`                            | The container has another name. Leave empty to skip that check.                                                                                                                                                                   |
| `WAIT_FULL_PATH` | `180` seconds                           | Maximum time to wait for delivery in `--full-path` mode. Built-in default: `180`. Override through the environment if needed. Must be a positive integer.                                                                         |
| `WAIT_RETRY`     | `720` seconds                           | Maximum time to wait for delivery in `--retry` mode. Built-in default: `720`. Override through the environment if needed. Must be a positive integer.                                                                             |

The secret file must contain a line in the following format:

```bash
WEBHOOK_SECRET=your-secret-here
```

The script reads the secret from the configured file. It does not use an exported `WEBHOOK_SECRET` environment variable as a fallback.

For example, to run the script without interactive prompts using the reference setup and the default secret file:

```bash
sudo DOMAIN=mydomain.org TEST_ALIAS=test PUBLIC_URL=https://inbound.mydomain.org/ SMTP_ADDR=127.0.0.1:2525 BRIDGE_URL=http://127.0.0.1:8087/ SERVICE=mail-bridge CONTAINER=aliasvault ./scripts/test-setup.sh
```

The script automatically uses `/etc/mail-bridge.env` to obtain the secret and applies the timeout defaults.

To use a different secret file, specify `SECRET_FILE` explicitly:

```bash
sudo DOMAIN=mydomain.org TEST_ALIAS=test PUBLIC_URL=https://inbound.mydomain.org/ SMTP_ADDR=127.0.0.1:2525 BRIDGE_URL=http://127.0.0.1:8087/ SECRET_FILE=/opt/mail-bridge.env SERVICE=mail-bridge CONTAINER=aliasvault ./scripts/test-setup.sh
```

To use a different setup, for example `cloudflared` in Docker, a custom service name and no public test:

```bash
sudo DOMAIN=mydomain.org TEST_ALIAS=test PUBLIC_URL="" SMTP_ADDR=127.0.0.1:2525 BRIDGE_URL=http://192.168.1.50:8087/ SERVICE=my-bridge CONTAINER=aliasvault ./scripts/test-setup.sh
```

In this case, the script still looks for `/etc/mail-bridge.env` first.

If the script is run without an interactive terminal, all configuration variables must be supplied through the environment, and `SECRET_FILE` must point to a readable file containing `WEBHOOK_SECRET`. The script cannot ask for an alternative path without an interactive terminal.

Not covered by the script, because it needs a temporary change in Cloudflare: the **dead-letter queue** test (6.3 below).

### 6.3 Dead-letter queue test (manual, optional)

1. Temporarily set `RETRY_DELAYS` to `[5, 5]` in `worker/src/index.js` and `max_retries = 2` in `wrangler.toml`, then run `npx wrangler deploy`.

2. Stop the bridge (`sudo systemctl stop mail-bridge`), send an email to your alias, and wait a minute or two.

3. The message must show up in the queue `aliasvault-mail-retry-dlq` and in the Worker logs; its KV value stays until it expires.

4. **Restore the production values** (`RETRY_DELAYS = [180, 600, 1800, 3600, 7200, 28800]`, `max_retries = 6`), deploy again and start the bridge: `sudo systemctl start mail-bridge`.

## 7. What happens when something fails

The Worker decides using the bridge's HTTP status:

- `200`: delivered.
- `400`, `405`, `413`, `422`: definitive rejection. On the first attempt the Worker calls `setReject`, so the sender gets a bounce.
- `401`, `403`, `404`, `408`, `429`, `502`, a timeout or a network error: treated as temporary or as a recoverable misconfiguration; the message is kept in KV and retried through Queues. (401/403/404 are deliberately retried: a wrong secret or tunnel mapping during reconfiguration should not lose mail.)

| Situation                                | Effect                                                                                                                 |
| ---------------------------------------- | ---------------------------------------------------------------------------------------------------------------------- |
| Bridge stopped or crashed                | First attempt fails; message saved to KV and queued. `Restart=always` restarts the bridge; retries deliver it.         |
| Tunnel / `cloudflared` down              | Same; no immediate bounce if KV and Queues are available.                                                              |
| Server powered off                       | Same; delivered when the server is reachable again, within the retry window (~12 h).                                   |
| AliasVault stopped or SMTP unreachable   | Bridge answers `502`; queued.                                                                                          |
| AliasVault answers SMTP `4xx`            | Bridge answers `502`; retried.                                                                                         |
| Unknown alias / unconfigured domain      | AliasVault answers `5xx`; bridge answers `422`; rejected immediately, no retry.                                        |
| Message over 25 MiB                      | Rejected by Email Routing before the Worker.                                                                           |
| Message over about 14 MiB                | Rejected by the Worker (AliasVault's message store limit).                                                             |
| KV or Queues unavailable while queueing  | Worker logs the error and rejects the message; without another storage system, it cannot be kept.                      |
| KV value not yet visible to the consumer | The consumer retries instead of discarding it (eventual consistency).                                                  |
| KV free space exhausted                  | New writes fail and the Worker rejects; after a very long outage some mail may not be queueable.                       |
| All retries failed                       | Message goes to `aliasvault-mail-retry-dlq`; the KV value stays until it expires (7 days). No bounce is sent any more. |

Limits of the retry mechanism:

- Delivery is **at-least-once**: if the consumer delivers to AliasVault and is interrupted before acknowledging, a retry can deliver a second copy.
- A permanent rejection during a retry (e.g. the alias was deleted meanwhile) deletes the KV value and logs the error, but cannot produce an SMTP bounce: the original SMTP transaction already finished.
- Check the free-plan KV and Queues limits (daily writes/reads, storage, retention) on Cloudflare's pages: they are fine for personal use but not for high volumes.

## 8. Maintenance

**Logs**

```bash
journalctl -u mail-bridge -f          # the bridge
docker compose logs -f aliasvault     # AliasVault container
ls logs/                              # AliasVault log files (./logs)
```

For retries also check, in the Cloudflare dashboard, the logs of the Worker `aliasvault-mail`, the queue `aliasvault-mail-retry` and the DLQ `aliasvault-mail-retry-dlq`. KV keys prefixed `incoming/` are messages not yet delivered (or waiting to expire after the DLQ).

**Updating AliasVault**

```bash
docker compose pull
docker compose up -d
```

Then repeat test 6.4.

**Updating the bridge**

```bash
cd bridge && cargo build --release
sudo install -m 755 target/release/mail-bridge /usr/local/bin/mail-bridge
sudo systemctl restart mail-bridge
```

**Updating the Worker:** after any change to `worker/src/index.js`, `wrangler.toml` or `INBOUND_URL`, run `npx wrangler deploy`.

**Rotating the secret:** update `/etc/mail-bridge.env`, `sudo systemctl restart mail-bridge`, run `npx wrangler secret put WEBHOOK_SECRET` and deploy again. Avoid rotating while messages are queued, or wait for retries to finish.

**Other notes**

- Do not rename the Worker without updating the catch-all rule: Cloudflare links the rule to the Worker name.
- Periodically check the DLQ: a message there means all retries failed. After restoring service, recover remaining `incoming/` KV keys manually or let them expire.
- Do not set `KV_TTL_SECONDS` below the total retry window.

## 9. Privacy and trade-offs

- **Cloudflare sees your mail.** Messages transit Cloudflare Email Routing and a Worker before reaching your server. AliasVault's end-to-end encrypted vault is unaffected, but mail in transit is handled by Cloudflare.
- **Retries store raw messages in Cloudflare KV** for up to 7 days. Values are deleted after delivery or definitive rejection; otherwise they expire.
- **At-least-once delivery.** In rare failure windows a message can arrive twice.
- **No bounce after queueing.** Once a message is in the retry queue, a later permanent failure cannot be reported to the sender.
- **The domain's MX belongs to Cloudflare Email Routing.** You cannot run another mail provider on the same domain.
- **Inbound only.**
- **No queue if KV/Queues are down:** the message is rejected.

## 10. Security notes

- The bridge's public endpoint is protected by the shared secret only; without it, it answers `401` and the bridge discards the body without keeping it in memory, within a size limit. It accepts only `POST`.
- **Add a Cloudflare rate-limit or WAF rule** for the `inbound` hostname (for example blocking requests without the `x-webhook-secret` header, or Cloudflare Access with a service token, in which case the Worker must send the token headers). The bridge spawns a thread per connection before authenticating, so a rate limit is recommended.
- Valid requests can allocate up to 26 MiB each in the bridge. With the secret protected, the risk is low.
- Keep `/etc/mail-bridge.env` at mode `600`; never commit it; never put the secret in `wrangler.toml` (use `wrangler secret put`).
- AliasVault's SMTP port stays on loopback and is never exposed to the LAN or the internet.
- The systemd unit runs the bridge as a dynamic unprivileged user with a read-only filesystem and `NoNewPrivileges`.
- Found a problem? Please open an issue (or contact the maintainer privately for anything security-sensitive).

## 11. Troubleshooting

| Symptom                                        | Likely causes and checks                                                                                                                                                                             |
| ---------------------------------------------- | ---------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| Sender gets an immediate delivery error        | Check the Worker logs and `journalctl -u mail-bridge`. `422` means a permanent rejection; a KV/Queues error means the message could not be queued.                                                   |
| No log and no mail                             | Catch-all not active or not assigned to `aliasvault-mail`; MX records missing; Email Routing not enabled.                                                                                            |
| `401` on the public test                       | Secret differs between the Worker and `/etc/mail-bridge.env`. Re-set it and deploy again.                                                                                                            |
| `502` from the bridge                          | AliasVault not answering on `127.0.0.1:2525`, a timeout, or SMTP `4xx`. The message should be in KV/Queues; check the consumer.                                                                      |
| "KV value not visible" in the consumer         | Eventual consistency; it retries by itself. If it persists beyond the retries, check that the KV write succeeded and the namespace is not full.                                                      |
| `422` from the bridge                          | AliasVault rejected it permanently: unknown alias, domain not configured, or message too large. No retry expected.                                                                                   |
| Message stuck in the queue                     | Bridge or tunnel still unreachable, or the consumer is not configured. Check the Worker logs and `max_concurrency`.                                                                                  |
| Message in the DLQ                             | All retries failed. Restore the service, recover the KV value and consider delivering manually; otherwise let it expire.                                                                             |
| `consegnata` in the log but nothing in the app | Check AliasVault's logs in `./logs`: it may have discarded the message. Verify `SUPPORT_EMAIL: "true"` and that `PRIVATE_EMAIL_DOMAINS` contains `example.com`.                                      |
| The tunnel can't reach the bridge              | `cloudflared` in Docker with `LISTEN=127.0.0.1`: bind to the LAN IP instead. Check that the tunnel hostname points to the right port.                                                                |
| The bridge won't start                         | `journalctl -u mail-bridge -e`: `WEBHOOK_SECRET mancante` ("missing") means a problem with `/etc/mail-bridge.env`; `bind fallito` ("bind failed") means the port is taken or the address is invalid. |
| The domain's regular mail stopped working      | The MX/TXT records added by Email Routing replaced your previous mail provider (see the warning in 3.2). Restore the previous records.                                                               |

## 12. Rollback

1. Cloudflare → Email Routing: disable the catch-all rule and, if you no longer use it, disable Email Routing for the domain.

2. Cloudflare → DNS: delete only the MX/TXT records added by Email Routing (including SPF/DKIM) and restore any previous records.

3. Cloudflare → Queues: empty or delete `aliasvault-mail-retry` and `aliasvault-mail-retry-dlq` after checking they hold no mail you need.

4. Cloudflare → KV: delete the namespace `aliasvault-mail-retry` after checking it holds no `incoming/` keys you need (or let the values expire).

5. Delete the Worker `aliasvault-mail`, and remove the `inbound.example.com` hostname (and its DNS record) from the tunnel.

6. On the server:

   ```bash
   sudo systemctl disable --now mail-bridge
   sudo rm /etc/systemd/system/mail-bridge.service /etc/mail-bridge.env /usr/local/bin/mail-bridge
   sudo systemctl daemon-reload
   ```

7. Restore the compose file: `cp docker-compose.yml.bak docker-compose.yml && docker compose up -d`.

## 13. Repository layout, status, license

| Path               | What it is                                                                                                                                                                                                            |
| ------------------ | --------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `bridge/`          | Rust HTTP→SMTP bridge. Standard library only. Checks a shared secret, validates the envelope, delivers to AliasVault's SMTP port. Maps SMTP `5xx` to HTTP `422` (permanent) and everything else to `502` (temporary). |
| `worker/`          | Cloudflare Email Worker with KV + Queues retries and a dead-letter queue.                                                                                                                                             |
| `deploy/`          | Example systemd unit and compose snippet.                                                                                                                                                                             |
| `docs/GUIDE.it.md` | Italian version of this guide.                                                                                                                                                                                        |

**Status.** Author-tested end to end. Versions used: AliasVault _0.31.3_, Rust ≥ _1.85.1_,            Wrangler _4.164.0_, host OS _raspberrypi OS_. The retry, KV and dead-letter paths were exercised with the bridge stopped. Not tested: the multi-container `install.sh` setup, Email Routing on subdomains, other architectures than the one listed.

**Contributing.** Issues and pull requests are welcome. Please keep the bridge dependency-free.

**License.** [MIT](LICENSE)
