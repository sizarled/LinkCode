export default async function shortCodeRouter(request, context) {
  const url = new URL(request.url);

  // A root-level six-digit path becomes the clean unlock URL.
  // Example: /123456 -> /unlock?code=123456
  const codeMatch = url.pathname.match(/^\/(\d{6})\/?$/);
  if (codeMatch) {
    const unlockUrl = new URL("/unlock", url.origin);
    unlockUrl.searchParams.set("code", codeMatch[1]);
    return Response.redirect(unlockUrl, 302);
  }

  // NOTE: /unlock is intentionally NOT rewritten here.
  // It is served as a real folder (unlock/index.html), so no rewrite is
  // needed. Rewriting it caused an infinite 301 loop with Netlify's
  // automatic pretty-URL redirect (Unlock.html -> /unlock -> rewrite ...).

  return context.next();
}
