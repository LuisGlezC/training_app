# Supabase setup

Supabase is the planned shared backend for coach and athlete accounts. The SQL
migration creates profiles, clubs, club memberships, assigned training
sessions, workout steps, athlete feedback, and private voice-note storage. Row
Level Security policies restrict access to club members, assigned athletes,
and their coaches.

## Create the project and database

1. Create a Supabase project in the Supabase Dashboard.
2. Open **SQL Editor** in that project.
3. Run the migrations in order, once each:
   - `migrations/202609230001_initial_schema.sql`
   - `migrations/202609230002_club_join_codes.sql`
   - `migrations/202609240001_club_join_requests_and_coaches.sql`
   - `migrations/202609240002_assign_cloud_sessions.sql`
   - `migrations/202609240003_training_voice_notes.sql`
   - `migrations/202609240004_wearable_activities.sql`
   - `migrations/202609240005_polar_backend_access.sql`
   - For an existing project, run only the migrations it does not have yet, in
     order. The final two files prepare wearable activity storage and the
     server-only Polar OAuth access helpers.
4. Keep the project URL and publishable key from the project's **Connect**
   panel. Do not use or share a `service_role` key in the mobile app.

## Configure the Flutter client

From the Flutter project directory, install the new package:

```powershell
& "C:\Users\luis5\develop\flutter\bin\flutter.bat" pub get
```

Start the app with the project's URL and publishable key:

```powershell
& "C:\Users\luis5\develop\flutter\bin\flutter.bat" run -d emulator-5554 `
  --dart-define="SUPABASE_URL=https://YOUR_PROJECT_REF.supabase.co" `
  --dart-define="SUPABASE_PUBLISHABLE_KEY=YOUR_PUBLISHABLE_KEY"
```

The values are supplied at build time and are not written into the repository.
The publishable key is intended for mobile clients; database access must still
be restricted by the migration's Row Level Security policies.

Without these values, the app continues to use its existing local SQLite data.
With them, the app supports Supabase sign-up/login, club creation, coach-reviewed
membership requests, multiple coaches per club, cloud training assignment,
shared completion reports, private athlete voice notes, and the protected data
tables for wearable connections and imported activity summaries. Provider OAuth
credentials are stored only in the `private` schema and must be accessed through
Supabase Edge Functions, never directly from Flutter. Imported activities are
private to the athlete until they are linked to an assigned session; then the
coaches allowed to see that session can also see its activity summary.
Existing memberships are preserved by the migrations. The sessions in the
original training screen and their feedback are still local to the device.

## Polar AccessLink Edge Functions

The Polar integration uses server-side OAuth and never returns access tokens to
the Flutter app. Register a Polar AccessLink client at
`https://admin.polaraccesslink.com` and set its redirect URL to:

```text
https://prlnznrdvfzhijhwddzh.supabase.co/functions/v1/polar-callback
```

Set `POLAR_CLIENT_ID`, `POLAR_CLIENT_SECRET`, and `POLAR_REDIRECT_URI` as Supabase
Edge Function secrets. Never commit them or put them in Flutter `--dart-define`
values. Supabase supplies its URL and service-role key to deployed functions.

Deploy from the Flutter project directory with the Supabase CLI:

```powershell
supabase functions deploy polar-connect --project-ref prlnznrdvfzhijhwddzh
supabase functions deploy polar-callback --project-ref prlnznrdvfzhijhwddzh
supabase functions deploy polar-sync --project-ref prlnznrdvfzhijhwddzh
supabase functions deploy polar-disconnect --project-ref prlnznrdvfzhijhwddzh
```

The athlete interface invokes `polar-connect` to check connection status and
start OAuth, `polar-sync` to import summaries, and `polar-disconnect` to revoke
access. The callback returns to the app using the `trainingapp://` URL scheme,
configured for Android and iOS. After updating the app or changing the
`polar-connect` GET status handler, redeploy the affected function. Polar
reports activities uploaded to Flow in the last 30 days and only after that
athlete has registered with this client. See the
[Polar AccessLink API documentation](https://www.polar.com/accesslink-api/).

## Garmin Connect Activity API

The activity schema already reserves `garmin` as a provider, but Garmin
authorization and importing are not enabled yet. Garmin's Activity API is a
cloud-to-cloud service, uses OAuth 2.0, and requires approval to join its
Developer Program. Garmin describes the program as intended for business or
enterprise integrations; approved developers can get an evaluation
environment. Review the [Activity API](https://developer.garmin.com/gc-developer-program/activity-api/),
[program overview](https://developer.garmin.com/gc-developer-program/overview/),
and [program FAQ](https://developer.garmin.com/gc-developer-program/program-faq/)
before requesting access. Do not add Garmin client credentials until the
application is approved and Garmin provides the integration details. Once
access is granted, implement its OAuth callback and activity delivery method
in Edge Functions, then normalize the approved activity fields into
`wearable_activities`.
