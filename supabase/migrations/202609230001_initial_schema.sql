-- Shared data model for coaches, athletes, clubs, and assigned sessions.

create type public.club_role as enum ('coach', 'athlete');

create table public.profiles (
  user_id uuid primary key references auth.users (id) on delete cascade,
  display_name text not null default 'Atleta',
  created_at timestamptz not null default now()
);

create table public.clubs (
  id uuid primary key default gen_random_uuid(),
  name text not null check (length(trim(name)) > 0),
  coach_id uuid not null references public.profiles (user_id) on delete cascade,
  created_at timestamptz not null default now()
);

create table public.club_memberships (
  club_id uuid not null references public.clubs (id) on delete cascade,
  user_id uuid not null references public.profiles (user_id) on delete cascade,
  role public.club_role not null,
  joined_at timestamptz not null default now(),
  primary key (club_id, user_id)
);

create table public.training_sessions (
  id uuid primary key default gen_random_uuid(),
  club_id uuid not null references public.clubs (id) on delete cascade,
  athlete_id uuid not null references public.profiles (user_id) on delete cascade,
  coach_id uuid not null references public.profiles (user_id) on delete cascade,
  title text not null check (length(trim(title)) > 0),
  description text not null default '',
  distance_meters integer check (distance_meters is null or distance_meters > 0),
  scheduled_at timestamptz not null,
  created_at timestamptz not null default now()
);

create table public.training_steps (
  id uuid primary key default gen_random_uuid(),
  training_session_id uuid not null
    references public.training_sessions (id) on delete cascade,
  position integer not null check (position >= 0),
  title text not null,
  target text not null,
  description text not null default '',
  unique (training_session_id, position)
);

create table public.session_feedback (
  training_session_id uuid primary key
    references public.training_sessions (id) on delete cascade,
  athlete_id uuid not null references public.profiles (user_id) on delete cascade,
  effort_rating integer check (effort_rating between 1 and 10),
  feeling_note text,
  voice_note_path text,
  completed_at timestamptz,
  updated_at timestamptz not null default now()
);

create index training_sessions_athlete_schedule_idx
  on public.training_sessions (athlete_id, scheduled_at);
create index training_sessions_club_schedule_idx
  on public.training_sessions (club_id, scheduled_at);
create index club_memberships_user_idx
  on public.club_memberships (user_id, club_id);

create schema if not exists private;
revoke all on schema private from public;
grant usage on schema private to authenticated;

-- These security-definer helpers avoid recursive membership policies.
create function private.is_club_member(target_club_id uuid)
returns boolean
language sql
stable
security definer
set search_path = ''
as $$
  select exists (
    select 1
    from public.club_memberships as membership
    where membership.club_id = target_club_id
      and membership.user_id = (select auth.uid())
  );
$$;

create function private.is_club_coach(target_club_id uuid)
returns boolean
language sql
stable
security definer
set search_path = ''
as $$
  select exists (
    select 1
    from public.club_memberships as membership
    where membership.club_id = target_club_id
      and membership.user_id = (select auth.uid())
      and membership.role = 'coach'::public.club_role
  );
$$;

create function private.is_club_athlete(
  target_club_id uuid,
  target_user_id uuid
)
returns boolean
language sql
stable
security definer
set search_path = ''
as $$
  select exists (
    select 1
    from public.club_memberships as membership
    where membership.club_id = target_club_id
      and membership.user_id = target_user_id
      and membership.role = 'athlete'::public.club_role
  );
$$;

create function private.are_clubmates(target_user_id uuid)
returns boolean
language sql
stable
security definer
set search_path = ''
as $$
  select exists (
    select 1
    from public.club_memberships as viewer
    join public.club_memberships as other_member
      on other_member.club_id = viewer.club_id
    where viewer.user_id = (select auth.uid())
      and other_member.user_id = target_user_id
  );
$$;

create function private.can_view_session(target_session_id uuid)
returns boolean
language sql
stable
security definer
set search_path = ''
as $$
  select exists (
    select 1
    from public.training_sessions as training_session
    where training_session.id = target_session_id
      and (
        training_session.athlete_id = (select auth.uid())
        or private.is_club_coach(training_session.club_id)
      )
  );
$$;

create function private.can_manage_session(target_session_id uuid)
returns boolean
language sql
stable
security definer
set search_path = ''
as $$
  select exists (
    select 1
    from public.training_sessions as training_session
    where training_session.id = target_session_id
      and training_session.coach_id = (select auth.uid())
      and private.is_club_coach(training_session.club_id)
  );
$$;

create function private.can_submit_feedback(target_session_id uuid)
returns boolean
language sql
stable
security definer
set search_path = ''
as $$
  select exists (
    select 1
    from public.training_sessions as training_session
    where training_session.id = target_session_id
      and training_session.athlete_id = (select auth.uid())
  );
$$;

create function public.add_club_coach_membership()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
begin
  insert into public.club_memberships (club_id, user_id, role)
  values (new.id, new.coach_id, 'coach'::public.club_role);
  return new;
end;
$$;

-- Populate profiles if this migration is applied after users already exist.
insert into public.profiles (user_id, display_name)
select
  users.id,
  coalesce(
    nullif(users.raw_user_meta_data ->> 'display_name', ''),
    nullif(split_part(coalesce(users.email, ''), '@', 1), ''),
    'Atleta'
  )
from auth.users as users
on conflict (user_id) do nothing;

create trigger add_club_coach_membership_after_insert
after insert on public.clubs
for each row execute function public.add_club_coach_membership();

create function public.create_profile_for_new_user()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
begin
  insert into public.profiles (user_id, display_name)
  values (
    new.id,
    coalesce(
      nullif(new.raw_user_meta_data ->> 'display_name', ''),
      nullif(split_part(coalesce(new.email, ''), '@', 1), ''),
      'Atleta'
    )
  );
  return new;
