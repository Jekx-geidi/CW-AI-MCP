# 2026-09-16 — Plano sa Buhatunon

Gi-andam 2026-09-15 sa gabii. Tan-awa ang `../README.md` para sa tibuok backlog
ug ngano ni ang pagkasunod-sunod.

## 0. Una una — check kung naay reply (5 min)

- [x] Plane GEIDIMCP-51 — naa bay reply si Ivan (Octelium token / Docker-vs-k3s /
      `cw_agent` guardrails)? **Oo** — gipadala ni Ivan ang `OCTELIUM_AUTH_TOKEN`
      (2026-09-16).
- [ ] Teams — pareha, gikan sa message nga gipadala 2026-09-15.
- Kung **naa** na ang token: adto dayon sa Track A, pwede na buhaton karong
  adlawa kay ready naman ang stack. Kung **wala pa**: padayon dayon sa Track B,
  ayaw paghulat.

## Track A — CW-MCP-01 (kung naa nay reply si Ivan)

Repo: `../../` (kini nga Daily Tasks folder naa sulod sa ConnectWise MCP repo)

- [x] Tubaga si Ivan kung naa siyay gipangutana bahin sa ngalan sa identity;
      kuhaa ang `OCTELIUM_AUTH_TOKEN`. — nadawat na, walay dugang pangutana.
- [x] `cp .env.example .env`, i-fill ang `OCTELIUM_AUTH_TOKEN` (ug
      `OCTELIUM_DOMAIN` kung lahi sa `access.geidi.com`). — na-fill na, default
      ra ang domain.
- [x] Kung na-confirm na niya ang placement (Docker vs k3s) ug dili plain
      Docker: hunong una ug i-adjust ang `docker-compose.yml` sa dili pa
      i-stand up for real (ayaw lang pilita sa sayop nga target aron lang
      "ma-test"). — walay bag-ong info gikan ni Ivan bahin ani, plain Docker
      ang gigamit.
- [x] `docker compose up -d`, i-confirm nga healthy ang duha ka containers
      (`docker compose ps`, `docker compose logs`). — na-install ang Docker
      Desktop + WSL2 (2026-09-16), duha ka containers "Up", octelium-connect
      na-authenticate as `cw-postgres-mcp` ug "Connected successfully",
      postgres-mcp nag-start sa RESTRICTED mode.
- [x] Padagana ang `./scripts/verify-acceptance.sh`, siguroha nga tanan 3 ka
      checks pasar (table list, `Company` count = 490, update refused). —
      tanan 3 pasar. Na-ayo pud ang script (sayop nga column name `id` →
      `"Id"` sa check 3 nga naga-mask sa tinuod nga error — na-verify pag-usab
      nga "cannot execute UPDATE in a read-only transaction" gyud ang hinungdan,
      dili typo).
- [x] I-paste ang output sa script sa GEIDIMCP-51 isip evidence. — na-post na
      via Plane MCP (comment 6f2a520f), naglakip pud sa 4th check (60s
      statement timeout, na-cancel human sa 61s — wala diay ni sa orihinal
      nga script, gidugang na).
- [x] I-register ang server sa imong kaugalingon gamit ang LastMCP onboarding
      workflow (gi-confirm ni Chris Jane nga self-service na ni, dili na iya)
      — pangitaa ang onboarding flow, i-register ang `cw-postgres-mcp`, i-note
      ang link sa registry entry balik sa ticket. — **NAKA-REGISTER NA** ✅.
      Dugang detalye sa dalan: Proxy URL + Backend Auth token gikan ni Ivan →
      raw curl 401 (na-confirm nga naay tinuod nga Octelium guard, sayop ra
      ang token/session) → nadiskobrehan nga KITA ang dapat mo-run sa
      `--serve=cw-postgres-mcp` session (dili si Ivan) → naay unrelated nga
      `cw-postgres` `max_connections` outage nga na-diagnose ug na-ayo dungan
      (JDBC leak, dili ato) → bag-ong token ni Ivan → curl 200 sa `/sse` →
      Janus form nag-fail gihapon ("Credential rejected") kay lahi diay ang
      path/transport gina-check ni Janus → Chris Jane nag-confirm nga
      Streamable HTTP ra ang atubangan ni Janus, dili SSE → gi-set ang "SSE
      Endpoint" field explicitly → **successful registration**. Connect
      command: `claude mcp add --transport http cw-postgres-mcp
      https://janus.scale.au/cw-postgres-mcp/mcp`. Evidence posted sa
      GEIDIMCP-51.
      **Update, human pa niini:** nibalik ang 401 pag-usab (dili stable,
      naka-verify pinaagi sa clean container recreate nga dili tungod sa
      atong side). Root cause diay mas lawom — diagnostic gikan sa team
      (2026-09-16 pm) nag-identify og **duha ka SEPARATE problema**: (1)
      wala pa na-setup ang OAuth para kang Claude Code mismo isip authorized
      caller sa Janus (lahi ni sa OCTELIUM_AUTH_TOKEN ug JANUS_BACKEND_AUTH_TOKEN
      — ikatulo nga klase sa credential), ug (2) gi-reject gyud ni Octelium
      mismo ang generic "Bearer Token" backend-auth scheme sa registry
      (na-confirm via raw curl, 401 sa Octelium layer, wala pa gani ni-abot
      sa postgres-mcp) — posible nga kinahanglan ni Octelium og iyang
      kaugalingong client/tunnel identity para sa external callers parehas
      ni Janus, dili basta static bearer token. Duha ka pangutana gipadala
      kang Ivan; naghulat sa iyang tubag sa dili pa mahuman gyud ni.
