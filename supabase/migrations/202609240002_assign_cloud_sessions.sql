-- Atomically create a club training session and its optional workout steps.

create function public.assign_training_session(
  target_club_id uuid,
  target_athlete_id uuid,
  session_title text,
  session_description text,
  session_distance_meters integer,
  session_scheduled_at timestamptz,
  session_steps jsonb
)
returns uuid
language plpgsql
security definer
set search_path = ''
as $$
declare
  current_user_id uuid := auth.uid();
  new_session_id uuid;
  step_item jsonb;
  step_position integer := 0;
  step_title text;
  step_target text;
begin
  if current_user_id is null then
    raise exception 'You must sign in to assign a training session.';
  end if;

  if not private.is_club_coach(target_club_id) then
    raise exception 'Only a coach in this club can assign training.';
  end if;

  if not private.is_club_athlete(target_club_id, target_athlete_id) then
    raise exception 'Choose an athlete who belongs to this club.';
  end if;

  if session_title is null or length(trim(session_title)) = 0 then
    raise exception 'The training session needs a title.';
  end if;

  if session_distance_meters is not null and session_distance_meters <= 0 then
    raise exception 'Distance must be greater than zero.';
  end if;

  if session_scheduled_at is null then
    raise exception 'Choose a training date.';
  end if;

  if jsonb_typeof(coalesce(session_steps, '[]'::jsonb)) <> 'array' then
    raise exception 'Training steps must be provided as a list.';
  end if;

  insert into public.training_sessions (
    club_id,
    athlete_id,
    coach_id,
    title,
    description,
    distance_meters,
    scheduled_at
  )
  values (
    target_club_id,
    target_athlete_id,
    current_user_id,
    trim(session_title),
    coalesce(session_description, ''),
    session_distance_meters,
    session_scheduled_at
  )
  returning id into new_session_id;

  for step_item in
    select value
      from jsonb_array_elements(coalesce(session_steps, '[]'::jsonb)) as items(value)
  loop
    step_title := trim(coalesce(step_item ->> 'title', ''));
    step_target := trim(coalesce(step_item ->> 'target', ''));

    if step_title = '' or step_target = '' then
      raise exception 'Each step needs a title and a target.';
    end if;

    insert into public.training_steps (
      training_session_id,
      position,
      title,
      target,
      description
    )
    values (
      new_session_id,
      step_position,
      step_title,
      step_target,
      coalesce(step_item ->> 'description', '')
    );

    step_position := step_position + 1;
  end loop;

  return new_session_id;
end;
$$;

revoke all on function public.assign_training_session(
  uuid, uuid, text, text, integer, timestamptz, jsonb
) from public;
grant execute on function public.assign_training_session(
  uuid, uuid, text, text, integer, timestamptz, jsonb
) to authenticated;
