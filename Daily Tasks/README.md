# Daily Tasks ? 16-ticket execution plan

Updated: 2026-09-16. Master roadmap: [5-Semana-Plano.md](5-Semana-Plano.md).

## Unsaon paggamit

1. Ablihi ang folder sa karong adlawa ug buhata ang main focus una.
2. Tan-awa ang prerequisite/approval sa dili pa magsugod sa dependent work.
3. Sa katapusan sa adlaw, isulat ang nahuman, evidence, blocker/owner ug next action.
4. I-update ang status sumala sa tinuod nga resulta. Planned work is not Done.

**Target: all 16 tickets within 25 weekdays, September 16?October 20, 2026.**
Weekends excluded; leave/public holidays are not yet deducted. October 21 is the
five-week anniversary. The existing October 16 Discovery milestone stays in place.
This is a proposed capacity-dependent schedule, not a verified promise or a change
to official Plane dates. Plane ticket descriptions/acceptance criteria and live status
have not been fetched in this session. New-ticket dependencies below are planning
assumptions pending confirmation. No tickets or messages were changed in Plane.

## Current baseline and proposed targets

The latest local September 16 completion log takes precedence over older scaffold notes.
**Correction (2026-09-16 evening): CW-MCP-01 registration is NOT fully done** —
it saved successfully in the registry and a connect command was generated, but
the live connection is unstable (intermittent 401s from Octelium, confirmed not
caused by our own container setup). Two separate root causes identified and
sent to Ivan: (1) no OAuth client identity registered for Claude Code itself as
a Janus caller, (2) Octelium rejects the registry's generic Bearer-token
backend-auth scheme outright at its own layer. Waiting on Ivan's answers before
this can be marked Done. D-04 approval is still pending in the recorded baseline. The eight KB/retrieval tickets
were recorded as Backlog with no official dates. Deliverables below are planning checklists,
not replacements for the actual ticket acceptance criteria.

| Ticket | Scope | Priority | Recorded status / prerequisite | Due / target | Evidence to prepare |
|---|---|---|---|---|---|
| CW-MCP-01 | Read-only Postgres MCP | High | Registry entry saved but connection unstable — Octelium auth architecture issue, blocked on Ivan | Sep 18 target | Query guide, placement confirmation, existing acceptance evidence, stable connection proof |
| D-04 | Entra ID / SSO discovery | High | Waiting for Ivan/Evgeny approval | Sep 24 recorded due | Approved export, application inventory, findings and intake handoff |
| D-07 | ConnectWise Manage discovery | High | Starts Sep 22; D-02 dependency | Oct 03 recorded due; deliver Oct 02 | Estate inventory, verified integrations, owner validation, intake records |
| D-15 | Foundry GitLab repo scan | High | Starts Sep 22 | Oct 03 recorded due; deliver Oct 02 | Repo/config inventory, systems found, evidence and intake handoff |
| D-13 | RMM / monitoring discovery | High | Starts Sep 29 | Oct 08 recorded due | Tools, coverage, owners, integrations and intake records |
| D-14 | Infrastructure / cloud discovery | High | Starts Sep 29 | Oct 08 recorded due | Platform inventory, ownership, integrations and intake records |
| D-16 | Headless data stores | Medium | Starts Sep 29 | Oct 08 recorded due | Store inventory, purpose, owner, access boundary and intake records |
| CW-MCP-04 | Curated ConnectWise MCP v0 | Medium | Needs CW-MCP-01 baseline | Oct 15 proposed target | Agreed tool scope, implementation, access/error checks, usage guide and demo |
| KB-02 | Outline evaluation spike | High | Backlog; priority/scope confirmation needed | Sep 23 proposed target | Evidence against all six actual gates; Outline vs Docmost/BookStack go/no-go |
| KB-01 | One SOP end-to-end tracer | Medium | Backlog; depends on agreed KB direction | Sep 28 proposed target | One SOP: Outline -> GitLab -> Postgres -> gateway, with reproducible evidence |
| KB-05 | Outline + Entra SSO + collections + RLS | Medium | Backlog; SSO/hosting/access required | Oct 07 proposed target | Deployment, SSO, client collections, metadata RLS and isolation checks |
| KB-06 | Hybrid KB retrieval + MCP read tools | Medium | Backlog; data/access and KB baseline required | Oct 14 proposed target | Postgres FTS + pgvector + RRF, MCP reads, golden set run #1 |
| KB-09 | Reviewed agent write path | Medium | Backlog; KB metadata/identity baseline required | Oct 19 proposed target | propose_change, review UI, verified_by/last_verified stamping and review-flow evidence |
| CW-RET-02 | Case cards, embeddings, backfill + CDC | Medium | Backlog; data pipeline, model access and upstream dependencies unverified | Oct 12 proposed target | Enrichment, measured full backfill, CDC lag below 15 minutes; evidence |
| CW-RET-03 | Hybrid ConnectWise retrieval | Medium | Backlog; needs usable case cards/index | Oct 15 proposed target | Dense + BM25 + reranker; find_similar/get_ticket and evaluation evidence |
| CW-RET-04 | Problem groups + canonical solutions | Medium | Backlog; needs case cards and retrieval baseline | Oct 20 proposed target | Clustering, canonical solutions, search_solutions and quality review |

