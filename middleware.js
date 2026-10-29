/* Einladungslinks (/?join=CODE) und geteilte Profile (/?u=NAME) brauchen
   eine eigene Vorschaukarte. Eine Rewrite-Regel in vercel.json greift auf
   "/" nie – Vercel liefert dort zuerst index.html aus. Die Middleware
   läuft davor und reicht genau diese Adressen an api/einladung bzw.
   api/profil weiter. Menschen leitet die Seite sofort weiter (/?j=CODE
   bzw. /?profil=NAME), wo die App die Einladung oder das Profil öffnet. */
export const config = { matcher: '/' };

/* Welche Adresse wohin gehört. Eigene Funktion, damit sie sich ohne
   Vercel prüfen lässt. */
export function vorschauZiel(u) {
  const join = u.searchParams.get('join');
  if (join) return { api: '/api/einladung', ersatz: '/?j=' + encodeURIComponent(join) };
  const wer = u.searchParams.get('u');
  if (wer) return { api: '/api/profil', ersatz: '/?profil=' + encodeURIComponent(wer) };
  return null;
}

export default async function middleware(req) {
  const u = new URL(req.url);
  const z = vorschauZiel(u);
  if (!z) return;                                    // alles andere wie bisher
  const ziel = new URL(z.api + u.search, u.origin);
  try {
    const r = await fetch(ziel, { headers: { 'user-agent': req.headers.get('user-agent') || '' } });
    if (r.ok) return new Response(r.body, { status: 200, headers: r.headers });
  } catch (e) {
    console.warn('[vorschau] middleware', z.api, e);
  }
  // Klappt die Karte nicht: Menschen kommen trotzdem an.
  return Response.redirect(new URL(z.ersatz, u.origin), 302);
}
