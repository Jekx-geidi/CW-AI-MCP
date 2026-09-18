# ConnectWise Postgres MCP (CW-MCP-01)

Read-only MCP server exposing `cw-postgres` (ConnectWise Manage replica) to agents,
reached through Octelium and registered in the MCP Gateway Registry.

Plane: [CW-MCP-01](https://) — "Stand up a generic read-only Postgres MCP against
cw-postgres through Octelium and register it in the gateway"

## Server choice

**[crystaldba/postgres-mcp](https://github.com/crystaldba/postgres-mcp)**, run in
`--access-mode=restricted`.

Why, over the official `@modelcontextprotocol/server-postgres`:

- The official reference server was **archived by Anthropic on 2025-05-29** — no
  further fixes or releases.
- `postgres-mcp`'s restricted mode does exactly what the ticket's guardrails ask
  for: queries run in a read-only transaction and resource use is constrained,
  instead of us having to hand-roll that enforcement in front of a generic server.
- It speaks SSE as well as stdio. The gateway needs a long-lived network-addressable
  server here (agents connect through Octelium, not a local subprocess), which rules
  out stdio-only servers.
- Ships a maintained Docker image (`crystaldba/postgres-mcp`), matching how other
  domain servers are expected to run behind the gateway.
- MIT licensed, active repo (issues/PRs/commits all recent as of this writing).

## Guardrails

Ticket requires these to hold end-to-end. Split across two layers:

| Guardrail | Enforced by |
|---|---|
| Read-only (`default_transaction_read_only`) | `cw_agent` Postgres role (Paul/Ivan) **and** `postgres-mcp --access-mode=restricted` |
| 60s statement timeout | `cw_agent` role default (`ALTER ROLE cw_agent SET statement_timeout = '60s'`) — confirm with Paul, restricted mode also caps runaway queries |
| 10-connection cap | `cw_agent` role `CONNECTION LIMIT 10` — confirm with Paul |

The MCP server is defense-in-depth, not the source of truth — the role-level
settings are what actually make an `UPDATE` fail and a runaway query get cut off.

## Connection (from Ivan, GEIDIMCP-51 comment, 2026-09-15)

- Host: `cw-postgres.default.local.access.geidi.com`, port 5432 — secretless,
  connect with any username, Octelium injects the real `cw_agent` credential
  upstream.
- Fallback IP `100.64.0.48` exists only for hostname-resolution problems and can
  shift on pod restart — never hardcode it, always use the hostname.
- Octelium domain: `access.geidi.com`.
- Ivan has drafted a `WORKLOAD`-type Octelium User (`cw-postgres-mcp`, already in
  `cw-data-readers`) but hasn't applied it — he's waiting on us to confirm the
  name. This repo assumes `cw-postgres-mcp`; reply on the ticket to confirm (or
  correct) so he can mint the `OCTELIUM_AUTH_TOKEN` credential.

## Blocked on

- **Ivan**: minting the `OCTELIUM_AUTH_TOKEN` credential for `cw-postgres-mcp`
  once the name is confirmed (see above).
- **Chris Jane**: gateway registration, zone/group placement, and tool description
  text (pull from `docs/querying-cw-postgres.md` §1–§3 once that exists).
- **Where domain servers run**: not yet confirmed by the gateway owner. This scaffold
  uses Docker Compose since it's portable to whatever the actual target turns out to
  be (bare Docker host, k3s via a Deployment manifest, etc.) with minimal rework.

## Running

```bash
cp .env.example .env
# fill OCTELIUM_AUTH_TOKEN once Ivan mints the credential (see below)
docker compose up -d
```

The server listens on SSE at `http://localhost:8000/sse` by default (see
`docker-compose.yml`).

## Acceptance verification

Run once the server is up and connected through Octelium. The mesh route only
exists inside the `octelium-connect` container's network namespace, not on the
Docker host — running `./scripts/verify-acceptance.sh` directly on the host
will fail to resolve `cw-postgres.default.local.access.geidi.com`. Run it
inside that namespace instead, via a throwaway container that has `psql`:

```bash
export OCTELIUM_CW_POSTGRES_URL=$(grep OCTELIUM_CW_POSTGRES_URL .env | cut -d= -f2-)
docker run --rm --network container:connectwisemcp-octelium-connect-1 \
  -e OCTELIUM_CW_POSTGRES_URL \
  -v "$(pwd)/scripts:/scripts" \
  postgres:16-alpine \
  sh -c "apk add --no-cache bash >/dev/null 2>&1 && bash /scripts/verify-acceptance.sh"
```

(On Windows/Git Bash, set `MSYS_NO_PATHCONV=1` first so the `-v` and
`--network` arguments aren't mangled into Windows paths.)

Checks, per the ticket:

1. List tables in `cw` schema.
2. `select count(*) from cw."Company"` → expect `490`.
3. Attempt an `update` against a `cw` table → must be refused.

Paste the script's output into the Plane ticket as evidence.
