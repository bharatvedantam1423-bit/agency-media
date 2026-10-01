# Agency Media — Agency Signal

Finds what design agencies, studios and creative business owners post on social media, and which patterns actually perform. It runs by itself, costs nothing, and shows everything on one dashboard.

## How it works

```
Every minute      X + Instagram      ─┐   (fetched from the database server, gently)
Every 10 minutes  Bluesky, Mastodon,  ├─▶  Supabase: posts, growth snapshots, accounts
                  YouTube, hashtags  ─┘         │
                                                ├─ every 30 min: score each post vs its account's usual
Every 3 hours     Laya (GitHub Actions) ────────┤   (winner = 2× the account's median engagement)
                  reads each post: purpose,     ├─ every hour: winning patterns, trait combos,
                  hook, subject, CTA, slop      │   hot topics, promote newly found accounts
                                                ▼
                                   Agency Signal dashboard (Claude artifact)
```

**It finds accounts by itself.** When it reads an account, it also notes the people that account mentions, quotes or gets suggested alongside, plus authors posting under followed hashtags. Candidates whose bio looks like a designer, studio, agency or business owner get checked once. If they perform and Laya agrees they're relevant, they're promoted to the watchlist, which is capped at 150 accounts per platform. Hashtags that start trending get followed automatically.

**Laya does the reading.** Laya is a free, open-source model that answers typed questions. The questions use the same format as TypeSafe's Jev, so switching to Jev later is a one-line change. Before Laya has run, simple text rules still tag each post's hook, call to action and length, so the dashboard works from day one.

## What's in this repo

| Path | What it is |
|---|---|
| `supabase/sql/` | Database: tables, scoring, pattern engine, fetchers, schedules (run in order; `14_laya_focus.sql` is the agency/business-owner filter) |
| `supabase/functions/collect/` | Edge function that collects Bluesky, Mastodon and YouTube |
| `worker/laya_worker.py` | Laya tagging worker (runs in GitHub Actions or on any computer) |
| `.github/workflows/laya-tagging.yml` | Runs the worker every 3 hours, free |
| `dashboard/agency-signal.html` | Source of the dashboard page |

## Who it follows

Only **design agencies, studios, freelance designers and business owners** who sell design, branding, web or creative services. Laya reads each discovered account's bio and recent posts and picks one label: `agency`, `freelancer`, `business`, `product` (software, tools, template shops), `media` (news, events, inspiration, courses) or `other`.

- Only `agency`, `freelancer` and `business` accounts with relevance of at least 0.6 are promoted to the watchlist. Everything else is parked.
- Promotion needs Laya's verdict. Keyword matches in a bio are no longer enough, which is how software companies like Webflow used to get in.
- Patterns, combos and hot topics only use posts from seed/manual accounts and Laya-approved discovered accounts.
- Laya tags posts only for watched accounts, so CPU time isn't spent on parked ones.

## Turn on Laya (one-time, about 2 minutes)

The workflow (`.github/workflows/laya-tagging.yml`) must be on the repo's **default branch** for the schedule to run.

1. In Supabase, open **SQL Editor** and run:
   `select value from private.config where key = 'worker_token';`
   Copy the value.
2. In GitHub, open this repo → **Settings → Secrets and variables → Actions → New repository secret** and add one secret:
   - `LAYA_WORKER_TOKEN` = the value from step 1

   The project URL and publishable key are public by design and are already in the workflow.
3. Open **Actions → Laya tagging → Run workflow** once. The first run downloads the model (~2 minutes). After that it runs every 3 hours by itself. It classifies accounts first, then tags posts (about 6 seconds per post on CPU; a backlog drains over several runs).

The worker can also run on any computer or cloud machine:

```bash
pip install laya
export SUPABASE_URL=... SUPABASE_KEY=... LAYA_WORKER_TOKEN=...
python worker/laya_worker.py
```

## Limits to know

- **X** only shares each account's roughly 100 top posts publicly, and they're often older. That's good for evergreen patterns, but it isn't live.
- **Instagram** blocks public data for *business* profiles right now (a bug on Instagram's side). Personal profiles work, and business profiles are retried daily.
- **LinkedIn, Dribbble, Behance, Contra and Threads** block automated access without a login, so they aren't collected.
- These are unofficial public endpoints. The collector runs slowly on purpose, and any source can change without notice.

🤖 Generated with [Claude Code](https://claude.com/claude-code)
