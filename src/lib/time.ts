/** Total race-clock offset in ms -> "12:34.5" (or "1:02:03.4" over an hour). */
export function formatClock(ms: number | null | undefined): string {
  if (ms == null || !Number.isFinite(ms)) return "—";
  const negative = ms < 0;
  const abs = Math.abs(Math.round(ms));
  const tenths = Math.floor((abs % 1000) / 100);
  const totalSec = Math.floor(abs / 1000);
  const sec = totalSec % 60;
  const min = Math.floor(totalSec / 60) % 60;
  const hr = Math.floor(totalSec / 3600);
  const mm = hr > 0 ? String(min).padStart(2, "0") : String(min);
  const s = String(sec).padStart(2, "0");
  return `${negative ? "-" : ""}${hr > 0 ? `${hr}:` : ""}${mm}:${s}.${tenths}`;
}

/** ISO timestamp -> local "h:mm:ss AM/PM" */
export function formatTimeOfDay(iso: string | null | undefined): string {
  if (!iso) return "—";
  return new Date(iso).toLocaleTimeString([], {
    hour: "numeric",
    minute: "2-digit",
    second: "2-digit",
  });
}

/** ISO timestamp -> value for `<input type="datetime-local">` (local wall time). */
export function isoToLocalInput(iso: string | null | undefined): string {
  if (!iso) return "";
  const d = new Date(iso);
  if (Number.isNaN(d.getTime())) return "";
  const pad = (n: number) => String(n).padStart(2, "0");
  return `${d.getFullYear()}-${pad(d.getMonth() + 1)}-${pad(d.getDate())}T${pad(d.getHours())}:${pad(d.getMinutes())}`;
}

/**
 * Starting value for a race's scheduled start: the meet date at 9 AM. Meets can
 * span days, so the day stays editable — this just saves re-typing it.
 */
export function defaultStartInput(meetDate: string | null | undefined): string {
  return /^\d{4}-\d{2}-\d{2}$/.test(meetDate ?? "") ? `${meetDate}T09:00` : "";
}

/**
 * Picker value -> ISO timestamp. Anything that is not a complete date (an empty
 * or half-typed picker, or a bare clock time) becomes null rather than throwing
 * `RangeError: Invalid Date` — and rather than parsing as some other year.
 */
export function toIsoOrNull(value: string | null | undefined): string | null {
  if (!value || !/^\d{4}-\d{2}-\d{2}/.test(value)) return null;
  const d = new Date(value);
  return Number.isNaN(d.getTime()) ? null : d.toISOString();
}
