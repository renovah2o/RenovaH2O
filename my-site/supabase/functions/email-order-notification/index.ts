import { createClient } from "npm:@supabase/supabase-js@2";

type WebhookPayload = {
  type?: string;
  table?: string;
  schema?: string;
  record?: {
    id?: string;
  };
};

const supabaseUrl = Deno.env.get("SUPABASE_URL");
const serviceRoleKey = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY");
const resendApiKey = Deno.env.get("RESEND_API_KEY");
const emailFrom = Deno.env.get("EMAIL_FROM");
const webhookSecret = Deno.env.get("EMAIL_WEBHOOK_SECRET");
const htmlEscapes: Record<string, string> = {
  "&": "&amp;",
  "<": "&lt;",
  ">": "&gt;",
  '"': "&quot;",
  "'": "&#39;"
};

function jsonResponse(body: Record<string, unknown>, status = 200) {
  return new Response(JSON.stringify(body), {
    status,
    headers: { "Content-Type": "application/json" }
  });
}

function escapeHtml(value: string) {
  return value.replace(/[&<>"']/g, character => htmlEscapes[character] ?? character);
}

Deno.serve(async request => {
  if (request.method !== "POST") {
    return jsonResponse({ error: "Method not allowed." }, 405);
  }

  if (!webhookSecret || request.headers.get("x-email-webhook-secret") !== webhookSecret) {
    return jsonResponse({ error: "Unauthorized." }, 401);
  }

  if (!supabaseUrl || !serviceRoleKey || !resendApiKey || !emailFrom) {
    console.error("Email notification function is missing required configuration.");
    return jsonResponse({ error: "Email service is not configured." }, 500);
  }

  let payload: WebhookPayload;
  try {
    payload = await request.json();
  } catch {
    return jsonResponse({ error: "Invalid JSON payload." }, 400);
  }

  if (
    payload.type !== "INSERT" ||
    payload.table !== "account_notifications" ||
    payload.schema !== "public" ||
    typeof payload.record?.id !== "string"
  ) {
    return jsonResponse({ error: "Unsupported database event." }, 400);
  }

  const supabase = createClient(supabaseUrl, serviceRoleKey, {
    auth: { autoRefreshToken: false, persistSession: false }
  });
  const { data: notification, error: notificationError } = await supabase
    .from("account_notifications")
    .select("id, user_id, order_id, title, message")
    .eq("id", payload.record.id)
    .maybeSingle();

  if (notificationError) {
    console.error("Could not load the account notification:", notificationError.message);
    return jsonResponse({ error: "Could not load the notification." }, 500);
  }
  if (!notification) return jsonResponse({ error: "Notification not found." }, 404);

  const { data: userResult, error: userError } = await supabase.auth.admin.getUserById(notification.user_id);
  if (userError) {
    console.error("Could not load the notification recipient:", userError.message);
    return jsonResponse({ error: "Could not load the notification recipient." }, 500);
  }

  const recipient = userResult.user?.email;
  if (!recipient) {
    console.error(`Notification ${notification.id} has no email recipient.`);
    return jsonResponse({ error: "Notification recipient has no email address." }, 422);
  }

  const { data: order, error: orderError } = notification.order_id
    ? await supabase.from("orders").select("user_id").eq("id", notification.order_id).maybeSingle()
    : { data: null, error: null };
  if (orderError) {
    console.error("Could not load the order recipient:", orderError.message);
    return jsonResponse({ error: "Could not load the order." }, 500);
  }

  const orderNumber = notification.order_id
    ? notification.order_id.slice(0, 8).toUpperCase()
    : null;
  const isCustomer = order?.user_id === notification.user_id;
  const accountUrl = isCustomer
    ? "https://renovah2o.com/cuenta#ordenes"
    : "https://renovah2o.com/cuenta#administrar-ordenes";
  const subject = orderNumber
    ? `${notification.title} · Orden ${orderNumber}`
    : notification.title;
  const safeTitle = escapeHtml(notification.title);
  const safeMessage = escapeHtml(notification.message);
  const orderReference = orderNumber
    ? `<p><strong>Orden:</strong> ${escapeHtml(orderNumber)}</p>`
    : "";
  const html = [
    `<h1>${safeTitle}</h1>`,
    `<p>${safeMessage.replace(/\n/g, "<br>")}</p>`,
    orderReference,
    `<p><a href="${accountUrl}">${isCustomer ? "Ver mis órdenes" : "Administrar órdenes"} en RenovaH2O</a></p>`
  ].join("");
  const text = [
    notification.title,
    notification.message,
    orderNumber ? `Orden: ${orderNumber}` : "",
    `Consulta tu cuenta: ${accountUrl}`
  ].filter(Boolean).join("\n\n");

  const response = await fetch("https://api.resend.com/emails", {
    method: "POST",
    headers: {
      "Authorization": `Bearer ${resendApiKey}`,
      "Content-Type": "application/json",
      "Idempotency-Key": `account-notification-${notification.id}`
    },
    body: JSON.stringify({
      from: emailFrom,
      to: [recipient],
      subject,
      html,
      text,
      tags: [
        { name: "notification_id", value: notification.id },
        { name: "recipient_type", value: isCustomer ? "customer" : "admin" }
      ]
    })
  });

  if (!response.ok) {
    const details = await response.text();
    console.error(`Resend rejected notification ${notification.id}:`, response.status, details);
    return jsonResponse({ error: "The email provider rejected the message." }, 502);
  }

  return jsonResponse({ ok: true });
});
