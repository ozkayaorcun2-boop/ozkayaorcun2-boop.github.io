-- Studio Desk automatic TikTok sync queue
-- Run this after supabase-schema.sql in Supabase SQL Editor.
-- This file intentionally contains no real API keys or project secrets.

create extension if not exists pg_cron with schema pg_catalog;
create extension if not exists pg_net with schema extensions;

create table if not exists public.tiktok_sync_queue (
  id uuid primary key default gen_random_uuid(),
  owner_id uuid not null references auth.users(id) on delete cascade,
  account_id text not null,
  username text not null,
  job_type text not null check (job_type in ('profile', 'posts')),
  status text not null default 'pending' check (status in ('pending', 'processing', 'done', 'failed')),
  attempts integer not null default 0,
  requested_by text not null default 'manual' check (requested_by in ('manual', 'daily')),
  run_id uuid not null,
  batch_key text not null,
  run_after timestamptz not null default now(),
  created_at timestamptz not null default now(),
  started_at timestamptz,
  finished_at timestamptz,
  last_error text,
  result_meta jsonb not null default '{}'::jsonb,
  unique (owner_id, account_id, job_type, batch_key)
);

create index if not exists tiktok_sync_queue_pending_idx
  on public.tiktok_sync_queue(status, run_after, created_at)
  where status = 'pending';
create index if not exists tiktok_sync_queue_owner_idx
  on public.tiktok_sync_queue(owner_id, created_at desc);

alter table public.tiktok_sync_queue enable row level security;
revoke all on public.tiktok_sync_queue from anon;
grant select on public.tiktok_sync_queue to authenticated;

drop policy if exists "Users can read their own TikTok sync jobs" on public.tiktok_sync_queue;
create policy "Users can read their own TikTok sync jobs"
  on public.tiktok_sync_queue for select to authenticated
  using (auth.uid() = owner_id);

-- Only the backend service role may claim work. SKIP LOCKED prevents two workers
-- from processing the same job if invocations overlap.
create or replace function public.claim_next_tiktok_sync_job()
returns setof public.tiktok_sync_queue
language plpgsql
security definer
set search_path = ''
as $$
begin
  return query
  with candidate as (
    select q.id
    from public.tiktok_sync_queue as q
    where q.status = 'pending' and q.run_after <= now()
    order by q.created_at asc
    for update skip locked
    limit 1
  )
  update public.tiktok_sync_queue as q
  set status = 'processing', attempts = q.attempts + 1, started_at = now(), last_error = null
  from candidate
  where q.id = candidate.id
  returning q.*;
end;
$$;

revoke all on function public.claim_next_tiktok_sync_job() from public, anon, authenticated;
grant execute on function public.claim_next_tiktok_sync_job() to service_role;

-- Scheduled functions require three values in Supabase Vault:
--   studio_project_url          = https://YOUR-PROJECT-REF.supabase.co
--   studio_supabase_secret_key  = Supabase secret key (or legacy service_role key)
--   studio_sync_cron_secret     = the same random value as the SYNC_CRON_SECRET
--                                 Edge Function secret
-- Create these via Vault before running the schedule statements below.
-- For example (replace placeholders; run only once):
-- select vault.create_secret('https://YOUR-PROJECT-REF.supabase.co', 'studio_project_url');
-- select vault.create_secret('YOUR_SUPABASE_SECRET_OR_SERVICE_ROLE_KEY', 'studio_supabase_secret_key');
-- select vault.create_secret('REPLACE_WITH_THE_SAME_LONG_RANDOM_SECRET', 'studio_sync_cron_secret');

-- One provider request every two minutes, staying under Sociflux's currently
-- advertised Free-plan limit of 1 request/minute. A five-account full refresh
-- uses ten requests and therefore takes about twenty minutes.
select cron.schedule(
  'studio-tiktok-sync-worker',
  '*/2 * * * *',
  $$
  select net.http_post(
    url := (select decrypted_secret from vault.decrypted_secrets where name = 'studio_project_url') || '/functions/v1/tiktok-sync-worker',
    headers := jsonb_build_object(
      'Content-Type', 'application/json',
      'apikey', (select decrypted_secret from vault.decrypted_secrets where name = 'studio_supabase_secret_key'),
      'x-sync-secret', (select decrypted_secret from vault.decrypted_secrets where name = 'studio_sync_cron_secret')
    ),
    body := '{}'::jsonb,
    timeout_milliseconds := 10000
  ) as request_id;
  $$
);

-- Queue a daily refresh of every account with a valid username at 00:10 UTC.
select cron.schedule(
  'studio-tiktok-sync-daily-scheduler',
  '10 0 * * *',
  $$
  select net.http_post(
    url := (select decrypted_secret from vault.decrypted_secrets where name = 'studio_project_url') || '/functions/v1/tiktok-sync-scheduler',
    headers := jsonb_build_object(
      'Content-Type', 'application/json',
      'apikey', (select decrypted_secret from vault.decrypted_secrets where name = 'studio_supabase_secret_key'),
      'x-sync-secret', (select decrypted_secret from vault.decrypted_secrets where name = 'studio_sync_cron_secret')
    ),
    body := '{}'::jsonb,
    timeout_milliseconds := 10000
  ) as request_id;
  $$
);
