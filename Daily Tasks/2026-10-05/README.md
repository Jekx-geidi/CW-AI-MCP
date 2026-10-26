# 2026-10-05 ? Week 3, working day 14/25

[Roadmap](../5-Semana-Plano.md) ? [16-ticket register](../README.md)

## Main focus: Validate inventories; KB implementation

**Tickets:** D-13; D-14; D-16; KB-05

### Before starting

- [ ] Check current ticket status, access and dependency changes; do not repeat accepted work.
- [ ] Keep Oct 08 discovery deadlines ahead of optional KB expansion.

### Buhaton karon

- [ ] Validate owners/coverage across the three inventories; implement KB SSO, collections and metadata access rules.

### Expected output

Reviewed inventory rows; working KB configuration.

### End-of-day update

- [ ] Compare output against actual ticket acceptance criteria; attach evidence where authorized.
- [ ] Record actual progress below and update the register; incomplete work stays incomplete.
- [ ] If blocked, record owner/next action and move to an unblocked task in the roadmap.

Actual result (as of ~10AM): Wala nabuhat ang D-13/D-14/D-16 karong buntag; ang oras naadto sa KB-02 gate 4. Docker Desktop na-restart (patay ganina), Outline nagdagan na. Na-test ang duha ka Entra login: generic OIDC napakyas (walay `email_verified` gikan sa Entra); built-in Microsoft login na-block sa AADSTS50011 (redirect URI). Outline mismo OK (email/Mailhog login).

Evidence: Outline logs (`Your email address has not been verified by Geidi Entra`), Microsoft error AADSTS50011 screenshot, `TICKETS OVERVIEW/KB/KB #02 - INPROGR.md` update.

Blocker / owner / next action: Ivan: i-add ang `http://localhost:3100/auth/azure.callback` (message draft gihatag kang Riel para i-send). Nicko: KB-00 (GEIDIMCP-75) nag-block sa final GO ug KB-05.

Carry-over and effect on target date: KB-05 implementation (karong adlawa nga plano) dili pa masugdan, naghulat sa KB-02 + KB-00. D-13/D-14/D-16 validation carry-over.
