# Chronos Gateway: host it yourself

Add AI agent features to your product without giving agents your database. Your app keeps using its Postgres; each
agent run gets a private copy (a **world**) holding only the rows of the one customer it works for. Its changes are
**proposed**: those within your rules (by default no deletes, at most 500 rows) are written to Postgres in one
checked transaction; the rest wait for a person (your team, or the end user, in a widget) before anything reaches
Postgres.

The gateway runs on your machine, next to your Postgres: no account, nothing sent anywhere. It is two binaries:
`chronos-gateway` (runs, tokens, approvals, webhooks) and the Chronos engine it runs (`chronos`: the worlds, the
rules, the checked write to Postgres).

**Status:** 0.1, for staging copies first. Linux (x86-64, arm64), or Docker anywhere. Postgres 12 or newer (16 and
17 tested); each attached table needs a primary key.

## Install

On a Linux server with systemd, as a service (the binaries in `/usr/local`, a `chronos-gateway` user, its data in
`/var/lib/chronos-gateway`, settings in `/etc/chronos-gateway/gateway.env`), started, with a first key for your
backend:

```bash
curl -fsSL https://github.com/Abhishekxdg/chronos-gateway-releases/releases/latest/download/install.sh | sudo sh -s -- --service
```

Or just the binaries, for you (`~/.local/bin`), to run it yourself:

```bash
curl -fsSL https://github.com/Abhishekxdg/chronos-gateway-releases/releases/latest/download/install.sh | sh
export GATEWAY_DATA=$PWD/gateway-data
chronos-gateway keys create backend     # your backend's key (cgk_...), shown once
chronos-gateway                         # listens on 127.0.0.1:7400
```

Or with Docker:

```bash
docker run -d --name chronos-gateway --restart unless-stopped -p 127.0.0.1:7400:7400 \
  -v chronos-gateway:/data ghcr.io/abhishekxdg/chronos-gateway:latest
docker exec chronos-gateway chronos-gateway keys create backend
```

(Or Docker Compose: `compose.yaml` in this repository, read-only, with no capabilities.)

The installer checks every download against its release's `SHA256SUMS` and runs both binaries before putting them
in place. Run it again to upgrade: settings, data and keys stay. `--uninstall` removes the service and the binaries
and keeps the data. `CHRONOS_GATEWAY_VERSION=v0.1.0` pins a release.

## Connect your Postgres

Look at your database first; nothing is written:

```bash
curl -s localhost:7400/v1/connect/check -H "Authorization: Bearer $KEY" -H 'Content-Type: application/json' \
  -d '{"url": "postgres://owner@your-db/app"}'
```

It lists each table, what attaching would refuse and why, which column looks like the tenant's, and `role_sql`: a
role with only the rights the engine needs. Make that role in Postgres, then connect with it:

```bash
curl -s localhost:7400/v1/connect -H "Authorization: Bearer $KEY" -H 'Content-Type: application/json' \
  -d '{"url": "postgres://chronos_gateway:...@your-db/app?sslmode=verify-full",
       "tables": ["leads", "accounts"], "tenant_column": "org_id"}'
```

(Or set `GATEWAY_SOURCE_FILE`, `GATEWAY_TABLES` and `GATEWAY_TENANT_COLUMN` in the settings: the gateway connects at
its next start, and the URL never goes through its API.)

## Run an agent

From your backend, with the client (`pip install chronos-gateway`, or `npm install @chronosdb/gateway`):

```python
from chronos_gateway import Gateway

gw = Gateway("http://localhost:7400", key=KEY)
with gw.run(tenant=user.org_id, intent="reassign Bo's open leads to Ada", end_user=user.id) as run:
    # MCP clients (Claude Code, the Claude Agent SDK): run.mcp_server()
    # tool-use loops (OpenAI, Anthropic): run.openai_tools(), run.call_tool(name, args)
    my_agent(run)
    result = run.propose()

if result.held:                                  # a rule wants a person
    link = gw.approval(run.id, end_user=user.id)
    # in your page: <script src="{link.script}"></script> {link.html}
```

The agent sees and changes only that tenant's rows, in its own world, and never gets a Postgres credential. Webhooks
(`merge.landed`, `merge.held`, `merge.conflict`, `merge.rejected`, `run.expired`, `run.refused`) tell your backend
what happened.

## Run it safely

- It listens on `127.0.0.1:7400`. Before anything else calls it, put TLS in front (nginx, Caddy, your load balancer)
  and set `GATEWAY_PUBLIC_URL` to that address: tokens travel in headers.
- Give it the least-privilege role from `role_sql`, never an owner or a superuser.
- Back up its data folder (`/var/lib/chronos-gateway`, or the Docker volume) with your Postgres: it holds its store,
  its keys and the engine's folder.
- Settings: `chronos-gateway --help`, or the commented file `/etc/chronos-gateway/gateway.env` (then `sudo systemctl
  restart chronos-gateway`). Logs: `journalctl -u chronos-gateway`.

## Licence

Business Source License 1.1 (`LICENSE` in the releases repository): you may run it in production for your own products; you may not offer
it to others as a hosted service. Each version becomes Apache 2.0 four years after it is published.

Questions and bugs: [issues](https://github.com/Abhishekxdg/chronos-gateway-releases/issues).
