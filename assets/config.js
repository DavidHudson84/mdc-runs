// Bump BUILD on every deploy. The service worker caches by it, and a stale
// cached version is the classic failure mode of GitHub Pages hosting.
export const BUILD = '2026.08.24.2';

export const SUPABASE_URL = 'https://gfvybedbfeguhizzgrow.supabase.co';

// Publishable key. This is PUBLIC by design and safe in a public repo — anon
// holds no table privileges at all, and every driver action goes through a
// SECURITY DEFINER function that checks a session token first.
// The service_role key must NEVER appear in this file.
export const SUPABASE_KEY = 'sb_publishable_nzUOHhr3hNF_l23gy3mksA__4OA4H9c';

// Which business this deployment serves. Dr Drapes or Wheelie would be a
// different slug against the same database, not a fork.
export const BUSINESS_SLUG = 'mdc';