## Capacity and blockers

At the first planning check, obtain actual ticket criteria, upstream owners, access and
remaining effort estimates. Reserve time for review/fixes; do not assume five full build days
each week. If estimates exceed available capacity, ask Paul to prioritize, narrow accepted
scope or provide support. Report the impact before dates slip. The additional eight tickets
are substantial engineering work, so an all-16 finish is an aggressive target.

## Historical PDF

`5-Semana-Plano.pdf` is the old eight-ticket snapshot, retained for history only.
Use the Markdown roadmap and daily folders for this updated 16-ticket plan.

## Archived baseline ? preserved for ticket links and history

The content below is historical; statuses and sequencing may be stale. Use the table above and daily evidence.

# Daily Tasks

One dated folder per working day (`YYYY-MM-DD/README.md`) with that day's execution
plan, checked off as it happens. This file is the standing index: the full ticket
backlog and where each one actually stands, so a daily plan can be built in minutes
instead of re-deriving it from Plane every morning.

Workspace: Geidi (Plane) · Project: **Geidi-MCP** (`GEIDIMCP`) · Assignee: Riel Jake

**5-week roadmap (target: all 8 Discovery-phase tickets Done by 2026-10-16,
none left behind): see [`5-Semana-Plano.md`](5-Semana-Plano.md) /
[PDF](5-Semana-Plano.pdf). Covers only the Discovery-phase tickets below — see
the separate "Newly discovered" section for 8 more Geidi-MCP tickets found on
2026-09-16 that this roadmap does NOT cover yet.**

## Backlog snapshot (as of 2026-09-15) — ordered High → Medium

