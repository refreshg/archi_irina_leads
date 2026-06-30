# archi_irina_leads

Archi CRM (Bitrix24) — export of leads that entered the **"ვერ დავუკავშირდი"** (couldn't-contact) stage.

Two ways to use it:
- **Web app (Vercel)** — open the deployed URL, pick a date range (defaults to yesterday), view the leads table and download Excel. Frontend: `public/index.html`; serverless API: `api/leads.js`.
- **PowerShell script** — run `archi_leads_export.ps1` locally (see below).

## Deploy (Vercel)
Import this repo into Vercel — zero config (static `public/` + `api/` serverless function). The root URL serves the page; the page calls `/api/leads`.

Optional environment variables (Vercel → Settings → Environment Variables):
- `BX_DEAL`, `BX_STATUS`, `BX_TIMELINE` — override the Bitrix webhook base URLs.
- `ACCESS_KEY` — if set, the API requires `?key=...` (the page has an "Access key" field). **Recommended**, since `/api/leads` otherwise returns client PII to anyone with the URL.

## What it does
`archi_leads_export.ps1` pulls deals from two pipelines and filters them by the date they **moved into** the "ვერ დავუკავშირდი" stage (using `crm.stagehistory.list`):

- Pipeline **0** (Sale Leads) → stage `7`
- Pipeline **35** (Hot Leads) → stage `C35:FINAL_INVOICE`

For each matching deal it exports: **type (Hot/Sale)**, client (name + phone, from the attached contact/company), FB Name (campaign), pipeline, creation date, the move-into-stage date, the **current** stage, and the **last timeline comment**.

Output: a hand-built `.xlsx` (OpenXML, UTF-8) and a `.csv` (UTF-8). Live progress is shown while loading.

## Usage
```powershell
# default = yesterday, full day
& '.\archi_leads_export.ps1'

# custom range
& '.\archi_leads_export.ps1' -DateFrom '2026-06-01T00:00:00' -DateTo '2026-06-30T23:59:59'
```

## Validation
The script prints a validation report: confirms every exported row's move-time is inside the range, shows the current-stage distribution (deals may have moved on), and prints the full stage history of 3 sample deals as proof that the "ვერ დავუკავშირდი" entry lands in the selected range.

## APIs used
- `crm.stagehistory.list` — date of move into stage (filtering basis)
- `crm.deal.list` — current stage, title, client refs, create date
- `crm.status.list` — stage-name resolution per pipeline
- `crm.contact.list` / `crm.company.list` — client names/phones
- `crm.timeline.comment.list` (batched) — last comment

> Note: the webhook URLs in the script are live credentials with CRM access.
