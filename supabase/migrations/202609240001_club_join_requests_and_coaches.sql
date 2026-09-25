-- Replace immediate club enrollment with coach-reviewed join requests.
-- An approved request can add either an athlete or another coach.

drop function if exists public.join_club_with_code(text);

create type public.club_request_status as enum (
  'pending',
  'approved',
  'rejected'
);

create table public.club_join_requests (
  id uuid primary key default gen_random_uuid(),
  club_id uuid not null references public.clubs (id) on delete cascade,
  user_id uuid not null references public.profiles (user_id) on delete cascade,
  requester_name text not null,
  club_name text not null,
  requested_role public.club_role not null,
  status public.club_request_status not null default 'pending',
  created_at timestamptz not null default now(),
  reviewed_at timestamptz,
  reviewed_by uuid references public.profiles (user_id) on delete set null,
  unique (club_id, user_id)
);

create index club_join_requests_club_status_idx
  on public.club_join_requests (club_id, status, created_at desc);
create index club_join_requests_user_idx
  on public.club_join_requests (user_id, created_at desc);

alter table public.club_join_requests enable row level security;

create policy club_requests_read_requester_and_coaches
  on public.club_join_requests for select to authenticated
  using (
    user_id = (select auth.uid())
    or private.is_club_coach(club_id)
  );

grant usage on type public.club_request_status to authenticated;
grant select on public.club_join_requests to authenticated;

create function private.is_club_coach_member(
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
       and membership.role = 'coach'::public.club_role
  );
$$;

revoke all on function private.is_club_coach_member(uuid, uuid) from public;
grant execute on function private.is_club_coach_member(uuid, uuid)
  to authenticated;

create function public.request_club_membership(
  invitation_code text,
  requested_role text
)
returns uuid
language plpgsql
security definer
set search_path = ''
as $$
declare
  current_user_id uuid := auth.uid();
  target_club public.clubs%rowtype;
  target_request_id uuid;
  requester_display_name text;
begin
  if current_user_id is null then
    raise exception 'You must sign in before requesting to join a club.';
  end if;

  if requested_role not in ('athlete', 'coach') then
    raise exception 'Choose either athlete or coach as the requested role.';
  end if;

  select club.*
    into target_club
    from public.clubs as club
   where club.join_code = upper(trim(invitation_code));

  if target_club.id is null then
    raise exception 'No club was found for that invitation code.';
  end if;

  if exists (
    select 1
      from public.club_memberships as membership
     where membership.club_id = target_club.id
       and membership.user_id = current_user_id
  ) then
    raise exception 'You are already a member of this club.';
  end if;

  select profile.display_name
    into requester_display_name
    from public.profiles as profile
   where profile.user_id = current_user_id;

  insert into public.club_join_requests (
    club_id,
    user_id,
    requester_name,
    club_name,
    requested_role
  )
  values (
    target_club.id,
    current_user_id,
    coalesce(requester_display_name, 'Usuario'),
    target_club.name,
    requested_role::public.club_role
  )
  on conflict (club_id, user_id) do update
    set requester_name = excluded.requester_name,
        club_name = excluded.club_name,
        requested_role = excluded.requested_role,
        status = 'pending'::public.club_request_status,
        created_at = now(),
        reviewed_at = null,
        reviewed_by = null
  returning id into target_request_id;

  return target_request_id;
end;
$$;

create function public.review_club_join_request(
  target_request_id uuid,
  accept_request boolean
)
returns public.club_request_status
language plpgsql
security definer
set search_path = ''
as $$
declare
  current_user_id uuid := auth.uid();
  target_request public.club_join_requests%rowtype;
  final_status public.club_request_status;
begin
  if current_user_id is null then
    raise exception 'You must sign in to review a club request.';
  end if;

  select request.*
    into target_request
    from public.club_join_requests as request
   where request.id = target_request_id
   for update;

  if target_request.id is null then
    raise exception 'Club request not found.';
  end if;

  if not private.is_club_coach(target_request.club_id) then
    raise exception 'Only a coach in this club can review requests.';
  end if;

  if target_request.status <> 'pending'::public.club_request_status then
    raise exception 'This request has already been reviewed.';
  end if;

  if accept_request then
    insert into public.club_memberships (club_id, user_id, role)
    values (
      target_request.club_id,
      target_request.user_id,
      target_request.requested_role
    )
    on conflict (club_id, user_id) do update
      set role = excluded.role;
    final_status := 'approved'::public.club_request_status;
  else
    final_status := 'rejected'::public.club_request_status;
  end if;

  update public.club_join_requests
     set status = final_status,
         reviewed_at = now(),
         reviewed_by = current_user_id
   where id = target_request.id;

  return final_status;
end;
$$;

revoke all on function public.request_club_membership(text, text)
  from public;
revoke all on function public.review_club_join_request(uuid, boolean)
  from public;
grant execute on function public.request_club_membership(text, text)
  to authenticated;
grant execute on function public.review_club_join_request(uuid, boolean)
  to authenticated;

-- All coaches in a club share access to its roster and training plan.
drop policy if exists clubs_update_coach on public.clubs;
create policy clubs_update_coach
  on public.clubs for update to authenticated
  using (private.is_club_coach(id))
  with check (
    private.is_club_coach(id)
    and private.is_club_coach_member(id, coach_id)
  );

drop policy if exists clubs_delete_coach on public.clubs;
create policy clubs_delete_coach
  on public.clubs for delete to authenticated
  using (
    coach_id = (select auth.uid())
    and private.is_club_coach(id)
  );

drop policy if exists sessions_read_assigned_athlete_or_coach
  on public.training_sessions;
create policy sessions_read_assigned_athlete_or_coach
  on public.training_sessions for select to authenticated
  using (
    athlete_id = (select auth.uid())
    or private.is_club_coach(club_id)
  );

drop policy if exists coaches_update_sessions on public.training_sessions;
create policy coaches_update_sessions
  on public.training_sessions for update to authenticated
  using (private.is_club_coach(club_id))
  with check (
    private.is_club_coach(club_id)
    and private.is_club_coach_member(club_id, coach_id)
    and private.is_club_athlete(club_id, athlete_id)
  );

drop policy if exists coaches_delete_sessions on public.training_sessions;
create policy coaches_delete_sessions
  on public.training_sessions for delete to authenticated
  using (private.is_club_coach(club_id));

create or replace function private.can_manage_session(target_session_id uuid)
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
       and private.is_club_coach(training_session.club_id)
  );
$$;
