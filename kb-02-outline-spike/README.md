# KB-02 — Outline evaluation spike

Local, throwaway self-hosted Outline instance to verify the six gates in
GEIDIMCP-KB-02 before committing to Outline as the authoring UI.

## Run it

```
docker compose up -d
```

- App: http://localhost:3100
- Mailhog (catches sign-in emails, no real mail server needed): http://localhost:8025

## Log in

1. Go to http://localhost:3100 → "Continue with email"
2. Enter any email address (e.g. `you@geidi.com`) — nothing is actually sent out
3. Open http://localhost:8025, click the message that just arrived, click the
   sign-in link inside it (opens in the same browser)
4. First login creates the workspace/team automatically

## Known gotchas already hit and fixed here

- `NODE_ENV` must be `production` — the published Docker image has no Vite dev
  server bundled. `development` makes the page load unbuilt source files
  (`/static/app/index.tsx`, `@vite/client`) that this image can't serve, which
  renders as a blank/black screen.
- `PGSSLMODE=disable` is required — in production mode Sequelize defaults to
  requiring SSL, which the local Postgres container doesn't support.
- No sign-in method is configured out of the box (no SMTP, no OIDC) — nothing
  to click on the login page otherwise. Mailhog is wired in as SMTP_HOST so
  email magic-link works without a real mail account.

## Gate test plan

1. **Webhook on publish/update** — Settings → API & Apps → Webhooks. Create one
   pointed at a throwaway endpoint (e.g. https://webhook.site), publish/edit a
   test document, confirm the payload carries document id, collection id, and
   revision.
2. **API export to Markdown fidelity** — create a doc with a table, an image,
   and a callout block; export via API (`POST /api/documents.info` /
   `.export`) or the UI "Download as Markdown"; check tables/images/callouts
   survive round-trip.
3. **Attachments/images export** — confirm exported Markdown links resolve
   (either inline data or a stable attachment URL), not broken references.
4. **Entra SSO with collection-level permissions** — App registration
   issued by Ivan 2026-10-02 (client `ff0a9cd4-...`, consent granted, email
   claim added). Generic OIDC (`OIDC_*`, button "Geidi Entra") does NOT work
   with Entra: Entra never sends `email_verified`, and Outline's
   userProvisioner rejects unverified emails for any user that already exists
   ("Your email address has not been verified by Geidi Entra"). So `.env` now
   uses the built-in Azure plugin (`AZURE_*`, button "Microsoft"), which does
   not need that claim; the `OIDC_*` lines are kept commented out, and
   `.env.oidc-backup` holds the old OIDC-only config. The Azure plugin needs
   redirect URI `http://localhost:3100/auth/azure.callback` on the app
   registration — not yet added as of 2026-10-05 (Microsoft returns
   AADSTS50011). Once added: sign in with "Continue with Microsoft", then
   test collection permissions.
   - The "Email" sign-in button sends its magic link to Mailhog
     (http://localhost:8025), never to a real Outlook inbox.
   - If Docker Desktop shows "unable to start", kill the Docker processes,
     `wsl --shutdown`, relaunch Docker Desktop, then `docker compose up -d`.
5. **Custom attributes in self-hosted edition** — informational only; check
   Settings/API for any document metadata fields beyond title/tags. Geidi
   metadata stays in the Geidi layer regardless of the answer.
6. **Collection structure for client boundary** — create one collection per
   test "client" plus Global and Internal; confirm permissions can be scoped
   per collection without contortion.

Record evidence per gate on GEIDIMCP-67 (KB-02); decision rule is in the
ticket description (2+ failing gates → evaluate Docmost/BookStack before
considering a build).

## Tear down

```
docker compose down -v
```

(`-v` also drops the Postgres/Outline data volumes — this is a throwaway
instance, not meant to persist.)
