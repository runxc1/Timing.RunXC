# timing.runXC.run

A near-zero-cost, offline-first PWA for timing cross-country meets. One phone at the
finish line taps a button for every runner that crosses; runners identify themselves
with a short code (generated as 4 characters, or any pre-printed 1–8 characters,
scanned from a QR sticker or typed in). Team scores
(classic top-5 with 6th-place tiebreaker) are computed automatically.

Hosting cost target: **$0/month** — static frontend on GitHub Pages + Supabase
free tier. No custom server.

## Features

- **Meet & race setup** — create a meet (admin code) and races, each with a short
  6-character race code for registration, timing, and results links.
- **Self-service registration** — athletes at `…/meet/<CODE>/signup` enter name, school
  (dropdown) and grade. Optionally pre-assign codes and print QR stickers.
- **QR sticker sheets** — client-side QR generation, print-ready sheet
  (`…/admin/races/<id>/stickers`), one sticker per athlete code.
- **Finish-line console** (`…/t/<CODE>`) — big START button, then one big FINISH tap
  per runner; scan the QR (camera) or type the code. Live finish-order board.
- **Offline-first** — every tap is written to IndexedDB (Dexie) and queued in an
  outbox; a background flusher syncs to Supabase with conflict-safe sequence
  renumbering. The console keeps working through a total network loss.
- **Finalize & results** — one-click finalize snapshots official finish times;
  results page shows individual places and team scores (top 5 score, 6th/7th push
  other teams, complete teams rank ahead of incomplete ones, tiebreaker by
  6th-runner time).
- **PWA** — installable, offline app shell, works on the phone at the finish line.

## Stack

