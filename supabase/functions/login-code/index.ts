// ============================================================
// Edge Function : login-code
//
// Envoie le code de connexion à usage unique (8 chiffres) sur
// l'adresse email d'un membre. Appelée depuis Postgres par pg_net
// via request_login_code (migration 13) : le navigateur ne la
// voit jamais ; le code transite par https et n'est stocké qu'en
// version hashée en base.
//
// Déploiement via CLI :
//   supabase functions deploy login-code
//   supabase secrets set SMTP_USER="jeton_smtp" \
//     SMTP_PASS="mot_de_passe_du_jeton" \
//     NOTIFY_FROM_EMAIL="famille@exemple.fr" \
//     EDGE_SHARED_SECRET="valeur_longue_aleatoire"
// (La même valeur EDGE_SHARED_SECRET vit dans app_secrets,
//  migration 12 ; sans l'en-tête « x-webhook-secret » égal à ce
//  secret, la fonction répond 401.)
//
// SMTP_HOST et SMTP_PORT sont facultatifs (défauts Proton :
// smtp.protonmail.ch, 587).
// ============================================================

import nodemailer from 'npm:nodemailer@6.9.13';

interface LoginCodeBody {
  email?: string;
  code?: string;
  minutes?: number;
  at?: string;
}

const corsHeaders = {
  'Access-Control-Allow-Origin': '*',
  'Access-Control-Allow-Headers':
    'authorization, x-client-info, apikey, content-type',
};

Deno.serve(async (req: Request) => {
  if (req.method === 'OPTIONS') {
    return new Response('ok', { headers: corsHeaders });
  }
  if (req.method !== 'POST') {
    return new Response(JSON.stringify({ error: 'Method not allowed' }), {
      status: 405,
      headers: { ...corsHeaders, 'Content-Type': 'application/json' },
    });
  }

  // Secret partagé : seul Postgres (pg_net) connaît cette valeur,
  // envoyée dans l'en-tête x-webhook-secret. Sans correspondance :
  // 401, la fonction ne divulgue rien.
  const edgeSecret = Deno.env.get('EDGE_SHARED_SECRET');
  const providedSecret = req.headers.get('x-webhook-secret');
  if (!edgeSecret || providedSecret !== edgeSecret) {
    return new Response(JSON.stringify({ error: 'Non autorisé' }), {
      status: 401,
      headers: { ...corsHeaders, 'Content-Type': 'application/json' },
    });
  }

  const smtpUser = Deno.env.get('SMTP_USER');
  const smtpPass = Deno.env.get('SMTP_PASS');
  const fromEmail = Deno.env.get('NOTIFY_FROM_EMAIL');

  if (!smtpUser || !smtpPass || !fromEmail) {
    return new Response(
      JSON.stringify({ error: 'Notification non configurée (secrets manquants)' }),
      { status: 500, headers: { ...corsHeaders, 'Content-Type': 'application/json' } },
    );
  }

  let body: LoginCodeBody;
  try {
    body = await req.json();
  } catch {
    return new Response(JSON.stringify({ error: 'Corps invalide' }), {
      status: 400,
      headers: { ...corsHeaders, 'Content-Type': 'application/json' },
    });
  }

  const email = body.email ?? '';
  const code = body.code ?? '';
  const minutes = Number.isFinite(body.minutes) ? Number(body.minutes) : 10;
  if (!email || !/^\d{8}$/.test(code)) {
    return new Response(JSON.stringify({ error: 'Paramètres invalides' }), {
      status: 400,
      headers: { ...corsHeaders, 'Content-Type': 'application/json' },
    });
  }

  const html = `
    <div style="font-family:sans-serif;max-width:480px;">
      <h2 style="margin-bottom:8px;">Votre code de connexion</h2>
      <p>Votre code de connexion est :</p>
      <p style="font-size:32px;font-weight:700;letter-spacing:8px;margin:16px 0;text-align:center;">
        ${escapeHtml(code)}
      </p>
      <p>Ce code est à usage unique et valable ${minutes} minute${minutes > 1 ? 's' : ''}.
      Saisissez-le sur le site pour vous connecter.</p>
      <p style="color:#64748b;font-size:13px;">
        Si vous n'êtes pas à l'origine de cette demande, ignorez cet email :
        aucun compte n'est accessible sans ce code.
      </p>
    </div>`;

  const port = Number(Deno.env.get('SMTP_PORT') ?? '587');
  const transporter = nodemailer.createTransport({
    host: Deno.env.get('SMTP_HOST') ?? 'smtp.protonmail.ch',
    port,
    secure: port === 465,
    auth: { user: smtpUser, pass: smtpPass },
  });

  try {
    await transporter.sendMail({
      from: fromEmail,
      to: email,
      subject: 'Votre code de connexion',
      html,
    });
  } catch (err) {
    return new Response(
      JSON.stringify({ error: 'Envoi impossible', detail: String(err?.message ?? err) }),
      { status: 502, headers: { ...corsHeaders, 'Content-Type': 'application/json' } },
    );
  }

  return new Response(JSON.stringify({ ok: true }), {
    headers: { ...corsHeaders, 'Content-Type': 'application/json' },
  });
});

function escapeHtml(text: string | null): string {
  if (!text) return '';
  return text
    .replace(/&/g, '&amp;')
    .replace(/</g, '&lt;')
    .replace(/>/g, '&gt;')
    .replace(/"/g, '&quot;');
}
