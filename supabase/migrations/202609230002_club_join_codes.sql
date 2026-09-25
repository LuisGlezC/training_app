-- Adds shareable invitation codes and a safe way for athletes to join a club.

alter table public.clubs
  add column join_code text not null unique
  default upper(substr(replace(gen_random_uuid()::text, '-', ''), 1, 10));

create function public.join_club_with_code(invitation_code text)
returns uuid
language plpgsql
security definer
set search_path = ''
as $$
declare
  current_user_id uuid := auth.uid();
  target_club_id uuid;
begin
  if current_user_id is null then
    raise exception 'You must sign in before joining a club.';
  end if;

  select club.id
    into target_club_id
    from public.clubs as club
   where club.join_code = upper(trim(invitation_code));

  if target_club_id is null then
    raise exception 'No club was found for that invitation code.';
  end if;

  insert into public.club_memberships (club_id, user_id, role)
  values (target_club_id, current_user_id, 'athlete'::public.club_role)
  on conflict (club_id, user_id) do nothing;

  return target_club_id;
end;
$$;

revoke all on function public.join_club_with_code(text) from public;
grant execute on function public.join_club_with_code(text) to authenticated;
