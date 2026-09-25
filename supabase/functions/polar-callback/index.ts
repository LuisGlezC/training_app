import { createClient } from "npm:@supabase/supabase-js@2";
import { sha256Hex } from "../_shared/http.ts";

const appReturnUrl = "trainingapp://polar-connected";

function resultPage(success: boolean, message: string): Response {
  const status = success ? "connected" : "error";
  const target = `${appReturnUrl}?status=${status}`;
  const title = success ? "Polar conectado" : "No se pudo conectar Polar";
  const safeMessage = message.replace(/[<>&"']/g, "");
  return new Response(`<!doctype html><html lang="es"><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1"><title>${title}</title><body style="font:16px system-ui;max-width:32rem;margin:12vh auto;padding:1.5rem;color:#183432"><h1>${title}</h1><p>${safeMessage}</p><p><a href="${target}">Volver a Training App</a></p><script>setTimeout(()=>location.replace(${JSON.stringify(target)}),700)</script></body></html>`, {
    status: success ? 200 : 400,
    headers: { "Content-Type": "text/html; charset=utf-8", "Cache-Control": "no-store" },
  });
}

Deno.serve(async (request: Request) => {
  if (request.method !== "GET") return new Response("Method not allowed.", { status: 405 });
  const callbackUrl = new URL(request.url);
  const code = callbackUrl.searchParams.get("code");
  const state = callbackUrl.searchParams.get("state");
  const providerError = callbackUrl.searchParams.get("error");
  if (!state) return resultPage(false, "Falta el estado de autorización. Vuelve a intentarlo desde la app.");

  const supabaseUrl = Deno.env.get("SUPABASE_URL");
  const serviceRoleKey = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY");
  const clientId = Deno.env.get("POLAR_CLIENT_ID");
  const clientSecret = Deno.env.get("POLAR_CLIENT_SECRET");
  const redirectUri = Deno.env.get("POLAR_REDIRECT_URI");
  if (!supabaseUrl || !serviceRoleKey || !clientId || !clientSecret || !redirectUri) {
    return resultPage(false, "La integración aún no está configurada en el servidor.");
  }

  const admin = createClient(supabaseUrl, serviceRoleKey, {
    auth: { persistSession: false, autoRefreshToken: false },
  });
  const { data: oauthState, error: stateError } = await admin.rpc("consume_provider_oauth_state", {
    target_state_hash: await sha256Hex(state),
  });
  const stateRow = Array.isArray(oauthState) ? oauthState[0] : null;
  if (stateError || !stateRow || stateRow.provider !== "polar") {
    return resultPage(false, "La solicitud expiró o ya fue utilizada. Vuelve a iniciar la conexión.");
  }
  if (providerError || !code) {
    return resultPage(false, "No se autorizó el acceso a Polar. Puedes intentarlo de nuevo desde la app.");
  }

  try {
    const form = new URLSearchParams({ grant_type: "authorization_code", code, redirect_uri: redirectUri });
    const tokenResponse = await fetch("https://polarremote.com/v2/oauth2/token", {
      method: "POST",
      headers: {
        "Authorization": `Basic ${btoa(`${clientId}:${clientSecret}`)}`,
        "Content-Type": "application/x-www-form-urlencoded",
        "Accept": "application/json;charset=UTF-8",
      },
      body: form,
    });
    const token = await tokenResponse.json();
    if (!tokenResponse.ok || typeof token.access_token !== "string") {
      console.error("Polar token exchange failed with status", tokenResponse.status);
      return resultPage(false, "Polar no pudo completar la autorización. Vuelve a intentarlo.");
    }

    const registerResponse = await fetch("https://www.polaraccesslink.com/v3/users", {
      method: "POST",
      headers: {
        "Authorization": `Bearer ${token.access_token}`,
        "Content-Type": "application/json",
        "Accept": "application/json",
      },
      body: JSON.stringify({ "member-id": stateRow.user_id }),
    });
    let polarUserId = token.x_user_id == null ? null : String(token.x_user_id);
    if (registerResponse.ok) {
      const registration = await registerResponse.json();
      if (registration["polar-user-id"] != null) polarUserId = String(registration["polar-user-id"]);
    } else if (registerResponse.status !== 409) {
      console.error("Polar user registration failed with status", registerResponse.status);
      return resultPage(false, "Polar autorizó la cuenta, pero no se pudo registrar. Vuelve a intentarlo.");
    }

    const expiresAt = Number.isFinite(Number(token.expires_in))
      ? new Date(Date.now() + Number(token.expires_in) * 1000).toISOString()
      : null;
    const { error: saveError } = await admin.rpc("save_provider_connection", {
      target_user_id: stateRow.user_id,
      target_provider: "polar",
      target_provider_user_id: polarUserId,
      target_access_token: token.access_token,
      target_refresh_token: token.refresh_token ?? null,
      target_token_expires_at: expiresAt,
    });
    if (saveError) {
      console.error("Could not persist Polar connection:", saveError.message);
      return resultPage(false, "No se pudo guardar la conexión. Contacta al entrenador o inténtalo más tarde.");
    }
    return resultPage(true, "La cuenta Polar quedó vinculada. Ya puedes volver a la app.");
  } catch (error) {
    console.error("Polar callback failed:", error);
    return resultPage(false, "Ocurrió un problema de conexión con Polar. Vuelve a intentarlo.");
  }
});
