# Studio Desk — TikTok Agency Workspace

A static HTML/CSS/JavaScript dashboard that can be hosted from a GitHub Pages repository. Workspace records live in Supabase Postgres; the browser stores only the signed-in Supabase authentication session. Optional TikTok public-metric syncing runs in Supabase Edge Functions, so your computer does not need to stay on.

## Package contents

- `index.html` — dashboard frontend
- `config.js` — the Supabase project URL and publishable key (safe for frontend use when RLS is correctly configured)
- `supabase-schema.sql` — the main workspace table and user-level access policies
- `supabase-tiktok-sync.sql` — sync queue, row-level security, worker claim function, and cron schedules
- `supabase/config.toml` — Edge Function verification settings
- `supabase/functions/tiktok-sync-start/` — authenticated endpoint that queues a manual sync
- `supabase/functions/tiktok-sync-worker/` — server-side Sociflux requests and cloud metric updates
- `supabase/functions/tiktok-sync-scheduler/` — queues a daily refresh for accounts with usernames
- `video-import-template.csv` — optional manual import template

## What the website does

- People folders, TikTok account records, content lists, notes, warm-up checklists and calculated analytics
- Shared cloud workspace tied to the signed-in Supabase user
- CSV/JSON import, CSV export and JSON workspace backup/restore
- Sociflux-powered public TikTok profile and recent-post sync after the backend setup below
- Manual sync button in the dashboard and per-account view
- Daily cloud sync for configured account usernames
- API tokens stored on the server, not in GitHub Pages JavaScript

Automatic sync is **not active until you deploy the functions and add your own secrets**. No API key is included in this package.

## 1. Create the Supabase database