| Layer      | Choice                                             |
| ---------- | -------------------------------------------------- |
| Frontend   | Vue 3 + TypeScript + Vite + Tailwind CSS v4 + PWA  |
| Local dev  | [aspire.love](https://aspire.love) (.NET Aspire AppHost) running the full Supabase stack in Docker |
| Backend    | Supabase (Postgres + RLS, PostgREST, GoTrue auth-less flows) |
| Hosting    | GitHub Pages (static) + Supabase free tier         |
| Scanner    | zxing-wasm (camera QR decoding, no server)         |

## Local development

Prerequisites: Node 20+, Docker, and the [Aspire CLI](https://aspire.dev)
(`dotnet tool install -g Aspire.Cli`).

```bash
npm install
aspire run            # from the repo root — starts Supabase stack + frontend
```

| Service            | URL                          |
| ------------------ | ---------------------------- |
| App (Vite)         | http://localhost:8088        |
| Supabase Studio    | http://localhost:54323       |
| Supabase API (Kong)| http://localhost:8000        |

Aspire injects `VITE_SUPABASE_URL` / `VITE_SUPABASE_PUBLISHABLE_KEY` into the
frontend. To run `npm run dev` without Aspire, copy `.env.example` to
`.env.local` and start the Supabase Docker stack yourself
(`supabase start` in a stock project works too).

Migrations live in `supabase/migrations/` and are applied automatically on first
boot of the Aspire stack.

### Verifying the data

To poke the API directly (curl/Postman), note that the local Kong gateway only
accepts the JWT Aspire generates — not the literal `local-dev-anon-key` found in
`aspire/infra/supabase/config/kong.yml` (Aspire replaces it at startup). Read the
live key with:

```bash
docker inspect runxctiming-supabase-kong --format "{{range .Config.Env}}{{println .}}{{end}}" | Select-String SUPABASE_ANON_KEY
```

`.env.example` ships a copy of it, and `aspire run` injects it into the app.
Alternatively bypass the gateway and hit PostgREST on `:57911` with a self-signed
HS256 JWT (secret `super-secret-jwt-token-with-at-least-32-characters-long`).

## Quality gates

```bash
npm run typecheck   # vue-tsc
npm test            # vitest (scoring engine, seq logic)
npm run build       # typecheck + production build to dist/
```

## How it works (short version)

- **Codes** — athlete codes are unique *within a meet*: generated ones are 4 chars
  from an unambiguous alphabet, and entry fields accept any pre-printed 1–8
  alphanumeric code (other meets may reuse the same code). QR stickers encode just
  the code; the scanner resolves it across the meet and flags wrong-division scans.
- **Ordering** — each FINISH tap stores a per-race monotonic `seq` plus the device
  clock. The outbox flusher retries durably; on a `(race_id, seq)` conflict it pulls
  the server's max seq and renumbers, so two devices (or a long offline stretch)
  never lose or reorder a finish.
- **Security** — Postgres RLS keys everything off the race/meet codes sent as
  headers (`X-Race-Code`, `X-Meet-Admin-Code`). No user accounts.
- **Scoring** — `finalize_race()` snapshots results server-side;
  `get_team_standings()` implements NFHS scoring (top 5, complete teams first,
  tiebreak on 6th-place time). A pure TypeScript mirror in `src/lib/scoring.ts`
  (unit-tested) renders results offline.

## Deploying (~$0/month)

Production is GitHub Pages (frontend, custom domain) + Supabase free tier
(data). Two GitHub Actions do everything; both are wired up in
`.github/workflows/`.

### 5-minute setup

1. **Create the repo & push**

   ```powershell
   git init -b main && git add . && git commit -m "timing.runXC.run"
   git remote add origin https://github.com/<you>/<repo>.git && git push -u origin main
   ```

2. **Create a Supabase project** at [supabase.com](https://supabase.com) (free
   tier is plenty). Grab these from the dashboard:
   - **URL + publishable anon key** — Project Settings → API Keys
   - **Project ref** — the id in `https://supabase.com/dashboard/project/<ref>/…`
     (the publish script remembers it after the first run)
   - *DB password* — Project Settings → Database. Not needed: the CLI connects
     through the management API with your access token.

3. **Publish migrations** — both paths are idempotent; new files in
   `supabase/migrations/` are applied in order and already-applied ones skipped.
   - Locally: `.\scripts\publish-supabase.ps1`. It asks for an access token
     (account avatar → Access tokens) **once** — `supabase login` stores it in
     your OS credential store — and remembers the project ref in
     `%LOCALAPPDATA%\runxc-timing\publish.json`, so from then on it just pushes.
     If you're already signed in to the Supabase CLI with one linked project,
     even the first run is prompt-free. Add `-DryRun` to see what would be
     applied, `-Forget` to drop the cached ref, or `-ProjectRef <ref>` to
     publish somewhere else once without touching the cache. Only the ref is
     written to disk — never a token or password.
   - From CI: add secret `SUPABASE_ACCESS_TOKEN` (and optionally variable
     `SUPABASE_PROJECT_REF`) under Settings → Secrets and variables → Actions,
     then run **Deploy Supabase migrations** manually. It runs the same script.

4. **Configure the Pages build** — add two repository **Variables** (same
   settings page, *Variables* tab; they're public values baked in at build):
   `VITE_SUPABASE_URL`, `VITE_SUPABASE_PUBLISHABLE_KEY`.

5. **Enable Pages**: Settings → Pages → Build and deployment → Source:
   **GitHub Actions**. From then on, every push to `main` (or a manual run of
   **Deploy Pages**) publishes the site.

6. **Custom domain** `timing.runXC.run`: add it under Settings → Pages →
   Custom domain (`public/CNAME` ships the same value). For an apex domain,
   point `A`/`AAAA` records at GitHub's `185.192.96.0/22` IPs (or use ALIAS if
   your DNS supports it); a `www`-style subdomain is a plain `CNAME` to
   `<you>.github.io`. Wait for "DNS configured", then tick **Enforce HTTPS**.

### SPA routing on GitHub Pages

GitHub Pages has no rewrite rules, so deep links like `/t/AB12CD` hit a 404.
`public/404.html` fixes that: it stores the requested URL and bounces to the
app root, where `src/lib/spaFallback.ts` replays it as the initial route.
(On Cloudflare/Netlify the same app uses `public/_redirects`, and an installed
PWA never hits either thanks to the Workbox navigation fallback.)

Note: the Vite build assumes the site is served from the **root** of its
domain — expected with the custom domain above. Serving from
`<you>.github.io/<repo>/` instead would require setting `base` in
`vite.config.ts` and the router base.

That's the whole production topology: static files + one Postgres.
Alternative static hosts (Cloudflare Pages/Netlify) work unchanged via
`npm run build` → publish `dist`.

## Project layout

```
src/
  views/        Home, MeetCreate, MeetDashboard, RaceSetup, Register,
                TimingConsole, Results, Stickers
  lib/          supabase.ts (clients), db.ts (Dexie), sync.ts (outbox),
                scoring.ts, liveQuery.ts, qr.ts
  components/   shared UI
supabase/migrations/   schema + RLS + RPCs (single init migration)
aspire/               AppHost (aspire.love) + local Supabase infra config
```

## Route map

| Route                        | Purpose                                  |
| ---------------------------- | ---------------------------------------- |
| `/`                          | Landing / open a meet                    |
| `/meets/new`                 | Create meet                              |
| `/admin`                     | All meets you administer (admin code)    |
| `/admin/:meetCode`           | Meet dashboard                           |
| `/admin/races/:raceId`       | Race setup                               |
| `/admin/races/:raceId/stickers` | Print QR stickers                     |
| `/admin/races/:raceId/compare` | Compare primary vs backup clocks       |
| `/meet/:meetCode/signup`     | Athlete registration                     |
| `/meet/:meetCode`            | Results                                  |
| `/t/:timerCode`              | Stopwatch timer console (splits only)    |
| `/scan/:scannerCode`         | Finish-line chute scanner (QR order)     |

The stopwatch timer and the code scanner are separate people: the timer taps
SPLIT per finisher, while chute crew scan/type athlete codes in finishing order
on `/scan/...`. A scan fills the oldest open split (official time stays with the
stopwatch); unknown codes keep their place as unclaimed placeholders with a
one-tap link to register that exact code.

The scanner console is built for loud finish lines: every read answers with a
chirp (recorded) or a buzz (look at the screen), muting on the header speaker
button. The camera preview is a small box under the code field and stays open,
so crew can scan sticker after sticker without re-opening anything; an instant
re-scan of the code that just landed is ignored as a double-tap.