end;
$$;

create trigger create_profile_after_signup
after insert on auth.users
for each row execute function public.create_profile_for_new_user();

alter table public.profiles enable row level security;
alter table public.clubs enable row level security;
alter table public.club_memberships enable row level security;
alter table public.training_sessions enable row level security;
alter table public.training_steps enable row level security;
alter table public.session_feedback enable row level security;

create policy profiles_read_self_and_clubmates
  on public.profiles for select to authenticated
  using (user_id = (select auth.uid()) or private.are_clubmates(user_id));
create policy profiles_update_self
  on public.profiles for update to authenticated
  using (user_id = (select auth.uid()))
  with check (user_id = (select auth.uid()));

create policy clubs_read_members
  on public.clubs for select to authenticated
  using (private.is_club_member(id));
create policy clubs_create_as_coach
  on public.clubs for insert to authenticated
  with check (coach_id = (select auth.uid()));
create policy clubs_update_coach
  on public.clubs for update to authenticated
  using (coach_id = (select auth.uid()) and private.is_club_coach(id))
  with check (coach_id = (select auth.uid()) and private.is_club_coach(id));
create policy clubs_delete_coach
  on public.clubs for delete to authenticated
  using (coach_id = (select auth.uid()) and private.is_club_coach(id));

create policy memberships_read_clubmates
  on public.club_memberships for select to authenticated
  using (private.are_clubmates(user_id));
create policy coaches_add_athletes
  on public.club_memberships for insert to authenticated
  with check (
    private.is_club_coach(club_id)
    and role = 'athlete'::public.club_role
    and user_id <> (select auth.uid())
  );
create policy members_leave_or_coaches_remove
  on public.club_memberships for delete to authenticated
  using (
    role = 'athlete'::public.club_role
    and (
      user_id = (select auth.uid())
      or private.is_club_coach(club_id)
    )
  );

create policy sessions_read_assigned_athlete_or_coach
  on public.training_sessions for select to authenticated
  using (
    athlete_id = (select auth.uid())
    or (
      coach_id = (select auth.uid())
      and private.is_club_coach(club_id)
    )
  );
create policy coaches_assign_sessions_to_club_athletes
  on public.training_sessions for insert to authenticated
  with check (
    coach_id = (select auth.uid())
    and private.is_club_coach(club_id)
    and private.is_club_athlete(club_id, athlete_id)
  );
create policy coaches_update_sessions
  on public.training_sessions for update to authenticated
  using (coach_id = (select auth.uid()) and private.is_club_coach(club_id))
  with check (
    coach_id = (select auth.uid())
    and private.is_club_coach(club_id)
    and private.is_club_athlete(club_id, athlete_id)
  );
create policy coaches_delete_sessions
  on public.training_sessions for delete to authenticated
  using (coach_id = (select auth.uid()) and private.is_club_coach(club_id));

create policy steps_read_session_members
  on public.training_steps for select to authenticated
  using (private.can_view_session(training_session_id));
create policy coaches_add_steps
  on public.training_steps for insert to authenticated
  with check (private.can_manage_session(training_session_id));
create policy coaches_update_steps
  on public.training_steps for update to authenticated
  using (private.can_manage_session(training_session_id))
  with check (private.can_manage_session(training_session_id));
create policy coaches_delete_steps
  on public.training_steps for delete to authenticated
  using (private.can_manage_session(training_session_id));

create policy feedback_read_athlete_and_coach
  on public.session_feedback for select to authenticated
  using (private.can_view_session(training_session_id));
create policy athletes_add_own_feedback
  on public.session_feedback for insert to authenticated
  with check (
    athlete_id = (select auth.uid())
    and private.can_submit_feedback(training_session_id)
  );
create policy athletes_update_own_feedback
  on public.session_feedback for update to authenticated
  using (
    athlete_id = (select auth.uid())
    and private.can_submit_feedback(training_session_id)
  )
  with check (
    athlete_id = (select auth.uid())
    and private.can_submit_feedback(training_session_id)
  );
create policy athletes_delete_own_feedback
  on public.session_feedback for delete to authenticated
  using (athlete_id = (select auth.uid()));

grant usage on schema public to authenticated;
grant usage on type public.club_role to authenticated;
grant select, update on public.profiles to authenticated;
grant select, insert, update, delete on public.clubs to authenticated;
grant select, insert, delete on public.club_memberships to authenticated;
grant select, insert, update, delete on public.training_sessions to authenticated;
grant select, insert, update, delete on public.training_steps to authenticated;
grant select, insert, update, delete on public.session_feedback to authenticated;

revoke all on function private.is_club_member(uuid) from public;
revoke all on function private.is_club_coach(uuid) from public;
revoke all on function private.is_club_athlete(uuid, uuid) from public;
revoke all on function private.are_clubmates(uuid) from public;
revoke all on function private.can_view_session(uuid) from public;
revoke all on function private.can_manage_session(uuid) from public;
revoke all on function private.can_submit_feedback(uuid) from public;
revoke all on function public.add_club_coach_membership() from public;
revoke all on function public.create_profile_for_new_user() from public;

grant execute on function private.is_club_member(uuid) to authenticated;
grant execute on function private.is_club_coach(uuid) to authenticated;
grant execute on function private.is_club_athlete(uuid, uuid) to authenticated;
grant execute on function private.are_clubmates(uuid) to authenticated;
grant execute on function private.can_view_session(uuid) to authenticated;
grant execute on function private.can_manage_session(uuid) to authenticated;
grant execute on function private.can_submit_feedback(uuid) to authenticated;
