// GitHub Pages serves public/404.html for unknown paths; that page stashes
// the originally requested URL in sessionStorage. This module runs at import
// time — it MUST be imported before ./router so vue-router initializes with
// the restored location instead of the app root.
const FALLBACK_KEY = "runxc-spa-fallback-path";

try {
  const saved = sessionStorage.getItem(FALLBACK_KEY);
  if (saved) {
    sessionStorage.removeItem(FALLBACK_KEY);
    // Only same-origin absolute paths (reject protocol-relative //host).
    if (/^\/(?!\/)/.test(saved)) {
      window.history.replaceState(null, "", saved);
    }
  }
} catch {
  // sessionStorage unavailable (private mode) — start at the root instead.
}
