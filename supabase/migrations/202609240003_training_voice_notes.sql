-- Store athlete voice notes privately and grant access only to the athlete
-- assigned to the session and coaches in that athlete's club.

insert into storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
values (
  'training-voice-notes',
  'training-voice-notes',
  false,
  5242880,
  array['audio/mp4']::text[]
)
on conflict (id) do update
set public = false,
    file_size_limit = excluded.file_size_limit,
    allowed_mime_types = excluded.allowed_mime_types;

create policy athletes_upload_own_training_voice_notes
  on storage.objects for insert to authenticated
  with check (
    bucket_id = 'training-voice-notes'
    and exists (
      select 1
      from public.training_sessions as training_session
      where training_session.id::text = (storage.foldername(name))[1]
        and training_session.athlete_id = (select auth.uid())
        and private.can_submit_feedback(training_session.id)
    )
  );

create policy club_members_read_training_voice_notes
  on storage.objects for select to authenticated
  using (
    bucket_id = 'training-voice-notes'
    and exists (
      select 1
      from public.training_sessions as training_session
      where training_session.id::text = (storage.foldername(name))[1]
        and private.can_view_session(training_session.id)
    )
  );

create policy athletes_delete_own_training_voice_notes
  on storage.objects for delete to authenticated
  using (
    bucket_id = 'training-voice-notes'
    and exists (
      select 1
      from public.training_sessions as training_session
      where training_session.id::text = (storage.foldername(name))[1]
        and training_session.athlete_id = (select auth.uid())
        and private.can_submit_feedback(training_session.id)
    )
  );