| Ticket | Priority | State | Start | Due | Status |
|---|---|---|---|---|---|
| [CW-MCP-01](https://app.plane.so/geidi/projects/4fadd894-3665-471c-8920-5cab6ae9228e/issues/dab2c4db-5ef9-45d6-bee5-66dda17174a2) Stand up read-only Postgres MCP for cw-postgres | High | Todo | — | — | **Registered in Janus (2026-09-16)** — server up, all 4 acceptance checks pass, registered in the MCP Gateway Registry (`claude mcp add --transport http cw-postgres-mcp https://janus.scale.au/cw-postgres-mcp/mcp`). Remaining: zone/group placement (Chris Jane), draft `docs/querying-cw-postgres.md` §1–§3 once `cw-ai-data-platform` repo access is confirmed |
| [D-04](https://app.plane.so/geidi/projects/4fadd894-3665-471c-8920-5cab6ae9228e/issues/eb4f7569-403e-4324-85f0-56badcfcb145) Entra ID enterprise apps + SSO export | High | Todo | 2026-09-15 | **2026-09-24** | Started, unblocked — needs Ivan/Evgeny approval before pulling the export |
| [D-07](https://app.plane.so/geidi/projects/4fadd894-3665-471c-8920-5cab6ae9228e/issues/f69d8fb2-d64b-490e-8dfb-1e62cbd3913c) Discover ConnectWise Manage estate | High | Todo | 2026-09-22 | 2026-10-03 | Not started yet — blocked by D-02 (Angel, due 2026-09-19) |
| [D-15](https://app.plane.so/geidi/projects/4fadd894-3665-471c-8920-5cab6ae9228e/issues/9a1499ce-80e9-4dbe-8c43-35a1400466ea) Scan Foundry GitLab repos | High | Todo | 2026-09-22 | 2026-10-03 | Not started yet |
| [D-13](https://app.plane.so/geidi/projects/4fadd894-3665-471c-8920-5cab6ae9228e/issues/cc4d9850-097c-4de5-8b00-707ed06cc525) Discover RMM/monitoring | High | Todo | 2026-09-29 | 2026-10-08 | Not started yet |
| [D-14](https://app.plane.so/geidi/projects/4fadd894-3665-471c-8920-5cab6ae9228e/issues/01d9ba59-52c2-45ee-b5db-82f05fae636e) Discover infra/cloud platforms | High | Todo | 2026-09-29 | 2026-10-08 | Not started yet |
| [D-16](https://app.plane.so/geidi/projects/4fadd894-3665-471c-8920-5cab6ae9228e/issues/07c560e5-e985-4fda-aa21-ba6e53b6179d) Enumerate headless data stores | Medium | Todo | 2026-09-29 | 2026-10-08 | Not started yet |
| [CW-MCP-04](https://app.plane.so/geidi/projects/4fadd894-3665-471c-8920-5cab6ae9228e/issues/da80f91a-f15d-4d09-aab8-233f2831596f) Build curated ConnectWise MCP v0 | Medium | Backlog | — | — | Downstream of CW-MCP-01 (needs it as baseline) — not started |

## Newly discovered (2026-09-16) — NOT in the 5-week roadmap yet

Paul flagged (Teams, 2026-09-16) that the assignee count looked off — turned out
16 tickets are assigned in Geidi-MCP, not 8. Investigated: all 8 extra tickets
(Knowledge Base + ConnectWise Retrieval workstreams) were created **and
assigned by Paul himself, earlier the same day** (KB-* ~03:23 UTC, CW-RET-*
~01:52 UTC, per `created_at`/`created_by`) — not something missed for weeks,
just not yet seen since Plane hadn't been re-checked since. All 8 are in
**Backlog** state with no start/target dates set — unscheduled, not yet
sequenced anywhere. Flagged back to Paul with this finding; waiting on his
input on priority relative to the Discovery-phase work above before slotting
these into a plan.

| Ticket | Priority | State | Workstream |
|---|---|---|---|
| [KB-02](https://app.plane.so/geidi/projects/4fadd894-3665-471c-8920-5cab6ae9228e/issues/8a64c0d0-2ef8-4444-98ca-ce5662ec58f3) Outline spike against the six evaluation gates; go/no-go vs Docmost/BookStack | High | Backlog | Knowledge Base |
| [KB-01](https://app.plane.so/geidi/projects/4fadd894-3665-471c-8920-5cab6ae9228e/issues/d9ee2e87-53d1-4f11-8593-cd7b13789454) Tracer bullet: one SOP end to end (Outline → GitLab → Postgres → gateway) | Medium | Backlog | Knowledge Base |
| [KB-05](https://app.plane.so/geidi/projects/4fadd894-3665-471c-8920-5cab6ae9228e/issues/6a5a3ba0-ad59-4501-ab31-9fb7b4c320bc) Deploy Outline with Entra SSO + per-client collections; metadata store with RLS | Medium | Backlog | Knowledge Base |
| [KB-06](https://app.plane.so/geidi/projects/4fadd894-3665-471c-8920-5cab6ae9228e/issues/b2bb7cfb-eb5b-4ecd-ab0a-f297e57ad511) Retrieval index (Postgres FTS + pgvector, RRF fusion) + MCP read tools; golden set run #1 | Medium | Backlog | Knowledge Base |
| [KB-09](https://app.plane.so/geidi/projects/4fadd894-3665-471c-8920-5cab6ae9228e/issues/fb68d32a-28a9-4cb8-aaf8-fcc4efc87385) Agent write path: `propose_change` tool, review UI, `verified_by`/`last_verified` stamping | Medium | Backlog | Knowledge Base |
| [CW-RET-02](https://app.plane.so/geidi/projects/4fadd894-3665-471c-8920-5cab6ae9228e/issues/4b653e13-81ad-4c22-8d7c-c8505a6cfb24) LLM enrichment to case cards, embeddings, full backfill + CDC (<15min lag) | Medium | Backlog | ConnectWise Retrieval |
| [CW-RET-03](https://app.plane.so/geidi/projects/4fadd894-3665-471c-8920-5cab6ae9228e/issues/1dd435a7-ba86-4bf6-93f4-a92325f2f70e) Hybrid retrieval service (dense+BM25+reranker) + `find_similar`/`get_ticket` | Medium | Backlog | ConnectWise Retrieval |
| [CW-RET-04](https://app.plane.so/geidi/projects/4fadd894-3665-471c-8920-5cab6ae9228e/issues/bc849e34-97a0-4222-8b61-17f5d5a8743e) Cluster case cards into problem groups, canonical solutions, `search_solutions` | Medium | Backlog | ConnectWise Retrieval |

Also assigned outside Geidi-MCP entirely (separate projects, not tracked here):
IT-Quoter MCP Rollout (1 ticket), geidi.ai-website/SEO (6 tickets), Phase3 (7
tickets) — 14 more, unrelated work. Full list pulled via Plane MCP on request.

## Sequencing logic

1. **D-04** is the only ticket already in its start window (2026-09-15–09-24) with
   nothing upstream blocking it — it's the default main-effort ticket until CW-MCP-01
   unblocks or D-07/D-15 open up on 2026-09-22.
2. **CW-MCP-01** is opportunistic: no active work to do until Ivan/Chris Jane reply,
   but check every day — once the token lands it becomes a same-day execute
   (stack's already scaffolded in `../ConnectWise MCP/`).
3. **D-07 / D-15** open up 2026-09-22. D-07 is formally blocked by D-02 (due
   2026-09-19) — don't start the estate write-up before that, but reading the
   `cw-ai-data-platform` repo (relevant to both D-07 and CW-MCP-01) is fair game
   earlier if the repo becomes reachable.
4. **D-13 / D-14 / D-16** open up 2026-09-29 — nothing to do on these before then.
5. **CW-MCP-04** waits on CW-MCP-01 producing a working baseline.

## Habit

Each morning: copy the section below into a new `YYYY-MM-DD/README.md`, check
Plane/Teams for anything that changed overnight, and re-sequence if a blocker
cleared or a new one appeared. Update the backlog snapshot above when a ticket's
state, dates, or blockers change.

remember when I am asking you to create for a message to a person, always in english basic. Understandable. But when i'm talking to claude, always cebuano.