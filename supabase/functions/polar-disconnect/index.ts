import { createClient } from "npm:@supabase/supabase-js@2";
import { errorResponse, jsonResponse } from "../_shared/http.ts";

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
  if (!connection) return jsonResponse({ disconnected: true });

  if (connection.provider_user_id) {
    const revokeResponse = await fetch(
      `https://www.polaraccesslink.com/v3/users/${encodeURIComponent(connection.provider_user_id)}`,
      { method: "DELETE", headers: { "Authorization": `Bearer ${connection.access_token}` } },
    );
    if (!revokeResponse.ok && revokeResponse.status !== 404) {
      console.error("Polar token revocation failed with status", revokeResponse.status);
      return errorResponse("Polar did not revoke access. Try again later.", 502);
    }
  }
  const { error: deleteError } = await admin.rpc("delete_provider_connection", {
    target_user_id: user.id,
    target_provider: "polar",
  });
  if (deleteError) return errorResponse("Could not remove the saved Polar connection.", 500);
  return jsonResponse({ disconnected: true });
});
