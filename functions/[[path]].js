/**
 * Cloudflare Pages Function — short-code router
 * Replaces the previous Netlify Edge Function.
 *
 * - /123456  →  302 redirect to /unlock?code=123456
 * - /unlock  →  serve Unlock.html while keeping the clean URL
 * - everything else → pass through to static assets
 */
export async function onRequest(context) {
  const { request, env, next } = context;
  const url = new URL(request.url);

  // Root-level six-digit path becomes the clean unlock URL.
  // Example: /123456 → /unlock?code=123456
  const codeMatch = url.pathname.match(/^\/(\d{6})\/?$/);
  if (codeMatch) {
    const unlockUrl = new URL("/unlock", url.origin);
    unlockUrl.searchParams.set("code", codeMatch[1]);
    return Response.redirect(unlockUrl.toString(), 302);
  }

  // Serve Unlock.html without changing the clean URL shown in the browser.
  if (url.pathname === "/unlock" || url.pathname === "/unlock/") {
    const assetUrl = new URL("/Unlock.html", url.origin);
    assetUrl.search = url.search; // preserve ?code=...
    // Fetch the static asset and return it under the original /unlock URL
    return env.ASSETS.fetch(new Request(assetUrl.toString(), request));
  }

  // Let Cloudflare serve static assets (or fall through)
  return env.ASSETS.fetch(request);
}
