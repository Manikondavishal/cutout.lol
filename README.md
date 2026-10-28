# cutout.lol

Fan war for Indian cinema. Most tickets wins. Tickets are free.

- `index.html` — the whole site (static). Talks to Supabase directly.
- `art/` — hero figurines (transparent WebP, 1050×1406).
- `supabase/schema.sql`, `supabase/seed.sql` — database setup (already run).
- Add `?demo` to the URL to see the simulated version without the database.

Deploy: Netlify → Import from GitHub → this repo. No build command, publish directory `.`.
Supabase: Authentication → Sign In / Providers → turn on **Allow anonymous sign-ins**.
