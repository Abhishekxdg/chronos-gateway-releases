# Chronos Gateway

Chronos Gateway lets AI agents change data in a Postgres database you already run, without giving them access to
that database. Each change an agent makes is checked against your rules and against the live data before it is
written. A change your rules don't allow waits for a person to approve it.

This repository is the self-hosted release: the installer, the Linux binaries and the Docker image. You run
everything on your own machines. There is no account to make, and the gateway sends nothing outside your network
unless you set up webhooks or link it to Chronos Cloud (both optional).

| | |
|---|---|
| Current release | **0.1.1** ([release notes](https://github.com/Abhishekxdg/chronos-gateway-releases/releases)) |
| Engine it bundles | Chronos **0.4.2** ([release](https://github.com/Abhishekxdg/Chronos-DB/releases/tag/v0.4.2)) |
| Status | Early (0.1). Try it on a staging copy of your database first. |
| Upgrading from 0.1.0 | Do it now: 0.1.1 fixes a security bug in tenant scoping ([Security model](#security-model)). |

## Contents

- [How it works](#how-it-works)
- [Requirements](#requirements)
- [Install](#install): installer, Docker, Docker Compose
- [Your first key](#your-first-key)
- [Connect your Postgres](#connect-your-postgres)
- [Run an agent](#run-an-agent)
- [Approve a held change](#approve-a-held-change)
- [Use it from your code](#use-it-from-your-code)
- [API at a glance](#api-at-a-glance)
- [Configuration](#configuration)
- [Security model](#security-model)
- [Running it in production](#running-it-in-production)
- [Upgrading](#upgrading)
- [Uninstalling](#uninstalling)
- [Troubleshooting](#troubleshooting)
- [License](#license)

## How it works

A few words first:

| Term | Meaning |
|---|---|
| Engine | `chronos`, the Chronos database engine. The gateway starts it and keeps it running. It holds a copy of the tables you choose, and it alone decides what may be written back to Postgres. |
| Tenant | The customer a row belongs to, named by a column such as `org_id`. |
| Run | One agent task for one tenant. It has its own token and ends after a set time (1 hour by default). |
| World | A run's private copy of the data, holding only its tenant's rows. The agent reads and writes here, never in Postgres. |
| Propose | Ask for a run's changes to be written to Postgres. |
| Merge policy | The rules a proposed change must keep to be written without a person. By default: no deletes, at most 500 rows (more in [Configuration](#configuration)). |
| Held | A proposed change that broke a rule. It waits for a person to approve or reject it. |

What happens, step by step:

1. Your backend starts a run for one tenant (`POST /v1/runs`) and gets a run token.
2. The agent sends SQL, or MCP tool calls, to the gateway with that run token. They run in the run's world. The
   agent sees and changes only its tenant's rows, and never gets a Postgres password.
3. Your backend, or the agent, proposes the run.
4. The engine checks the change against the merge policy.
   - **Within the rules:** it is written to Postgres in one transaction. Each row is locked and compared with
     Postgres first. If any of them changed since the agent read it, nothing is written (a conflict).
   - **A rule broken:** the change is held. A person approves it (written, with the same checks) or rejects it
     (dropped). The person can be on your team, using the API, or your own end user, in an approval widget on your
     site.
5. Webhooks tell your backend what happened.

```
 your app ─────────────── reads and writes, as today ──────────────────> Postgres
                                                                            ^
 your backend ── start a run for tenant 42 ──> gateway ──> engine           │ written only on a merge,
 the agent ───── SQL / MCP, run token ───────> gateway ──> its world        │ each row checked
                                                            (tenant 42 only) │
 your backend ── propose ──> rules kept ─────────────────────────> merged ──┘
                             a rule broken ──> held ──> approved ──> merged
                                                    └─> rejected ──> dropped
```

The gateway is two programs:

- `chronos-gateway`: the HTTP API, tokens, runs, approvals and webhooks. It keeps its own state in SQLite.
- `chronos`: the engine. The gateway runs it on `127.0.0.1` (loopback), starts it again if it stops, and stops it
  cleanly on shutdown.

## Requirements

| | |
|---|---|
| Machine | Linux on x86-64 or arm64 for the installer. The x86-64 build needs an x86-64-v2 CPU (POPCNT, SSE4.2): nearly any server CPU from the last decade. Anything that runs Docker for the image (`linux/amd64`, `linux/arm64`). There is no macOS build: use Docker there. |
| Installer | `curl`, `tar`, and `sha256sum` or `shasum`. For `--service`: root, systemd and `useradd`. |
| Postgres | 12 or newer (16, 17 and 18 are tested). The gateway's host must reach it. |
| Tables | Each table you attach needs a primary key. Views, partitioned tables, tables with row-level security, tables with generated columns, and tables in an inheritance tree are refused (the connection check lists which, and why). |
| Database admin | Once, someone who can create a role and grant rights on the tables, to make the gateway's own least-privilege role. |
| Disk | Room for a copy of the tables you attach, in the gateway's data folder. |

## Install

Pick one of three ways. Each gives you the same two programs and the same API on port 7400.

### 1. The installer (Linux)

**As a service** (recommended on a server). This installs the binaries in `/usr/local`, makes a system user
`chronos-gateway`, keeps data in `/var/lib/chronos-gateway` and settings in `/etc/chronos-gateway/gateway.env`,
starts the service, and prints a first key for your backend:

```bash
curl -fsSL https://github.com/Abhishekxdg/chronos-gateway-releases/releases/latest/download/install.sh | sudo sh -s -- --service
```

**Just the binaries, for your own user.** This puts `chronos-gateway` in `~/.local/bin` and the engine in
`~/.local/lib/chronos-gateway/`. You start it yourself:

```bash
curl -fsSL https://github.com/Abhishekxdg/chronos-gateway-releases/releases/latest/download/install.sh | sh
```

What the installer does, in order:

1. Downloads the gateway and its engine for your CPU.
2. Checks each download against the `SHA256SUMS` file of its release. On a mismatch it stops and installs nothing.
3. Runs both binaries once (`--version`), so a build that can't run on this machine is never put in place.
4. Moves them into place. With `--service`, writes the systemd unit and settings, starts the service, and waits
   until it answers.

To read the script before you run it:

```bash
curl -fsSLO https://github.com/Abhishekxdg/chronos-gateway-releases/releases/latest/download/install.sh
less install.sh
sudo sh install.sh --service
```

To install one exact release, use that release's own installer. It also names the engine that release was tested
with:

```bash
curl -fsSL https://github.com/Abhishekxdg/chronos-gateway-releases/releases/download/v0.1.1/install.sh | sudo sh -s -- --service
```

Installer options:

| Option or variable | Effect |
|---|---|
| `--service` | Install as a systemd service (Linux, root). Without it: only the binaries. |
| `--uninstall` | Remove the service and the binaries. Keeps the data and the settings. |
| `CHRONOS_GATEWAY_PREFIX` | Where the binaries go. Default `/usr/local` as root, else `~/.local`. |
| `CHRONOS_GATEWAY_VERSION` | A release tag such as `v0.1.1`. Default: the release the script came from. |
| `CHRONOS_GATEWAY_BASE_URL`, `CHRONOS_ENGINE_BASE_URL` | Download from a mirror instead of GitHub. |

`sudo` drops environment variables, so pass them through `env`:
`curl -fsSL <installer URL> | sudo env CHRONOS_GATEWAY_PREFIX=/opt/chronos sh -s -- --service`.

### 2. Docker

The image is `ghcr.io/abhishekxdg/chronos-gateway`. Tags: `0.1.1`, `0.1.0` and `latest`, each for `linux/amd64`
and `linux/arm64`. It holds both programs on a distroless base (no shell), runs as user 65532, and keeps its data in
`/data`.

```bash
docker run -d --name chronos-gateway --restart unless-stopped \
  -p 127.0.0.1:7400:7400 \
  -e GATEWAY_PUBLIC_URL=http://localhost:7400 \
  -v chronos-gateway:/data \
  ghcr.io/abhishekxdg/chronos-gateway:0.1.1
```

- `-p 127.0.0.1:7400:7400` publishes the API on this machine only. Put TLS in front before anything else calls it.
- `GATEWAY_PUBLIC_URL` is the address the gateway writes into the links it hands out. Inside the container it
  listens on `0.0.0.0:7400`, so without this setting those links would say `http://0.0.0.0:7400`.
- `-v chronos-gateway:/data` keeps the data in a named volume. If you mount a host folder instead, make it owned by
  uid 65532.

### 3. Docker Compose

This repository's [`compose.yaml`](compose.yaml) runs the same image with a read-only root filesystem, no Linux
capabilities, and the port on this machine only.

```bash
mkdir chronos-gateway && cd chronos-gateway
curl -fsSLO https://raw.githubusercontent.com/Abhishekxdg/chronos-gateway-releases/main/compose.yaml
echo 'GATEWAY_VERSION=0.1.1' > .env
docker compose up -d
```

Compose reads settings from `.env` in the same folder: `GATEWAY_VERSION` (default `latest`), `GATEWAY_PUBLIC_URL`
(default `http://localhost:7400`), `GATEWAY_ALLOWED_ORIGINS`, `GATEWAY_TABLES` and `GATEWAY_TENANT_COLUMN`. The file
also has commented lines for passing the Postgres URL as a secret file (see
[Connect at start](#connect-at-start-instead)).

## Your first key

Your backend calls the gateway with a **developer key** (it starts with `cgk_`). A key is shown once, when it is
made. The gateway keeps only its hash.

| Install | How to get a key |
|---|---|
| Installer, `--service` | Printed at the end of the install. Another one: `sudo -u chronos-gateway env GATEWAY_DATA=/var/lib/chronos-gateway /usr/local/bin/chronos-gateway keys create backend-2` |
| Installer, binaries only | See below. |
| Docker | `docker exec chronos-gateway chronos-gateway keys create backend` |
| Docker Compose | `docker compose exec gateway chronos-gateway keys create backend` |

With the binaries only, choose a data folder, make a key, then start the gateway. Use the same `GATEWAY_DATA` for
both commands:

```bash
export GATEWAY_DATA=$HOME/chronos-gateway-data
chronos-gateway keys create backend     # prints cgk_...
chronos-gateway                         # listens on 127.0.0.1:7400; Ctrl-C stops it
```

(If the installer said `~/.local/bin` isn't on your `PATH`, run `export PATH="$HOME/.local/bin:$PATH"` first.)

The examples below read the key from a shell variable:

```bash
export KEY=cgk_...      # the key you just made
curl -s localhost:7400/v1/status -H "Authorization: Bearer $KEY"
```

`/v1/status` answers with the engine's state (`"configured": false` until you connect a Postgres), the merge policy,
and run counts. To list or revoke keys: `chronos-gateway keys list` and `chronos-gateway keys revoke <id>`, with the
same data folder (and user) as above.

## Connect your Postgres

Connecting takes three steps: look at the database, make a role for the gateway, then attach the tables agents may
work on. The examples use a table `leads` whose tenant column is `org_id`. Use your own names.

### Step 1: look first (nothing is written)

```bash
curl -s localhost:7400/v1/connect/check -H "Authorization: Bearer $KEY" -H 'Content-Type: application/json' \
  -d '{"url": "postgres://admin:ADMIN_PASSWORD@db.internal:5432/app"}'
```

The gateway connects with that URL, reads Postgres's catalog, and forgets the URL. The answer lists:

- each table in the schema (`public` unless you send `"schema": "..."`), its estimated rows, its primary key, whether
  it can be attached, and if not, why (`refused`);
- `tenant_candidates`: columns that look like a tenant column (`tenant_id`, `org_id`, `account_id`, ...);
- `role_sql`: the statements that make a least-privilege role for the gateway;
- `warnings`, for example when the URL logs in as a superuser or points at a read replica (merges must write to the
  primary).

This check takes `sslmode` `disable`, `prefer` or `require` only, and whenever it uses TLS it trusts only the public
web certificate authorities. If your server's certificate comes from a private CA, the check can't connect: skip it
and write the role from the template in step 2.

### Step 2: make the gateway's role

Run `role_sql` from step 1 as a database admin (for example in `psql`). Choose a long random password. For the two
tables `leads` and `accounts` in `public`, it reads:

```sql
create role chronos_gateway login password '<a long random password>';
grant usage on schema "public" to chronos_gateway;
grant select, insert, update, delete on "public"."leads", "public"."accounts" to chronos_gateway;
grant usage on all sequences in schema "public" to chronos_gateway;
create schema if not exists chronos;
create table if not exists chronos.merges (id text primary key, at timestamptz not null default now());
grant usage on schema chronos to chronos_gateway;
grant select, insert on chronos.merges to chronos_gateway;
```

That is all the role may do: read and write the attached tables, use their sequences, and record each merge in its
own table `chronos.merges`. It is not an owner and not a superuser.

On Postgres 12 or 13, run `set password_encryption = 'scram-sha-256';` in the same session before `create role`.
The engine refuses to send a password as MD5 or in the clear unless the connection is `sslmode=verify-full`.

### Step 3: attach the tables

```bash
curl -s localhost:7400/v1/connect -H "Authorization: Bearer $KEY" -H 'Content-Type: application/json' \
  -d '{"url": "postgres://chronos_gateway:ROLE_PASSWORD@db.internal:5432/app?sslmode=verify-full",
       "tables": ["leads", "accounts"], "tenant_column": "org_id"}'
```

| Field | Meaning |
|---|---|
| `url` | The new role's URL. The engine accepts `sslmode` `disable`, `prefer`, `require`, `verify-ca` and `verify-full`, and `sslrootcert=<file.pem>` for a private CA (a path the gateway's user can read). Without `sslrootcert`, `verify-full` uses the system's CA bundle. |
| `tables` | The tables agents may work on. Only these are copied. |
| `tenant_column` | The column that names each row's tenant. Recorded, so a run can then give just the value (`"tenant": 42`). |
| `yes` | `true` to attach more than 1,000,000 rows. |

The gateway saves the URL in its data folder (`source.url`, readable by its user only), the engine copies the tables,
and the gateway starts the engine and sets up the merge policy. The answer is `{"ok": true, ...}` with the engine's
report.

One data folder holds one Postgres connection. A second `POST /v1/connect` answers `409 attached`. To attach other
tables later, start a gateway with a new data folder.

### Connect at start instead

To keep the Postgres URL out of the API entirely, put it in a file and let the gateway attach at its first start.

With the service:

```bash
sudo install -m 640 -o root -g chronos-gateway /dev/null /etc/chronos-gateway/postgres-url
printf '%s' 'postgres://chronos_gateway:ROLE_PASSWORD@db.internal:5432/app?sslmode=verify-full' \
  | sudo tee /etc/chronos-gateway/postgres-url >/dev/null
sudoedit /etc/chronos-gateway/gateway.env    # uncomment and set the three lines below
sudo systemctl restart chronos-gateway
```

```bash
GATEWAY_SOURCE_FILE=/etc/chronos-gateway/postgres-url
GATEWAY_TABLES=leads,accounts
GATEWAY_TENANT_COLUMN=org_id
```

With Compose: write the URL to `postgres-url.txt` next to `compose.yaml`, then `chmod 600 postgres-url.txt` and
`sudo chown 65532 postgres-url.txt` (the image's user). Uncomment the `GATEWAY_SOURCE_FILE` line and both `secrets`
blocks in `compose.yaml`, add `GATEWAY_TABLES` and `GATEWAY_TENANT_COLUMN` to `.env`, and run `docker compose up -d`.

At its first start the gateway attaches the tables and logs `attached leads, accounts from GATEWAY_SOURCE_FILE`
(or the reason it couldn't). It copies the file into its data folder at every start, so a changed password is
picked up at the next restart. This also works after you connected through the API: set `GATEWAY_SOURCE_FILE` to rotate the password.
While it is set, `POST /v1/connect` takes `tables` only and refuses a `url`.

## Run an agent

A run is what you hand an agent. These calls show the whole path with `curl`. In your product you would use a
[client library](#use-it-from-your-code).

**Start a run** for tenant 42, with your developer key:

```bash
curl -s localhost:7400/v1/runs -H "Authorization: Bearer $KEY" -H 'Content-Type: application/json' \
  -d '{"tenant": {"org_id": 42}, "intent": "remove the duplicate lead", "end_user": "user_7"}'
```

The answer (`201`) has the run's `id`, its `token` (starts with `cgr_`, shown only now), `sql_url`, `mcp_url` and
`expires`. Keep the first two:

```bash
export RUN=run_...          # "id" from the answer
export RUN_TOKEN=cgr_...    # "token" from the answer: this is what the agent gets
```

`tenant` can be `{"org_id": 42}`, `"org_id = 42"`, or just `42` when you set `tenant_column` at connect. Other
fields: `intent` (what the run is for, shown to approvers), `end_user` (who it acts for), `ttl_seconds` (shorter than
the default hour), and `meta` (any JSON you want kept with the run).

**The agent sends SQL** with the run token. It sees only tenant 42's rows:

```bash
curl -s localhost:7400/v1/runs/$RUN/sql -H "Authorization: Bearer $RUN_TOKEN" -H 'Content-Type: application/json' \
  -d '{"sql": "select id, name, owner from leads"}'

curl -s localhost:7400/v1/runs/$RUN/sql -H "Authorization: Bearer $RUN_TOKEN" -H 'Content-Type: application/json' \
  -d '{"sql": "delete from leads where id = 3"}'
```

Nothing has reached Postgres yet. The delete happened only in the run's world. Agents that speak MCP use `mcp_url`
with the same token instead: they get the tools that work inside the world (`describe`, `find`, `sql`, `diff`,
`merge_preview` and others), and none that merge, fork or drop worlds.

**See the changes**, in plain words and as rows:

```bash
curl -s localhost:7400/v1/runs/$RUN/changes -H "Authorization: Bearer $KEY"
```

**Propose** the run:

```bash
curl -s localhost:7400/v1/runs/$RUN/propose -H "Authorization: Bearer $KEY" -H 'Content-Type: application/json' -d '{}'
```

| Answer | Meaning |
|---|---|
| `200 {"status": "merged"}` | Within the rules: written to Postgres. |
| `202 {"status": "held", "reasons": [...]}` | A rule was broken. Here it is the delete: the default rules allow none. Nothing is written yet. |
| `409`, code `conflict` | A row the run changed was changed in Postgres meanwhile. Nothing is written. Propose again with the conflict settled (`by_columns`, `resolve`, `rows`), or have a person approve it settled. |
| `409`, code `expired` | The run's time ran out first. |

## Approve a held change

A held change waits for a person for 3 days by default (`GATEWAY_HOLD_TTL`), then expires. There are two ways to
decide it.

**From your backend or admin tool**, with the developer key:

```bash
curl -s localhost:7400/v1/runs/$RUN/approve -H "Authorization: Bearer $KEY" -H 'Content-Type: application/json' \
  -d '{"by": "ada@example.com"}'
# or: curl -s localhost:7400/v1/runs/$RUN/reject ... -d '{"reason": "still a customer", "by": "ada@example.com"}'
```

Approving writes the change to Postgres, with the same row checks as any merge. Send `"version"` (from
`/changes`) to approve only what you looked at: if the run changed since, the answer is `409 stale`.

**By your end user**, in your product. Ask for a one-time approval link:

```bash
curl -s localhost:7400/v1/runs/$RUN/approvals -H "Authorization: Bearer $KEY" -H 'Content-Type: application/json' \
  -d '{"end_user": "user_7"}'
```

The answer holds a `token` (starts with `cga_`) and a `widget` with a `script` URL and an `html` tag. Put both in
your page:

```html
<script src="https://gateway.example.com/widget.js"></script>
<chronos-approve base="https://gateway.example.com" token="cga_..."></chronos-approve>
```

The widget shows the change in plain words, such as "Remove lead “Hooli”", with Approve and Reject buttons. The
link works once, for 1 day by default (`GATEWAY_APPROVAL_TTL`), and approves only the version it was made for. For
the widget to work, the user's browser must reach the gateway at `GATEWAY_PUBLIC_URL`, and your site's origin must
be in `GATEWAY_ALLOWED_ORIGINS`. The widget fires `chronos-decided` and `chronos-error` events, and takes the CSS
variables `--chronos-accent`, `--chronos-radius` and `--chronos-font`.

**Make changes read well.** Name your tables and columns once, and hide the ones a person shouldn't see
(`null`):

```bash
curl -s -X PUT localhost:7400/v1/labels -H "Authorization: Bearer $KEY" -H 'Content-Type: application/json' \
  -d '{"tables": {"leads": {"name": "lead", "title": "name", "columns": {"owner": "owner", "org_id": null}}}}'
```

**Hear about it with webhooks.** Register a URL once. The answer holds its signing `secret`, shown only then:

```bash
curl -s localhost:7400/v1/webhooks -H "Authorization: Bearer $KEY" -H 'Content-Type: application/json' \
  -d '{"url": "https://app.example.com/hooks/chronos"}'
```

Events: `run.created`, `merge.landed`, `merge.held`, `merge.conflict`, `merge.rejected`, `run.expired`,
`run.discarded`, `run.failed`, and `run.refused` (a tenant went past its hourly run limit). Send `"events": [...]` to
take only some. Each delivery is a JSON `POST` with a `Chronos-Event-Id` header and a
`Chronos-Signature: t=<unix seconds>,v1=<hex HMAC-SHA256 of "<t>.<body>">` header. Check it on the raw body with the
clients' `verify_signature` (Python) or `verifySignature` (TypeScript). A delivery that doesn't get a 2xx answer is
retried after 10 s, 1 min, 5 min, 30 min, 2 h and 6 h, then dropped. `GET /v1/events` lists past events.

## Use it from your code

Client libraries wrap the API: Python ([`chronos-gateway`](https://pypi.org/project/chronos-gateway/)) and
TypeScript ([`@chronosdb/gateway`](https://www.npmjs.com/package/@chronosdb/gateway), Node 18+, Deno, Bun).

```bash
pip install chronos-gateway
```

```python
from chronos_gateway import Gateway

gw = Gateway("http://localhost:7400", key=KEY)  # your developer key

with gw.run(tenant=42, intent="reassign Bo's open leads to Ada", end_user="user_7") as run:
    # MCP clients (Claude Code, the Claude Agent SDK): run.mcp_server()
    # tool-use loops (OpenAI, Anthropic): run.openai_tools() and run.call_tool(name, args)
    my_agent(run)               # your agent
    result = run.propose()

if result.held:                 # a rule wants a person
    link = gw.approval(run.id, end_user="user_7")
    # in your page: <script src="{link.script}"></script> {link.html}
```

A run left without a proposal is discarded when the `with` block ends.

## API at a glance

Every call sends `Authorization: Bearer <token>`. Bodies are JSON. Errors read
`{"error": {"message": "...", "code": "..."}}`.

| Call | Token | What it does |
|---|---|---|
| `GET /health` | none | `{"ok": true}`, for load balancers |
| `GET /v1/status` | key | engine health, what is attached, policy, run counts, webhook backlog |
| `POST /v1/connect/check` | key | look at a Postgres; writes nothing |
| `POST /v1/connect` | key | attach tables and start the engine |
| `POST /v1/setup` | key | apply `GATEWAY_POLICY_RULES` to the merge policy again |
| `POST /v1/refresh` | key | take Postgres's latest rows now |
| `GET`, `PUT /v1/labels` | key | names for tables and columns in approvals |
| `POST /v1/runs`, `GET /v1/runs` | key | start a run; list runs (`?status=&limit=`) |
| `GET /v1/runs/:id` | key or run | the run and its outcome |
| `DELETE /v1/runs/:id` | key | discard the run |
| `GET /v1/runs/:id/changes` | key or run | its changes, in words and rows, and its `version` |
| `POST /v1/runs/:id/sql` | run | SQL in the run's world |
| `POST /v1/runs/:id/mcp` | run | MCP (JSON-RPC) in the run's world |
| `POST /v1/runs/:id/propose` | key or run | ask for the merge |
| `POST /v1/runs/:id/approve`, `/reject` | key | decide a held run (or settle one in conflict) |
| `POST /v1/runs/:id/approvals` | key | a one-time approval link for a held run |
| `GET`, `POST /v1/approve` | approval | the widget's calls: see the change; decide it (`{"decision": "approve"}` or `"reject"`) |
| `POST`, `GET /v1/webhooks`, `DELETE /v1/webhooks/:id` | key | manage webhooks |
| `GET /v1/events` | key | past events (`?after=<event id>&limit=`) |
| `GET /widget.js` | none | the approval widget |

## Configuration

The gateway reads its settings from environment variables. With the service, set them in
`/etc/chronos-gateway/gateway.env`, then `sudo systemctl restart chronos-gateway`. `chronos-gateway --help` lists
them too. Times take `60`, `60s`, `15m`, `1h` or `1d`. For limits, `0` means no limit.

**Where it runs**

| Variable | Default | Meaning |
|---|---|---|
| `GATEWAY_LISTEN` | `127.0.0.1:7400` (image: `0.0.0.0:7400`) | Address and port it listens on. |
| `GATEWAY_PUBLIC_URL` | `http://` + `GATEWAY_LISTEN` | How clients and browsers reach it. Used in `sql_url`, `mcp_url` and approval links. Use `https://` anywhere but this machine. |
| `GATEWAY_DATA` | `gateway-data` (service: `/var/lib/chronos-gateway`, image: `/data`) | Its data folder. |
| `GATEWAY_ALLOWED_ORIGINS` | none | Web origins allowed to call the approval endpoints from a browser, comma-separated (`https://app.example.com`). |
| `GATEWAY_API_KEY` | unset | One more developer key to accept, besides those made with `keys create`. It can't be revoked with `keys revoke`: remove it and restart. |
| `RUST_LOG` | `chronos_gateway=info` | Log detail, for example `chronos_gateway=debug`. |

**The engine and your Postgres**

| Variable | Default | Meaning |
|---|---|---|
| `CHRONOS_BIN` | the engine the installer put beside it, else `chronos` on the `PATH` | The engine binary. |
| `GATEWAY_REFRESH_EVERY` | `5m` | How often the engine takes Postgres's latest rows. |
| `GATEWAY_SOURCE_FILE` | unset | A file holding the Postgres URL. Copied into the data folder at each start. |
| `GATEWAY_TABLES` | unset | With `GATEWAY_SOURCE_FILE`: the tables to attach at the first start, comma-separated. |
| `GATEWAY_TENANT_COLUMN` | unset | With `GATEWAY_TABLES`: the tenant column. |
| `CHRONOS_ENGINE_URL`, `CHRONOS_ADMIN_TOKEN` | unset | Use an engine you run yourself instead of starting one. Both are needed. Then attach where that engine runs, and call `POST /v1/setup`. |

**Rules and limits**

| Variable | Default | Meaning |
|---|---|---|
| `GATEWAY_POLICY` | `gateway` | Name of the merge policy runs keep to. |
| `GATEWAY_POLICY_RULES` | `max_rows = 500, max_deletes = 0, rows_per_hour = 5000, max_age = '15 minutes', check_reads = true, require_scope = true` | The rules a change must keep to be written without a person. See below. |
| `GATEWAY_RUN_TTL` | `1h` | How long a run, and its token, lasts. A run can ask for less (`ttl_seconds`), not more. |
| `GATEWAY_HOLD_TTL` | `3d` | How long a held change waits for a person before it expires. |
| `GATEWAY_APPROVAL_TTL` | `1d` | How long an approval link works, at most. |
| `GATEWAY_RUN_STATEMENTS_PER_MINUTE` | `120` | SQL statements and MCP tool calls per run per minute. Past it: `429`. |
| `GATEWAY_RUN_PROPOSES_PER_MINUTE` | `6` | Proposes per run per minute. Each one locks and compares rows in your Postgres. Past it: `429 too_many_proposes`. |
| `GATEWAY_RUNS_PER_HOUR` | `60` | New runs per tenant per hour. Past it: `429 too_many_runs`, and a `run.refused` webhook. |
| `GATEWAY_RUN_MAX_ROWS` | `1000` | Rows one SQL answer returns to an agent. Longer answers are cut and marked `truncated`. |

The default rules, in plain words: a change is written without a person only if it deletes no rows, changes at most
500 rows, keeps its tenant under 5,000 changed rows an hour (counted across all its runs), was made within the last
15 minutes, every row it read still matches Postgres, and it declares its tenant (every gateway run does). Anything
else is held.

`GATEWAY_POLICY_RULES` replaces that whole list. The rules are applied when you connect. To change them later, set
the variable, restart, then apply it:

```bash
curl -s -X POST localhost:7400/v1/setup -H "Authorization: Bearer $KEY" -H 'Content-Type: application/json' -d '{}'
```

**Optional: link to Chronos Cloud.** Unset by default, and then nothing below runs. With `GATEWAY_CLOUD` set, the
gateway opens one outbound TLS connection to Chronos Cloud so its dashboard can show reviews and send back what
people decide there. The Postgres URL and the engine's admin token never cross that link.

| Variable | Default | Meaning |
|---|---|---|
| `GATEWAY_CLOUD` | unset | The cloud's `https://` address. |
| `GATEWAY_CLOUD_ENROLL` | unset | The one-time enrollment token (`cce_...`) from the dashboard, for the first start. |
| `GATEWAY_CLOUD_ALLOW` | `read,merge,discard,undo` | What the cloud may ask for. Also `agents`, `policy`, `sql` (read-only). |
| `GATEWAY_CLOUD_SHARE` | `diffs` | `diffs`: changed rows, less columns your labels hide. `counts`: no row leaves your network. |
| `HTTPS_PROXY`, `NO_PROXY` | unset | A proxy for that link (HTTP CONNECT). |

## Security model

**Three kinds of token.** Each is 32 random bytes with a prefix. The gateway stores only their SHA-256 hashes.

| Token | Who holds it | What it opens | How long |
|---|---|---|---|
| `cgk_` developer key | your backend | everything except a run's own SQL and MCP, and the widget's calls | until revoked (`keys revoke <id>`) |
| `cgr_` run token | one agent | that one run: its SQL, MCP, changes, status and propose | until the run ends or its time runs out |
| `cga_` approval token | one person | one held change, at the version it was made for, once | `GATEWAY_APPROVAL_TTL` |

Keep the developer key in your backend only: it can start runs and approve held changes. It never reaches Postgres
directly.

**Tenant scope.** The engine holds each run's agent to one tenant. Every read and write of a table that has the
tenant column is filtered to that tenant, whatever SQL the agent sends: joins, subqueries,
`set row_security = off` and past versions included. Two limits to know:

- A table without the tenant column is visible to every run in full. Give such tables the column, or don't attach
  them.
- Since 0.1.1, `POST /v1/runs` refuses a tenant column that no attached table has (`400 tenant_column`), and the
  `"column = value"` form takes only a plain column name and `=`. In 0.1.0, a typo such as `"org = 42"` for
  `org_id`, or a comparison such as `"id <= 10"`, was accepted and could read every tenant's rows. If you run 0.1.0,
  [upgrade](#upgrading).

**What reaches Postgres, and when.**

| When | What happens in Postgres |
|---|---|
| `POST /v1/connect/check` | The gateway logs in with the URL you sent and reads the catalog. No writes. The URL isn't kept. |
| `POST /v1/connect` | The engine logs in as the gateway's role and reads the attached tables to copy them. |
| Every `GATEWAY_REFRESH_EVERY` | The engine reads the attached tables again. |
| An agent's SQL or MCP | Nothing. It runs in the run's world. |
| A merge (rules kept, or a person approved) | One transaction: each row the merge writes is locked and compared with Postgres, then written, and the merge is recorded in `chronos.merges`. If any row changed meanwhile, nothing is written. |
| Held, rejected, expired or discarded | Nothing. |

Between refreshes an agent may read a row that is out of date. That is safe: the merge compares every row it writes
with Postgres, and the default `check_reads = true` holds a change if a row it read has changed.

**What is on the gateway's host.** The data folder is readable by the gateway's user only (the service makes it mode
700).

| File | Holds |
|---|---|
| `gateway.db` | The SQLite store: token hashes, runs, approvals, events, and webhook signing secrets (needed to sign, so kept as they are). Mode 600. |
| `secret.key` | The key that seals the engine tokens of run agents inside the store. Mode 600. |
| `source.url` | The Postgres URL, with its password. Mode 600. |
| `engine.json` | The engine's local port and admin token. Mode 600. |
| `db/` | The engine's folder: the copy of the attached tables and the runs' worlds. |
| `engine.log` | The engine's output. |

Anyone who takes this host can act as the gateway's Postgres role. That is why the role should have only the rights
in `role_sql`, never an owner's or a superuser's.

**On the network.** The engine listens on `127.0.0.1` only. The gateway listens on `127.0.0.1:7400` unless you
change it, over plain HTTP. Tokens travel in headers, so put TLS in front (nginx, Caddy, your load balancer) before
anything on another machine calls it, and set `GATEWAY_PUBLIC_URL` to the `https://` address. The gateway logs a
warning when it listens beyond loopback with an `http://` public URL.

**Downloads.** The installer checks every binary against its release's `SHA256SUMS`. Releases aren't signed yet. The
image is pushed with build provenance and an SBOM.

## Running it in production

- **TLS:** see [On the network](#security-model) above.
- **Health:** `GET /health` answers `{"ok": true}` without a token. `GET /v1/status` (with a key) also says whether
  the engine is healthy.
- **Logs:** service: `journalctl -u chronos-gateway`. Docker: `docker logs chronos-gateway`. The engine writes to
  `engine.log` in the data folder (`/var/lib/chronos-gateway/engine.log`; in Docker,
  `docker cp chronos-gateway:/data/engine.log .`).
- **Backups:** back up the data folder along with your Postgres. It holds the store, the keys and the engine's
  folder. For a consistent copy, stop the gateway first:

  ```bash
  sudo systemctl stop chronos-gateway
  sudo tar -C /var/lib -czf chronos-gateway-backup.tar.gz chronos-gateway
  sudo systemctl start chronos-gateway
  ```

- **Large tables:** each refresh reads the attached tables in full. On big tables, refresh less often
  (`GATEWAY_REFRESH_EVERY`).
- **The service unit** runs as `chronos-gateway` with a hardened sandbox (`ProtectSystem=strict`, `NoNewPrivileges`,
  write access to the data folder only). On stop, the gateway stops the engine cleanly before it exits.

## Upgrading

Back up the data folder first. Upgrades keep settings, data and keys.

| Install | Upgrade |
|---|---|
| Installer, `--service` | Run the same command again: `curl -fsSL https://github.com/Abhishekxdg/chronos-gateway-releases/releases/latest/download/install.sh \| sudo sh -s -- --service`. It replaces both binaries and restarts the service. |
| Installer, binaries only | Run the same command again, then restart your `chronos-gateway`. |
| Docker | `docker pull ghcr.io/abhishekxdg/chronos-gateway:<version>`, then `docker rm -f chronos-gateway` and run the same `docker run` command with the new tag. The volume carries over. |
| Docker Compose | Set the new `GATEWAY_VERSION` in `.env`, then `docker compose pull && docker compose up -d`. |

Check the result with `chronos-gateway --version` (Docker: `docker exec chronos-gateway chronos-gateway --version`).
The bundled engine answers `--version` too:

| Install | Engine version |
|---|---|
| Installer, `--service` | `/usr/local/lib/chronos-gateway/chronos --version` |
| Installer, binaries only | `~/.local/lib/chronos-gateway/chronos --version` |
| Docker | `docker exec chronos-gateway chronos --version` |

## Uninstalling

```bash
curl -fsSL https://github.com/Abhishekxdg/chronos-gateway-releases/releases/latest/download/install.sh | sudo sh -s -- --uninstall
```

This removes the service and both binaries, and keeps the data folder and the settings. To remove those too (the
store, the keys and the engine's folder; this can't be undone):

```bash
sudo rm -rf /var/lib/chronos-gateway /etc/chronos-gateway && sudo userdel chronos-gateway
```

For a binaries-only install, run the first command with `sh` instead of `sudo sh`, and delete your data folder
yourself. For Docker: `docker rm -f chronos-gateway`, and `docker volume rm chronos-gateway` to delete the data.

The tables you attached stay as they were. The gateway's role and the `chronos` schema stay in Postgres until you
drop them.

## Troubleshooting

| What you see | Why, and what to do |
|---|---|
| `401` with "send a developer key" | The `Authorization: Bearer cgk_...` header is missing, or the token is a run or approval token. |
| `/v1/connect/check`: "not a Postgres URL: invalid value for option `sslmode`" or "unknown option" | The check takes `sslmode` `disable`, `prefer` or `require`, and no other URL options. Drop `verify-full`, `sslrootcert` and the like for the check only. `/v1/connect` takes them. |
| `/v1/connect/check`: a TLS or certificate error | The check trusts only the public web CAs. With a private CA, make the role from the [template](#step-2-make-the-gateways-role) and go straight to `/v1/connect`. |
| `/v1/connect`: "the server asks for the password as MD5" (or "in the clear") | Set `password_encryption = 'scram-sha-256'` and set the role's password again (`alter role chronos_gateway password '...'`), or connect with `sslmode=verify-full`. |
| `/v1/connect`: "no CA certificates found" | `verify-full` found no system CA bundle. Add `sslrootcert=<file.pem>` with your CA, readable by the gateway's user (in Docker, mount it). |
| `/v1/connect` in Docker can't reach a Postgres on the same machine | Inside the container, `localhost` is the container. Use `host.docker.internal` (Docker Desktop; on Linux add `--add-host=host.docker.internal:host-gateway` to `docker run`). |
| `/v1/connect`: `409 attached` | This data folder already has a Postgres. Use a new data folder for different tables. |
| "the engine didn't start within 30 s" | Read `engine.log` in the data folder. |
| `POST /v1/runs`: `400 tenant_column` | No attached table has that column. The message lists the attached tables and their columns. |
| `429 too_many_runs`, `too_many_proposes`, or "statements a minute" | A limit from [Configuration](#configuration). A loop that never settles a conflict hits `too_many_proposes`. |
| Propose: `409 conflict` | Rows changed in Postgres meanwhile. Proposing the same way again fails the same way: settle it (`"by_columns": true` first) or have a person approve it. |
| Approve: `409 stale` | The run changed after the person saw it. Make a new approval link. |
| Approval link: `410 expired` or `409 used` | Make a new link with `POST /v1/runs/:id/approvals`. |
| The widget doesn't load or its calls fail | The browser must reach `GATEWAY_PUBLIC_URL`, and your site's origin must be in `GATEWAY_ALLOWED_ORIGINS`. |
| Log warning "listening on 0.0.0.0:7400 over plain HTTP" in Docker | Expected inside the container. It is fine while the port is published to `127.0.0.1` only. Put TLS in front and set an `https://` `GATEWAY_PUBLIC_URL` before exposing it. |
| Installer: "doesn't run on this machine; nothing was installed" | The x86-64 build needs an x86-64-v2 CPU. Use the Docker image on another host. |
| Installer: "no macOS build of the gateway yet" | Use Docker on macOS. |

Questions and bug reports: [issues](https://github.com/Abhishekxdg/chronos-gateway-releases/issues).

## License

Chronos Gateway is under the Business Source License 1.1 ([`LICENSE`](LICENSE)). In short:

- You may use it in production, for your own products and your own company.
- You may not offer it to third parties as a hosted or managed service.
- Four years after each version is published, that version becomes Apache License 2.0.

The `LICENSE` file is the binding text. The engine it bundles (`chronos`) is a separate project with its own
license, in [its repository](https://github.com/Abhishekxdg/Chronos-DB).
