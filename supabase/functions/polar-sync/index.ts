import { createClient } from "npm:@supabase/supabase-js@2";
import { errorResponse, jsonResponse } from "../_shared/http.ts";

function durationSeconds(value: unknown): number | null {
  if (typeof value !== "string") return null;
  const match = value.match(/^P(?:(\d+)D)?(?:T(?:(\d+)H)?(?:(\d+)M)?(?:(\d+(?:\.\d+)?)S)?)?$/);
  if (!match) return null;
  return Math.round((Number(match[1] ?? 0) * 86400) + (Number(match[2] ?? 0) * 3600) + (Number(match[3] ?? 0) * 60) + Number(match[4] ?? 0));
}

function utcStartTime(localValue: unknown, offsetValue: unknown): string | null {
  if (typeof localValue !== "string") return null;
  const local = new Date(`${localValue}Z`);
  if (!Number.isFinite(local.getTime())) return null;
  const offsetMinutes = Number(offsetValue ?? 0);
  return new Date(local.getTime() - offsetMinutes * 60_000).toISOString();
}

Deno.serve(async (request: Request) => {
  if (request.method === "OPTIONS") {
    return new Response("ok", { headers: {
      "Access-Control-Allow-Origin": "*",
      "Access-Control-Allow-Headers": "authorization, x-client-info, apikey, content-type",
      "Access-Control-Allow-Methods": "POST, OPTIONS",
    } });
  }
  if (request.method !== "POST") return errorResponse("Method not allowed.", 405);
  const authorization = request.headers.get("Authorization");
  if (!authorization?.startsWith("Bearer ")) return errorResponse("Sign in is required.", 401);

  const supabaseUrl = Deno.env.get("SUPABASE_URL");
  const anonKey = Deno.env.get("SUPABASE_ANON_KEY");
  const serviceRoleKey = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY");
  if (!supabaseUrl || !anonKey || !serviceRoleKey) return errorResponse("The server is not configured.", 503);

  const userClient = createClient(supabaseUrl, anonKey, {
    global: { headers: { Authorization: authorization } },
    auth: { persistSession: false, autoRefreshToken: false },
  });
  const { data: { user }, error: authError } = await userClient.auth.getUser();
  if (authError || !user) return errorResponse("The session is invalid or expired.", 401);

  const admin = createClient(supabaseUrl, serviceRoleKey, {
    auth: { persistSession: false, autoRefreshToken: false },
  });
  const { data: connections, error: connectionError } = await admin.rpc("get_provider_connection", {
    target_user_id: user.id,
    target_provider: "polar",
  });
  const connection = Array.isArray(connections) ? connections[0] : null;
  if (connectionError) return errorResponse("Could not read the Polar connection.", 500);
  if (!connection?.access_token) return errorResponse("Connect your Polar account first.", 409);

  try {
    const polarResponse = await fetch("https://www.polaraccesslink.com/v3/exercises", {
      headers: { "Authorization": `Bearer ${connection.access_token}`, "Accept": "application/json" },
    });
    if (polarResponse.status === 204) return jsonResponse({ imported: 0 });
    if (!polarResponse.ok) {
      console.error("Polar activity sync failed with status", polarResponse.status);
      return errorResponse(polarResponse.status === 403
        ? "Accept Polar's required data consents in Polar Flow, then try again."
        : "Polar could not return activities right now.", polarResponse.status === 403 ? 403 : 502);
    }

    const activities = await polarResponse.json();
    if (!Array.isArray(activities)) return errorResponse("Polar returned an unexpected activity response.", 502);
    const rows = activities.flatMap((activity: Record<string, unknown>) => {
      const startedAt = utcStartTime(activity.start_time, activity.start_time_utc_offset);
      if (typeof activity.id !== "string" || !startedAt) return [];
      const heartRate = activity.heart_rate as Record<string, unknown> | undefined;
      const sport = typeof activity.detailed_sport_info === "string"
        ? activity.detailed_sport_info
        : typeof activity.sport === "string" ? activity.sport : null;
      return [{
        athlete_id: user.id,
        provider: "polar",
        provider_activity_id: activity.id,
        title: sport ? `Polar · ${sport}` : "Entrenamiento Polar",
        sport,
        started_at: startedAt,
        duration_seconds: durationSeconds(activity.duration),
        distance_meters: typeof activity.distance === "number" ? activity.distance : null,
        average_heart_rate: typeof heartRate?.average === "number" ? heartRate.average : null,
        maximum_heart_rate: typeof heartRate?.maximum === "number" ? heartRate.maximum : null,
        calories: typeof activity.calories === "number" ? activity.calories : null,
      }];
    });

    if (rows.length === 0) return jsonResponse({ imported: 0 });
    const { error: saveError, count } = await admin
      .from("wearable_activities")
      .upsert(rows, {
        onConflict: "athlete_id,provider,provider_activity_id",
        ignoreDuplicates: true,
        count: "exact",
      });
    if (saveError) {
      console.error("Could not save imported activities:", saveError.message);
      return errorResponse("Polar activities were received but could not be saved.", 500);
    }
    return jsonResponse({ imported: count ?? rows.length });
  } catch (error) {
    console.error("Polar sync failed:", error);
    return errorResponse("Could not synchronize Polar activities right now.", 502);
  }
});