1. Create a project at [Supabase](https://supabase.com/).
2. Open **SQL Editor** and run the full `supabase-schema.sql` file.
3. Create an agency login under **Authentication → Users**.
4. Copy the project URL and the publishable key (older projects may call this the `anon` key). Put them in `config.js`:

   ```js
   window.STUDIO_CONFIG = {
     supabaseUrl: "https://YOUR-PROJECT.supabase.co",
     supabasePublishableKey: "YOUR-PUBLISHABLE-OR-ANON-KEY"
   };
   ```

The publishable key is intended to be public. The `service_role`/secret key is not.

## 2. Set up the Sociflux API key

1. Visit [Sociflux](https://sociflux.com/), create an account, and create an API key in its console.
2. Create a long random secret for the internal cron-to-function calls. Example command if Node.js is installed:

   ```sh
   node -e "console.log(require('crypto').randomBytes(32).toString('hex'))"
   ```

3. Install the [Supabase CLI](https://supabase.com/docs/guides/cli) and, from the extracted Studio Desk folder, run:

   ```sh
   supabase login
   supabase link --project-ref YOUR_PROJECT_REF
   supabase secrets set SOCIFLUX_API_KEY=YOUR_SOCIFLUX_KEY SYNC_CRON_SECRET=YOUR_LONG_RANDOM_SECRET
   ```

   Replace the placeholder values with your real values. Never commit them to GitHub, place them in `config.js`, or paste them into frontend JavaScript.

## 3. Deploy the three Supabase functions

Run these commands from the folder that contains the `supabase/` directory:

```sh
supabase functions deploy tiktok-sync-start
supabase functions deploy tiktok-sync-worker
supabase functions deploy tiktok-sync-scheduler
```

The included `supabase/config.toml` keeps the manual start endpoint authenticated and disables built-in JWT verification only for the two internal cron endpoints. Those endpoints independently require the private `x-sync-secret` value.

## 4. Set up the sync queue and scheduled jobs

1. In Supabase **Vault**, create three secrets with these exact names:
   - `studio_project_url` — your Supabase project URL, e.g. `https://YOUR-PROJECT-REF.supabase.co`
   - `studio_supabase_secret_key` — your project secret API key (or legacy `service_role` key); this is private and is only used by the scheduled HTTP request
   - `studio_sync_cron_secret` — the same random value you set as `SYNC_CRON_SECRET` in the Edge Function secrets
2. You can create the Vault secrets through the Supabase interface if available. Alternatively, the SQL examples near the bottom of `supabase-tiktok-sync.sql` use `vault.create_secret(...)`; replace all three placeholders with your values and run those statements in SQL Editor.
3. Run the full `supabase-tiktok-sync.sql` in SQL Editor after the Vault secrets exist. It creates the queue and schedules the queue worker every two minutes and daily enqueue at 00:10 UTC.

**Secret safety:** do not commit a modified SQL file containing real secrets. If you add Vault secrets through SQL Editor, avoid saving the populated query in a public repository. You can safely upload the unmodified SQL template to GitHub.

If you rerun the sync SQL, check **Integrations → Cron** for duplicate jobs; remove any duplicate `studio-tiktok-sync-worker` or `studio-tiktok-sync-daily-scheduler` jobs.

## 5. Publish the website on GitHub Pages

1. Upload the contents of the package to the root of your repository. Make sure `index.html` and `config.js` are at the repository root.
2. Keep the `supabase/` folder in your local working copy so you can deploy functions later; the functions don't need to be served by GitHub Pages.
3. In the repository, open **Settings → Pages**, choose **Deploy from a branch**, select `main` and `/(root)`, and save.
4. Open the published page and sign in using the Supabase agency user you created.
5. Add the TikTok username to each account's **Edit account** form. The username field should be just `username` or `@username`.
6. Click **Sync TikTok** for all configured accounts, or **Sync now** inside a specific account. The cloud queue processes requests over time; close the browser if you need to—the worker runs in Supabase.

## Provider, quota and data notes

Sociflux documents these endpoints:

- `GET https://api.sociflux.com/v1/tiktok/profile?username=...`
- `GET https://api.sociflux.com/v1/tiktok/posts?username=...&count=30`

The worker uses one profile call and one recent-post call per account. Profile snapshots include public follower/following/post/like totals where returned. Recent post metrics include views, likes, comments, shares, caption, URL, date and duration where available. It does **not** provide private Creator Analytics such as retention or private audience breakdowns.

Sociflux currently advertises a free quota of 500 API calls/month and a 1-request/minute rate limit; the site also references a three-account monitoring cap and labels the service as beta/open testing. Its docs currently say the open beta's free period runs until November 1, 2026, with provider-side data reset at launch. These terms may change. Confirm current plan and terms in your own account before relying on this, especially for five accounts. A five-account refresh uses ten API calls and is queued at about one request every two minutes. Daily refreshes alone would use about 300 calls per 30-day month, leaving limited room for manual refreshes under a 500-call allowance. If the provider limits your account to three tracked accounts, some of the five channels may need a plan change or different data provider.

This provider returns public platform data; it is not a TikTok-authorized Creator Analytics API. Third-party public-data integrations can stop working or change their access methods. Review provider rules and the TikTok terms that apply to your accounts before enabling unattended collection. Don't use these metrics to imply access to private account insights.

## Data persistence and privacy

- People, accounts, checklists, videos and sync results are saved to Supabase Postgres. They are not newly saved to browser `localStorage`.
- The frontend may read the older Studio Desk local-storage keys once to offer migration into an empty cloud workspace. After a successful cloud load/migration, those legacy keys are removed.
- The Supabase publishable key is public by design and is safe only with the included row-level security rules.
- Never add a Supabase `service_role` key, `SOCIFLUX_API_KEY`, `SYNC_CRON_SECRET`, or other private credential to frontend files or GitHub.
- This version gives one signed-in Supabase user a private workspace. To grant different team members access to the same agency workspace, add an agency-membership model and policies first; don't share the owner's login casually.

## Useful links

- [Sociflux API documentation](https://sociflux.com/docs)
- [Sociflux pricing](https://sociflux.com/pricing)
- [Supabase Edge Functions](https://supabase.com/docs/guides/functions)
- [Supabase scheduled Edge Functions](https://supabase.com/docs/guides/functions/schedule-functions)
- [Supabase Row Level Security](https://supabase.com/docs/guides/database/postgres/row-level-security)
- [GitHub Pages documentation](https://docs.github.com/en/pages)
