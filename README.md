<div align="center">

# Chronos Gateway

**Let AI agents change your Postgres, without letting them touch it.**

Every agent gets its own private copy of its customer's rows. It can read, write and delete there all day.
Nothing reaches your database until the change passes your rules, and the rows it touches still match what's live.
Anything risky waits for a person to click **Approve**.

[![Release](https://img.shields.io/github/v/release/Abhishekxdg/chronos-gateway-releases?label=release)](https://github.com/Abhishekxdg/chronos-gateway-releases/releases/latest)
[![Image](https://img.shields.io/badge/ghcr.io-chronos--gateway-blue?logo=docker)](https://github.com/users/Abhishekxdg/packages/container/package/chronos-gateway)
[![Postgres 12+](https://img.shields.io/badge/Postgres-12%2B-336791?logo=postgresql&logoColor=white)](GUIDE.md#requirements)
[![License: BUSL-1.1](https://img.shields.io/badge/license-BUSL--1.1-lightgrey)](LICENSE)

[**Deploy in 1 minute**](#deploy-in-1-minute) · [**Try it in 5**](#your-first-agent-in-5-minutes) ·
[**Setup guide**](GUIDE.md) · [**API**](GUIDE.md#api-at-a-glance) ·
[**Chronos DB**](https://github.com/Abhishekxdg/Chronos-DB)

</div>

---

## Why

You want an agent to clean up a customer's CRM, fix their invoices, or reassign their leads. You don't want to hand
it a Postgres password and hope.

| Without a gateway | With Chronos Gateway |
|---|---|
| The agent holds a database password | The agent holds a run token that opens **one task, for one customer, for one hour** |
| A prompt injection reads every tenant's data | It only ever sees **its tenant's rows**, whatever SQL it sends |
| `DELETE FROM leads` runs on production | Deletes happen in a **private copy**; by default every delete waits for a person |
| A stale read overwrites someone's edit | Each row is **locked and compared with Postgres** at write time; a changed row stops the merge |
| You find out what it did from the logs | You see **"Remove lead ‘Hooli’"** and approve it, or turn it down |

Your app keeps reading and writing Postgres exactly as it does today. The gateway sits beside it, never in front of
it.

## How it works

```
 your app ─────────────── reads and writes, as today ──────────────────> Postgres
                                                                            ^
 your backend ── start a run for tenant 42 ──> gateway ──> engine           │ written only on a merge,
 the agent ───── SQL / MCP, run token ───────> gateway ──> its world        │ every row checked
                                                            (tenant 42 only) │
 your backend ── propose ──> rules kept ─────────────────────────> merged ──┘
                             a rule broken ──> held ──> approved ──> merged
                                                    └─> rejected ──> dropped
```

1. **Start a run** for one tenant. You get a token to hand the agent.
2. **The agent works** over SQL or MCP, in its own world: a copy holding only that tenant's rows.
3. **Propose.** Within your rules (by default: no deletes, at most 500 rows), it's written to Postgres in one checked
   transaction. Otherwise it's **held** for a person: your team through the API, or your own end user through a
   drop-in `<chronos-approve>` widget.
4. **Webhooks** tell your backend what landed, what's held, and what conflicted.

More in [How it works](GUIDE.md#how-it-works).

## Deploy in 1 minute

Pick one. All three give you the same API on port `7400`, and an admin console at `/console` that walks you through
the rest: connect Postgres, set the rules, review and approve what agents change.

### Docker (easiest, any OS)

```bash
docker run -d --name chronos-gateway --restart unless-stopped \
  -p 127.0.0.1:7400:7400 -v chronos-gateway:/data ghcr.io/abhishekxdg/chronos-gateway:latest

docker logs chronos-gateway     # a setup code: open http://localhost:7400/console and enter it
```

### Linux server (systemd service)

```bash
curl -fsSL https://github.com/Abhishekxdg/chronos-gateway-releases/releases/latest/download/install.sh | sudo sh -s -- --service
```

It checks every download against `SHA256SUMS`, installs a systemd service, and prints the console's address and a
setup code.
[Read the script first](GUIDE.md#1-the-installer-linux) if you like.

### Docker Compose, on your own domain with HTTPS

Point your domain's DNS at the server, then:

```bash
mkdir chronos-gateway && cd chronos-gateway
curl -fsSLO https://raw.githubusercontent.com/Abhishekxdg/chronos-gateway-releases/main/compose.yaml
echo 'GATEWAY_DOMAIN=gateway.example.com' > .env
docker compose --profile https up -d     # Caddy gets the certificate by itself
docker compose logs gateway              # a setup code: open https://gateway.example.com/console
```

Leave out the domain and `--profile https` to run it on this machine only.

### Then, in your browser

Open the console, enter the setup code from the log, and it makes your first key and signs you in. **Get started**
lists the rest. Every option, including pinning a version and running without root:
[Install](GUIDE.md#install), [Set it up in the console](GUIDE.md#set-it-up-in-the-console).

## Your first agent in 5 minutes

### Connect your Postgres

**1. Look at your database.** Read-only: nothing is written, and the URL isn't kept.

```bash
curl -s localhost:7400/v1/connect/check -H "Authorization: Bearer $KEY" -H 'Content-Type: application/json' \
  -d '{"url": "postgres://admin:PASSWORD@db.internal:5432/app"}'
```

It tells you which tables can be attached, which column looks like your tenant (`org_id`, `tenant_id`, ...), and
gives you `role_sql`: a least-privilege role for the gateway. Run that once as a database admin.

**2. Attach the tables agents may work on**, as that new role:

```bash
curl -s localhost:7400/v1/connect -H "Authorization: Bearer $KEY" -H 'Content-Type: application/json' \
  -d '{"url": "postgres://chronos_gateway:ROLE_PASSWORD@db.internal:5432/app",
       "tables": ["leads"], "tenant_column": "org_id"}'
```

### Run an agent

**3. Start a run** for one customer, and hand its token to your agent:

```bash
curl -s localhost:7400/v1/runs -H "Authorization: Bearer $KEY" -H 'Content-Type: application/json' \
  -d '{"tenant": 42, "intent": "remove the duplicate lead"}'
# → {"id": "run_...", "token": "cgr_...", "sql_url": "...", "mcp_url": "..."}
```

```bash
export RUN=run_... RUN_TOKEN=cgr_...   # "id" and "token" from that answer
```

**4. The agent works.** It sees tenant 42's rows only, and nothing reaches Postgres yet:

```bash
curl -s localhost:7400/v1/runs/$RUN/sql -H "Authorization: Bearer $RUN_TOKEN" -H 'Content-Type: application/json' \
  -d '{"sql": "delete from leads where id = 3"}'
```

MCP agents (Claude Code, the Claude Agent SDK, any MCP client) point at `mcp_url` with the same token instead.

**5. Propose it.** A delete breaks the default rules, so it's held for a person:

```bash
curl -s localhost:7400/v1/runs/$RUN/propose -H "Authorization: Bearer $KEY" -H 'Content-Type: application/json' -d '{}'
# → 202 {"status": "held", "reasons": [...]}: the default rules allow no deletes

curl -s localhost:7400/v1/runs/$RUN/approve -H "Authorization: Bearer $KEY" -H 'Content-Type: application/json' \
  -d '{"by": "you@example.com"}'
# → {"status": "merged"}: now it's in Postgres, every row checked
```

The full walkthrough, with every answer explained: [Connect your Postgres](GUIDE.md#connect-your-postgres), then
[Run an agent](GUIDE.md#run-an-agent).

## From your code

```bash
pip install chronos-gateway          # or: npm install @chronosdb/gateway
```

```python
from chronos_gateway import Gateway

gw = Gateway("http://localhost:7400", key=KEY)

with gw.run(tenant=42, intent="reassign Bo's open leads to Ada", end_user="user_7") as run:
    my_agent(run)               # run.mcp_server(), or run.openai_tools() + run.call_tool(...)
    result = run.propose()

if result.held:                 # a rule wants a person: show them the change in your app
    link = gw.approval(run.id, end_user="user_7")
```

Let your own users approve, right in your product:

```html
<script src="https://gateway.example.com/widget.js"></script>
<chronos-approve base="https://gateway.example.com" token="cga_..."></chronos-approve>
```

More in [Use it from your code](GUIDE.md#use-it-from-your-code) and
[Approve a held change](GUIDE.md#approve-a-held-change).

## What you get

- **Tenant isolation the agent can't talk its way out of.** Enforced by the engine on every read and write: joins,
  subqueries and `set row_security = off` included.
- **Your rules, as a merge policy.** Max rows, max deletes, rows per hour per tenant, how stale the work may be,
  reads checked against Postgres. [Configure them](GUIDE.md#configuration).
- **Reads checked per tenant.** A run is held when what it read changed, and only its own tenant's rows count:
  another customer's edits never hold it. A person can still approve a run whose reads changed, on purpose, and it's
  recorded that way.
- **Fresh within a second, if you like.** With `GATEWAY_FOLLOW=on` the engine takes your app's changes about a
  second after they commit, through a logical replication slot. Otherwise it reads them every 5 minutes
  (`GATEWAY_REFRESH_EVERY`). [Configuration](GUIDE.md#configuration).
- **An admin console** at `/console`: review held changes row by row and approve all or part, set the rules as a
  form, make keys, add webhooks. Sign in with a key or your SSO. [The console](GUIDE.md#the-console).
- **Changes in plain words** for whoever approves, with columns you choose to hide.
- **Signed webhooks** with retries: `merge.landed`, `merge.held`, `merge.conflict`, `merge.rejected`, `run.expired`.
- **Least privilege.** The gateway's role reads and writes only the tables you attach. It is never an owner or a
  superuser.
- **Your network, your data.** No account, no phone-home. Optional link to Chronos Cloud for a dashboard.
- **Works with the Postgres you run:** 12 or newer, wherever it's hosted, as long as the gateway can reach it.
  Tested on 12 to 18, Supabase (through its pooler) and Neon (pooled or direct, and waking from a suspend).

## Docs

| | |
|---|---|
| **Set it up** | [Requirements](GUIDE.md#requirements) · [Install](GUIDE.md#install) · [Set it up in the console](GUIDE.md#set-it-up-in-the-console) · [Your first key](GUIDE.md#your-first-key) · [Connect your Postgres](GUIDE.md#connect-your-postgres) |
| **Use it** | [Run an agent](GUIDE.md#run-an-agent) · [Approve a held change](GUIDE.md#approve-a-held-change) · [The console](GUIDE.md#the-console) · [Use it from your code](GUIDE.md#use-it-from-your-code) · [API at a glance](GUIDE.md#api-at-a-glance) |
| **Run it for real** | [Configuration](GUIDE.md#configuration) · [Security model](GUIDE.md#security-model) · [Running it in production](GUIDE.md#running-it-in-production) · [Upgrading](GUIDE.md#upgrading) · [Troubleshooting](GUIDE.md#troubleshooting) |
| **The engine underneath** | [Chronos DB](https://github.com/Abhishekxdg/Chronos-DB) · [Chronos DB docs](https://chronosdb-docs.vercel.app/) · [Attach to Postgres](https://chronosdb-docs.vercel.app/guides/attach-postgres) |

## Prefer the database itself?

The gateway is a service around [**Chronos DB**](https://github.com/Abhishekxdg/Chronos-DB), the database for AI
agents: worlds (branches of your data), merge policies, and the checked write-back to Postgres. Run Chronos DB on its
own when you'd rather drive it directly, over the Postgres wire protocol or MCP:

- [Chronos DB on GitHub](https://github.com/Abhishekxdg/Chronos-DB): releases, install, source
- [Quickstart](https://chronosdb-docs.vercel.app/quickstart) · [Concepts](https://chronosdb-docs.vercel.app/concepts) ·
  [Merge policies](https://chronosdb-docs.vercel.app/guides/merge-policies) ·
  [Attach to Postgres](https://chronosdb-docs.vercel.app/guides/attach-postgres)

## Status

Early: 0.2.5, on Chronos DB 0.4.6. Try it on a staging copy of your database first, and
[open an issue](https://github.com/Abhishekxdg/chronos-gateway-releases/issues) when something surprises you.

Source-available under [BUSL-1.1](LICENSE). Downloads are the installer, static Linux binaries (x86-64 and arm64)
and the image `ghcr.io/abhishekxdg/chronos-gateway` (amd64 and arm64).
