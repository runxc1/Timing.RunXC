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
