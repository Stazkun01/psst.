// Returns the visitor's approximate city + country (from Vercel's edge network)
// so a sender's message can carry a location hint. Nothing is stored here.
export const config = { runtime: 'edge' };

export default function handler(req) {
  const h = req.headers;
  const dec = (v) => { try { return v ? decodeURIComponent(v) : null; } catch { return v; } };
  return new Response(
    JSON.stringify({ city: dec(h.get('x-vercel-ip-city')), country: h.get('x-vercel-ip-country') || null }),
    { headers: { 'content-type': 'application/json', 'cache-control': 'no-store' } }
  );
}
