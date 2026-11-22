// ============================================================
// Edge Function : notify-proposal
//
// Notifie les administrateurs par email (API Resend) lorsqu'une
// proposition de modification est soumise. Appelée depuis le
// navigateur avec supabase.functions.invoke('notify-proposal').
//
// Déploiement :
//   supabase functions deploy notify-proposal
//   supabase secrets set RESEND_API_KEY=... \
//     NOTIFY_FROM_EMAIL="Administration familiale <onboarding@resend.dev>" \
//     NOTIFY_TO_EMAILS="admin1@exemple.fr,admin2@exemple.fr"
//
// Si la fonction n'est pas déployée, la proposition reste
// enregistrée en base (le front ignore l'échec de notification).
// ============================================================

interface ProposalChange {
  field: string;
  from: string | null;
  to: string | null;
}

interface NotifyBody {
  member?: string;
  proposed_by?: string;
  changes?: ProposalChange[];
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

  const resendApiKey = Deno.env.get('RESEND_API_KEY');
  const fromEmail = Deno.env.get('NOTIFY_FROM_EMAIL');
  const toEmails = (Deno.env.get('NOTIFY_TO_EMAILS') ?? '')
    .split(',')
    .map((s) => s.trim())
    .filter(Boolean);

  if (!resendApiKey || !fromEmail || toEmails.length === 0) {
    return new Response(
      JSON.stringify({ error: 'Notification non configurée (secrets manquants)' }),
      { status: 500, headers: { ...corsHeaders, 'Content-Type': 'application/json' } },
    );
  }

  let body: NotifyBody;
  try {
    body = await req.json();
  } catch {
    return new Response(JSON.stringify({ error: 'Corps invalide' }), {
      status: 400,
      headers: { ...corsHeaders, 'Content-Type': 'application/json' },
    });
  }

  const member = body.member ?? '';
  const proposedBy = body.proposed_by ?? '';
  const changes: ProposalChange[] = Array.isArray(body.changes) ? body.changes : [];

  const rows = changes
    .map(
      (c) => `
        <tr>
          <td style="border:1px solid #ddd;padding:6px 10px;font-weight:600;">${escapeHtml(c.field)}</td>
          <td style="border:1px solid #ddd;padding:6px 10px;color:#b91c1c;">${escapeHtml(c.from || '(vide)')}</td>
          <td style="border:1px solid #ddd;padding:6px 10px;color:#15803d;font-weight:600;">${escapeHtml(c.to || '(vide)')}</td>
        </tr>`,
    )
    .join('');

  const html = `
    <div style="font-family:sans-serif;max-width:640px;">
      <h2 style="margin-bottom:4px;">Proposition de modification</h2>
      <p>
        <strong>${escapeHtml(proposedBy)}</strong> a proposé une modification
        de la fiche de <strong>${escapeHtml(member)}</strong>.
      </p>
      ${changes.length > 0
        ? `<table style="border-collapse:collapse;max-width:640px;">
            <thead>
              <tr>
                <th style="border:1px solid #ddd;padding:6px 10px;text-align:left;">Champ</th>
                <th style="border:1px solid #ddd;padding:6px 10px;text-align:left;">Actuel</th>
                <th style="border:1px solid #ddd;padding:6px 10px;text-align:left;">Proposé</th>
              </tr>
            </thead>
            <tbody>${rows}</tbody>
          </table>`
        : '<p>(aucun détail transmis)</p>'}
      <p style="color:#64748b;font-size:13px;">
        Connectez-vous au site avec un compte administrateur,
        bouton « Modifications proposées », pour accepter ou refuser.
      </p>
    </div>`;

  try {
    const res = await fetch('https://api.resend.com/emails', {
      method: 'POST',
      headers: {
        Authorization: `Bearer ${resendApiKey}`,
        'Content-Type': 'application/json',
      },
      body: JSON.stringify({
        from: fromEmail,
        to: toEmails,
        subject: `Proposition de modification — ${member}`,
        html,
      }),
    });
    if (!res.ok) {
      const detail = await res.text();
      return new Response(JSON.stringify({ error: detail }), {
        status: 502,
        headers: { ...corsHeaders, 'Content-Type': 'application/json' },
      });
    }
  } catch (err) {
    return new Response(
      JSON.stringify({ error: `Envoi impossible : ${String(err)}` }),
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
