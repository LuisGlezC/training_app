-- Secure storage for connected wearable accounts and imported activity summaries.
-- OAuth credentials stay in the private schema and are only used by backend code.

create table private.provider_connections (
  user_id uuid not null references auth.users (id) on delete cascade,
  provider text not null check (provider in ('polar', 'garmin')),
  provider_user_id text,
  access_token text not null,
  refresh_token text,
  token_expires_at timestamptz,
  connected_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  primary key (user_id, provider)
);

create table private.provider_oauth_states (
  state_hash text primary key,
  user_id uuid not null references auth.users (id) on delete cascade,
  provider text not null check (provider in ('polar', 'garmin')),
  expires_at timestamptz not null,
  created_at timestamptz not null default now()
);

create index provider_oauth_states_expiry_idx
  on private.provider_oauth_states (expires_at);

alter table private.provider_connections enable row level security;
alter table private.provider_oauth_states enable row level security;

-- Authenticated clients must never read or write provider access credentials.
revoke all on table private.provider_connections from public, anon, authenticated;
revoke all on table private.provider_oauth_states from public, anon, authenticated;
grant usage on schema private to service_role;
grant select, insert, update, delete
  on table private.provider_connections, private.provider_oauth_states
  to service_role;

create table public.wearable_activities (
  id uuid primary key default gen_random_uuid(),
  athlete_id uuid not null references public.profiles (user_id) on delete cascade,
  provider text not null check (provider in ('polar', 'garmin')),
  provider_activity_id text not null,
  linked_training_session_id uuid references public.training_sessions (id)
    on delete set null,
  title text not null,
  sport text,
  started_at timestamptz not null,
  duration_seconds integer check (duration_seconds is null or duration_seconds >= 0),
  distance_meters numeric(12, 2)
    check (distance_meters is null or distance_meters >= 0),
  average_heart_rate integer
    check (average_heart_rate is null or average_heart_rate > 0),
  maximum_heart_rate integer
    check (maximum_heart_rate is null or maximum_heart_rate > 0),
  calories integer check (calories is null or calories >= 0),
  imported_at timestamptz not null default now(),
  unique (athlete_id, provider, provider_activity_id)
);

create index wearable_activities_athlete_started_idx
  on public.wearable_activities (athlete_id, started_at desc);
create index wearable_activities_session_idx
  on public.wearable_activities (linked_training_session_id)
  where linked_training_session_id is not null;

alter table public.wearable_activities enable row level security;

create policy athletes_and_session_coaches_read_activities
  on public.wearable_activities for select to authenticated
  using (
    athlete_id = (select auth.uid())
    or (
      linked_training_session_id is not null
      and private.can_view_session(linked_training_session_id)
    )
  );

create policy athletes_manage_own_activities
  on public.wearable_activities for all to authenticated
  using (athlete_id = (select auth.uid()))
  with check (
    athlete_id = (select auth.uid())
    and (
      linked_training_session_id is null
      or exists (
        select 1
        from public.training_sessions as assigned_session
        where assigned_session.id = linked_training_session_id
          and assigned_session.athlete_id = (select auth.uid())
      )
    )
  );

grant select, insert, update, delete on public.wearable_activities
  to authenticated;
grant select, insert, update, delete on public.wearable_activities
  to service_role;
