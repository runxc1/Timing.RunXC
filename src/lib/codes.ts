/** Unambiguous alphabet: no 0/O, 1/I, L. */
export const CODE_ALPHABET = "23456789ABCDEFGHJKMNPQRSTUVWXYZ";
export const CODE_LENGTH = 6;

export function normalizeCode(raw: string | null | undefined): string {
  return (raw ?? "").toUpperCase().replace(/[^A-Z0-9]/g, "");
}

export function isValidCode(raw: string): boolean {
  const c = normalizeCode(raw);
  return c.length === CODE_LENGTH && [...c].every((ch) => CODE_ALPHABET.includes(ch));
}

export function genCode(): string {
  const bytes = new Uint8Array(CODE_LENGTH);
  crypto.getRandomValues(bytes);
  return [...bytes]
    .map((b) => CODE_ALPHABET[b % CODE_ALPHABET.length])
    .join("");
}

/** Insert a thin space every 3 chars for display (234 567). */
export function formatCode(raw: string): string {
  const c = normalizeCode(raw);
  return c.length === CODE_LENGTH ? `${c.slice(0, 3)} ${c.slice(3)}` : c;
}

// --- Athlete codes -----------------------------------------------------------
// Generated athlete codes are short (4 chars) because they only have to be
// unique inside one meet. Runners may also arrive with pre-printed codes of
// any length from 1 to 8, so entry fields accept the full range.

export const ATHLETE_CODE_GEN_LENGTH = 4;
export const ATHLETE_CODE_MAX = 8;

/** Any 1–8 alphanumeric characters (external stickers may use 0/O/1/I/L). */
export function isValidAthleteCode(raw: string): boolean {
  const c = normalizeCode(raw);
  return c.length >= 1 && c.length <= ATHLETE_CODE_MAX;
}

export function genAthleteCode(): string {
  const bytes = new Uint8Array(ATHLETE_CODE_GEN_LENGTH);
  crypto.getRandomValues(bytes);
  return [...bytes]
    .map((b) => CODE_ALPHABET[b % CODE_ALPHABET.length])
    .join("");
}