- [ ] Kung natubag pud ni Ivan ang pangutana bahin sa `docs/plan.md` /
      `cw-ai-data-platform` access: kuhaa ang related nga schema section,
      i-draft ang `docs/querying-cw-postgres.md` §1–§3, ihatag kang Chris Jane
      para sa tool description text. — walay access/URL pa nga nakuha karon,
      nabilin para sa 2026-09-17+.
- [x] I-update ang backlog table sa `../README.md` — status sa CW-MCP-01.

## Track B — D-04 (Entra ID / SSO export) — default nga main effort

- [x] **Kuhaa una ang approval** — i-message si Ivan (cybersecurity approval)
      ug si Evgeny (Entra admin) nga mag-export ka og: enterprise
      applications, app registrations + API permissions, OAuth2 permission
      grants, service principals, ug 90-day sign-in logs per app. Read-only,
      walay secrets/tokens nga kopyahon. Ayaw pag-export sa wala pa ni
      ma-acknowledge. — message drafted ug gi-send 2026-09-16, naghulat pa sa
      reply ni Ivan/Evgeny.
- [ ] Kung na-approve na: kuhaa ang export (Graph API o portal export).
- [ ] Himoa ang usa ka row per application: ngalan, publisher, SSO type,
      assigned users/groups, last sign-in, permissions nga gihatag, tingali
      unsa nga business team, tingali kinsa ang owner (guess, i-flag nga
      i-validate), suspected duplicate/legacy.
- [ ] I-cross-check ang listahan batok sa seed system inventory sa Program
      Charter page — markahi kung unsa ang BAG-O.
- [ ] I-post ang export summary (row count, date, walay secrets) ug ang
      listahan sa bag-ong nadiskobrehan nga systems isip comment sa D-04.
- [ ] Intake records: ang D-02 (ang intake template, gina-buhat ni Angel) wala
      pa tapos (due 2026-09-19) — ayaw pag-block ani. Ihatag lang ang raw
      findings kang Angel karon ug i-note nga ang formal intake-record
      formatting mosunod human na ang template; balikan ang status sa D-02 sa
      dili pa ang 2026-09-24 due date.
- [ ] I-update ang backlog table sa `../README.md` — status sa D-04.

## Kung parehas na-stall ang duha ka tracks

- [ ] Basaha ang `cw-ai-data-platform` repo docs kung naabli na ang access
      (makatabang sa CW-MCP-01's tool description ug sa D-07 nga muabot) —
      wala pa nasulayan, walay access/URL nga nakuha karon.
- [x] Kung wala gyu'y mahimo: i-flag kang Nicko/Paul kung tinuod nga wala
      gyu'y trabahoon — resulta: **wala ni mahitabo** kay laing butang ang
      nitumaw nga naghatag og buhaton (tan-awa ubos).

## Bag-ong butang: 16 tickets diay, dili 8 (Paul, Teams, 2026-09-16)

- [x] Si Paul nag-flag nga naay ~15 tickets nga assigned pero wala klaro nga
      na-track. Na-investigate: **16 ka tickets** diay sa Geidi-MCP (dili 8),
      ug ang 8 ka dugang (KB-01/02/05/06/09, CW-RET-02/03/04) **gi-create ug
      gi-assign ni Paul mismo karong adlawa** (01:52–03:24 AM UTC) — dili
      sayop sa pag-track, bag-o ra gyud sila. Gi-reply na kang Paul ang
      findings, gi-dugang na sa `../README.md` backlog isip "Newly
      discovered" section. Naghulat sa iyang steer sa priority.
- [x] Naa puy 14 ka laing tickets sa laing projects (IT-Quoter, geidi.ai-website/
      SEO, Phase3) — na-note ra, wala pa gi-detalye, separate sa Geidi-MCP work.

## Sa katapusan sa adlaw

- [x] I-update ang backlog table sa `../README.md`.
- [x] Kopyaha ang structure ani nga file ngadto sa `../2026-09-17/README.md`
      uban sa tinuod nga kahimtang, dili blind copy sa unchecked boxes.

**Status: CW-MCP-01 registered ug evidence posted; D-04, ang bag-ong 8
tickets, ug ang docs draft naghulat sa reply gikan kang Ivan/Evgeny/Paul/
Chris Jane — walay dugang buhaton karon nga dili maghulat.**


---

## Planning addendum ? all 16 tickets

Original completion log above is preserved. The items below are additional planning
work, not a reset of completed MCP setup or a claim that planning checks are complete.

# 2026-09-16 ? Week 1, working day 1/25

[Roadmap](../5-Semana-Plano.md) ? [16-ticket register](../README.md)

## Main focus: Baseline ug scope check

**Tickets:** CW-MCP-01; all 16

### Before starting

- [ ] Check current ticket status, access and dependency changes; do not repeat accepted work.
- [ ] Ayaw i-repeat ang completed Janus registration. D-04 export waits for approval.

### Buhaton karon

- [ ] Preserve completed MCP setup evidence; list all 16 tickets and request exact acceptance criteria, dependencies and priority from Paul.

### Expected output

Confirmed/local status list, access requests, effort estimate per ticket.

### End-of-day update

- [ ] Compare output against actual ticket acceptance criteria; attach evidence where authorized.
- [ ] Record actual progress below and update the register; incomplete work stays incomplete.
- [ ] If blocked, record owner/next action and move to an unblocked task in the roadmap.

Actual result: Pending execution.

Evidence: ?

Blocker / owner / next action: ?

Carry-over and effect on target date: ?
