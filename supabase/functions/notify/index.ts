// Sends a web push to every device a psst user turned notifications on for.
// Called by the messages_notify database trigger with a shared secret.
import "jsr:@supabase/functions-js/edge-runtime.d.ts";
import { createClient } from "npm:@supabase/supabase-js@2.45.4";
import webpush from "npm:web-push@3.6.7";

const db = createClient(Deno.env.get("SUPABASE_URL")!, Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!, {
  auth: { persistSession: false },
});

let cfg: { vapid_public: string; vapid_private: string; hook_secret: string } | null = null;
async function config() {
  if (cfg) return cfg;
  const { data, error } = await db.from("app_config").select("vapid_public, vapid_private, hook_secret").eq("id", 1).single();
  if (error) throw error;
  cfg = data;
  webpush.setVapidDetails("https://sendpsst.vercel.app", data.vapid_public, data.vapid_private);
  return cfg;
}

const LINES: Record<string, string> = {
  messages: "someone sent you an anonymous message 👀",
  tbh: "someone told you tbh 👀",
  nhie: "new never have i ever 🙈",
  confess: "someone confessed something 🤐",
  words: "someone described you in 3 words ✍️",
  rate: "someone rated you ⭐",
  shoot: "someone shot their shot 💘",
  ama: "someone asked you something 💬",
  flags: "someone sent you a red or green flag 🚩",
};

Deno.serve(async (req) => {
  try {
    const c = await config();
    if (req.headers.get("x-psst-secret") !== c.hook_secret) return new Response("no", { status: 401 });
    const { user_id, game } = await req.json();
    const { data: subs } = await db.from("push_subs").select("endpoint, sub").eq("user_id", user_id);
    const payload = JSON.stringify({ title: "psst 🤫", body: LINES[game] ?? LINES.messages, url: "/" });
    let sent = 0;
    await Promise.all((subs ?? []).map(async (s) => {
      try { await webpush.sendNotification(s.sub, payload, { TTL: 86400, urgency: "high" }); sent++; }
      catch (e) {
        const code = (e as { statusCode?: number }).statusCode;
        if (code === 404 || code === 410) await db.from("push_subs").delete().eq("endpoint", s.endpoint);
      }
    }));
    return new Response(JSON.stringify({ sent }), { headers: { "Content-Type": "application/json" } });
  } catch (e) {
    return new Response(String(e), { status: 500 });
  }
});
