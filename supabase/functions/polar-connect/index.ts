import { createClient } from "npm:@supabase/supabase-js@2";
import { errorResponse, jsonResponse, randomToken, sha256Hex } from "../_shared/http.ts";

Deno.serve(async (request: Request) => {
  if (request.method === "OPTIONS") {
    return new Response("ok", { headers: {
      "Access-Control-Allow-Origin": "*",
      "Access-Control-Allow-Headers": "authorization, x-client-info, apikey, content-type",
      "Access-Control-Allow-Methods": "POST, OPTIONS",
    } });
  }
  if (request.method !== "POST" && request.method !== "GET") {
    return errorResponse("Method not allowed.", 405);
  }

  const authorization = request.headers.get("Authorization");
  if (!authorization?.startsWith("Bearer ")) return errorResponse("Sign in is required.", 401);

  const supabaseUrl = Deno.env.get("SUPABASE_URL");
  const anonKey = Deno.env.get("SUPABASE_ANON_KEY");
  const serviceRoleKey = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY");
  const clientId = Deno.env.get("POLAR_CLIENT_ID");
  const redirectUri = Deno.env.get("POLAR_REDIRECT_URI");
  if (!supabaseUrl || !anonKey || !serviceRoleKey || !clientId || !redirectUri) {
    return errorResponse("Polar is not configured on the server yet.", 503);
  }

  const userClient = createClient(supabaseUrl, anonKey, {
    global: { headers: { Authorization: authorization } },
    auth: { persistSession: false, autoRefreshToken: false },
  });
  const { data: { user }, error: authError } = await userClient.auth.getUser();
  if (authError || !user) return errorResponse("The session is invalid or expired.", 401);

  const state = randomToken();
  const stateHash = await sha256Hex(state);
  const admin = createClient(supabaseUrl, serviceRoleKey, {
    auth: { persistSession: false, autoRefreshToken: false },
  });
  if (request.method === "GET") {
    const { data, error } = await admin.rpc("get_provider_connection", {
      target_user_id: user.id,
      target_provider: "polar",
    });
    if (error) return errorResponse("Could not read the Polar connection.", 500);
    const connection = Array.isArray(data) ? data[0] : null;
    return jsonResponse({ connected: Boolean(connection?.access_token) });
  }

  const { error: stateError } = await admin.rpc("create_provider_oauth_state", {
    target_state_hash: stateHash,
    target_user_id: user.id,
    target_provider: "polar",
    target_expires_at: new Date(Date.now() + 10 * 60 * 1000).toISOString(),
  });
  if (stateError) return errorResponse("Could not start Polar authorization.", 500);

  const authorizationUrl = new URL("https://flow.polar.com/oauth2/authorization");
  authorizationUrl.searchParams.set("response_type", "code");
  authorizationUrl.searchParams.set("client_id", clientId);
  authorizationUrl.searchParams.set("redirect_uri", redirectUri);
  authorizationUrl.searchParams.set("scope", "accesslink.read_all");
  authorizationUrl.searchParams.set("state", state);
  return jsonResponse({ authorizationUrl: authorizationUrl.toString() });
});
