/* SPOTOUT — Vorschaukarte für geteilte Profile (/?u=NAME)
   ------------------------------------------------------------------
   Wie api/einladung.js: WhatsApp, iMessage, Signal & Co. rufen den Link
   einmal auf und lesen Titel und Bild aus der Antwort, ohne JavaScript.
   Hier stehen Name, @name und Profilbild drin. Menschen leitet die Seite
   sofort weiter auf /?profil=NAME, wo die App das Profil öffnet.

   Gelesen wird nur mit dem öffentlichen Schlüssel (RLS und Spaltenrechte
   gelten) und nur, was ohnehin öffentlich ist. Bei einem privaten Profil
   steht nur der Name drin – kein Bild: eine Vorschaukarte reist weiter
   als der Link selbst. Fehlt diese Datei, geht alles wie vorher.
*/

const SB_URL = 'https://tuxyyrlxjkxabhvremqu.supabase.co';
const SB_KEY = 'sb_publishable_dldlgp40jFNPHVV8o7lF4A_UmGSxEFZ';
const BILD_STANDARD = 'https://spotoutapp.ch/og.jpg';

const esc = (t) => String(t == null ? '' : t)
  .replace(/&/g, '&amp;').replace(/</g, '&lt;').replace(/>/g, '&gt;')
  .replace(/"/g, '&quot;').replace(/'/g, '&#39;');

// Benutzernamen bestehen aus a–z, 0–9 und _ ; alte Links tragen die Kennung.
const IST_NAME = /^[A-Za-z0-9_.]{1,40}$/;
const IST_ID = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;

export async function profilZu(wer, holen = fetch) {
  const filter = IST_ID.test(wer) ? 'id=eq.' + wer
               : IST_NAME.test(wer) ? 'username=eq.' + encodeURIComponent(wer)
               : null;
  if (!filter) return null;
  try {
    const r = await holen(SB_URL + '/rest/v1/profiles?select=username,full_name,avatar_url,privat,kontoart,verein_ort&'
      + filter + '&limit=1', {
      headers: { apikey: SB_KEY, Authorization: 'Bearer ' + SB_KEY },
    });
    if (!r.ok) return null;
    const j = await r.json();
    return Array.isArray(j) ? (j[0] || null) : null;
  } catch (_) { return null; }
}

/* Reine Funktion: aus dem Profil (oder nichts) die Seite. So lässt sie
   sich ohne Netz prüfen. */
export function profilSeite(wer, p) {
  const ziel = '/?profil=' + encodeURIComponent(wer);
  const kanon = 'https://spotoutapp.ch/?u=' + encodeURIComponent(wer);
  const verein = p && p.kontoart === 'verein';
  const privat = !!(p && p.privat);
  const name = p ? (p.full_name || p.username || 'SPOTOUT') : 'Profil auf SPOTOUT';
  const handle = p && p.username ? '@' + p.username : '';
  const titel = p ? (name + (handle ? ' (' + handle + ')' : '') + ' auf SPOTOUT') : 'Profil auf SPOTOUT';
  const text = !p ? 'Partys und Feste in der Schweiz – sieh, wer hingeht. SPOTOUT ist gratis.'
    : privat ? 'Privates Profil auf SPOTOUT. Öffne den Link und stell eine Anfrage.'
    : verein ? ('Anlässe von ' + name + (p.verein_ort ? ' in ' + p.verein_ort : '') + ' auf SPOTOUT.')
    : ('Folge ' + name + ' auf SPOTOUT und sieh, an welche Partys es geht.');
  // Privat: nie das Profilbild in die Karte
  const eigenesBild = !!(p && !privat && p.avatar_url && /^https:\/\//.test(p.avatar_url));
  const bild = eigenesBild ? p.avatar_url : BILD_STANDARD;
  // Ein Profilbild ist quadratisch – als kleine Karte, nicht als Banner
  const karte = eigenesBild ? 'summary' : 'summary_large_image';

  return `<!doctype html>
<html lang="de">
<head>
<meta charset="utf-8"/>
<meta name="viewport" content="width=device-width,initial-scale=1"/>
<title>${esc(titel)}</title>
<meta name="description" content="${esc(text)}"/>
<meta name="robots" content="noindex"/>
<meta property="og:type" content="profile"/>
<meta property="og:site_name" content="SPOTOUT"/>
<meta property="og:title" content="${esc(titel)}"/>
<meta property="og:description" content="${esc(text)}"/>
<meta property="og:image" content="${esc(bild)}"/>
<meta property="og:url" content="${esc(kanon)}"/>
<meta name="twitter:card" content="${karte}"/>
<meta name="twitter:title" content="${esc(titel)}"/>
<meta name="twitter:description" content="${esc(text)}"/>
<meta name="twitter:image" content="${esc(bild)}"/>
<link rel="canonical" href="${esc(kanon)}"/>
<meta http-equiv="refresh" content="0;url=${esc(ziel)}"/>
<style>
  :root{color-scheme:dark}
  body{margin:0;min-height:100vh;display:flex;align-items:center;justify-content:center;
       background:#090D24;color:#fff;font-family:Inter,-apple-system,BlinkMacSystemFont,'Segoe UI',Roboto,sans-serif;
       padding:24px;text-align:center}
  .k{max-width:420px}
  h1{font-size:1.5rem;margin:0 0 6px;letter-spacing:-.02em}
  p{color:rgba(255,255,255,.62);font-size:.95rem;line-height:1.5;margin:0 0 22px}
  a{display:inline-block;background:linear-gradient(135deg,#FF2D76,#FF5A45);color:#fff;
    text-decoration:none;font-weight:800;padding:14px 26px;border-radius:14px}
</style>
</head>
<body>
  <div class="k">
    <h1>${esc(name)}</h1>
    <p>${esc(handle || 'SPOTOUT')}</p>
    <a href="${esc(ziel)}">Profil öffnen</a>
  </div>
  <script>location.replace(${JSON.stringify(ziel).replace(/</g, '\\u003c')});</script>
</body>
</html>`;
}

export default async function handler(req, res) {
  const u = new URL(req.url, 'https://spotoutapp.ch');
  const wer = (u.searchParams.get('u') || '').trim().replace(/^@/, '');

  // Ohne gültigen Namen hat die Seite nichts zu suchen – zurück auf die Startseite.
  if (!wer || (!IST_NAME.test(wer) && !IST_ID.test(wer))) {
    res.writeHead(302, { Location: '/' });
    return res.end();
  }

  const p = await profilZu(wer);
  res.setHeader('Content-Type', 'text/html; charset=utf-8');
  // Kurz zwischenspeichern: ändert jemand sein Bild, soll es bald stimmen.
  res.setHeader('Cache-Control', 'public, max-age=60, s-maxage=300');
  res.statusCode = 200;
  res.end(profilSeite(wer, p));
}
