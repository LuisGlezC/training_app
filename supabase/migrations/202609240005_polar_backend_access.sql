-- Keep provider credentials in the private schema. Edge Functions call these
-- narrow RPCs with the service role; mobile clients cannot execute them.

create function public.create_provider_oauth_state(
  target_state_hash text,
  target_user_id uuid,
  target_provider text,
  target_expires_at timestamptz
)
returns void
language plpgsql
security definer
set search_path = ''
as $$
begin
  if (select auth.role()) <> 'service_role' then
    raise exception 'Service role is required.';
  end if;

  if target_provider not in ('polar', 'garmin') then
    raise exception 'Unsupported provider.';
  end if;

  delete from private.provider_oauth_states
  where expires_at <= now();

  insert into private.provider_oauth_states (
    state_hash, user_id, provider, expires_at
  )
  values (
    target_state_hash, target_user_id, target_provider, target_expires_at
  );
end;
$$;

create function public.consume_provider_oauth_state(target_state_hash text)
returns table (user_id uuid, provider text)
language plpgsql
security definer
set search_path = ''
as $$
begin
  if (select auth.role()) <> 'service_role' then
    raise exception 'Service role is required.';
  end if;

  return query
  delete from private.provider_oauth_states as oauth_state
  where oauth_state.state_hash = target_state_hash
    and oauth_state.expires_at > now()
  returning oauth_state.user_id, oauth_state.provider;
end;
$$;

create function public.get_provider_connection(
  target_user_id uuid,
  target_provider text
)
returns table (
  provider_user_id text,
  access_token text,
  refresh_token text,
  token_expires_at timestamptz
)
language plpgsql
security definer
set search_path = ''
as $$
begin
  if (select auth.role()) <> 'service_role' then
    raise exception 'Service role is required.';
  end if;

  return query
  select connection.provider_user_id,
         connection.access_token,
         connection.refresh_token,
         connection.token_expires_at
  from private.provider_connections as connection
  where connection.user_id = target_user_id
    and connection.provider = target_provider;
end;
$$;

create function public.save_provider_connection(
  target_user_id uuid,
  target_provider text,
  target_provider_user_id text,
  target_access_token text,
  target_refresh_token text,
  target_token_expires_at timestamptz
)
returns void
language plpgsql
security definer
set search_path = ''
as $$
begin
  if (select auth.role()) <> 'service_role' then
    raise exception 'Service role is required.';
  end if;

  if target_provider not in ('polar', 'garmin') then
    raise exception 'Unsupported provider.';
  end if;

  insert into private.provider_connections (
    user_id, provider, provider_user_id, access_token, refresh_token,
    token_expires_at, connected_at, updated_at
  )
  values (
    target_user_id, target_provider, target_provider_user_id,
    target_access_token, target_refresh_token, target_token_expires_at,
    now(), now()
  )
  on conflict (user_id, provider) do update
  set provider_user_id = excluded.provider_user_id,
      access_token = excluded.access_token,
      refresh_token = excluded.refresh_token,
      token_expires_at = excluded.token_expires_at,
      connected_at = now(),
      updated_at = now();
end;
$$;

create function public.delete_provider_connection(
  target_user_id uuid,
  target_provider text
)
returns void
language plpgsql
security definer
set search_path = ''
as $$
begin
  if (select auth.role()) <> 'service_role' then
    raise exception 'Service role is required.';
  end if;

  delete from private.provider_connections
  where user_id = target_user_id and provider = target_provider;
end;
$$;

revoke all on function public.create_provider_oauth_state(text, uuid, text, timestamptz)
  from public, anon, authenticated;
revoke all on function public.consume_provider_oauth_state(text)
  from public, anon, authenticated;
revoke all on function public.get_provider_connection(uuid, text)
  from public, anon, authenticated;
revoke all on function public.save_provider_connection(uuid, text, text, text, text, timestamptz)
  from public, anon, authenticated;
revoke all on function public.delete_provider_connection(uuid, text)
  from public, anon, authenticated;

grant execute on function public.create_provider_oauth_state(text, uuid, text, timestamptz)
  to service_role;
grant execute on function public.consume_provider_oauth_state(text)
  to service_role;
grant execute on function public.get_provider_connection(uuid, text)
  to service_role;
grant execute on function public.save_provider_connection(uuid, text, text, text, text, timestamptz)
  to service_role;
grant execute on function public.delete_provider_connection(uuid, text)
  to service_role;
