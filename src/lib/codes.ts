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
