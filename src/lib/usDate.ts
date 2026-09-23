/**
 * US date/time entry helpers (mm/dd/yyyy and h:mm AM/PM).
 *
 * A native `<input type="date">` renders in whatever order the *operating
 * system* region asks for, so an en-US app was showing day/month/year fields.
 * These back masked text inputs instead, so the order is always month first no
 * matter what the machine is set to. Displayed strings elsewhere are pinned to
 * `en-US` for the same reason.
 */

const pad2 = (n: number) => String(n).padStart(2, "0");

/** ISO date (`YYYY-MM-DD`) -> `mm/dd/yyyy`. Anything else -> "". */
export function formatUsDate(iso: string | null | undefined): string {
  const m = /^(\d{4})-(\d{2})-(\d{2})$/.exec(iso ?? "");
  return m ? `${m[2]}/${m[3]}/${m[1]}` : "";
}

/**
 * Progressive typing mask. Separators the user types are honoured; otherwise
 * they are inserted ("9232026" -> "9/23/2026", "11302026" -> "11/30/2026").
 */
export function maskUsDate(raw: string): string {
  const digits = (s: string | undefined) => (s ?? "").replace(/\D/g, "");
  if (!raw.includes("/")) {
    const typed = digits(raw).slice(0, 8);
    if (!typed) return "";
    // A leading 2-9 can only begin a one-digit month, so the slash lands early.
    const monthLen = Number(typed[0]) > 1 ? 1 : Math.min(2, typed.length);
    let out = typed.slice(0, monthLen);
    if (typed.length > monthLen) out += `/${typed.slice(monthLen, monthLen + 2)}`;
    if (typed.length > monthLen + 2) out += `/${typed.slice(monthLen + 2, monthLen + 6)}`;
    return out;
  }
  // Separators the user typed win; digits that overflow a segment roll forward.
  const parts = raw.split("/").map(digits);
  const month = (parts[0] ?? "").slice(0, 2);
  const afterMonth = (parts[0] ?? "").slice(2) + (parts[1] ?? "");
  const day = afterMonth.slice(0, 2);
  const year = (afterMonth.slice(2) + (parts[2] ?? "")).slice(0, 4);
  let out = month;
  if (parts.length > 1) out += `/${day}`;
  if (parts.length > 2 || year) out += `/${year}`;
  return out;
}

/** `9/23/2026` -> `2026-09-23`. Incomplete or impossible dates -> null. */
export function parseUsDate(text: string | null | undefined): string | null {
  const m = /^\s*(\d{1,2})\/(\d{1,2})\/(\d{4})\s*$/.exec(text ?? "");
  if (!m) return null;
  const month = Number(m[1]);
  const day = Number(m[2]);
  const year = Number(m[3]);
  if (year < 1900 || year > 2999) return null;
  const d = new Date(year, month - 1, day);
  if (d.getFullYear() !== year || d.getMonth() !== month - 1 || d.getDate() !== day) return null;
  return `${String(year).padStart(4, "0")}-${pad2(month)}-${pad2(day)}`;
}

/** `HH:mm` -> `h:mm AM/PM`. Anything else -> "". */
export function formatUsTime(hhmm: string | null | undefined): string {
  const m = /^(\d{2}):(\d{2})$/.exec(hhmm ?? "");
  if (!m) return "";
  const h = Number(m[1]);
  return `${h % 12 === 0 ? 12 : h % 12}:${m[2]} ${h >= 12 ? "PM" : "AM"}`;
}

/**
 * `5:05 pm`, `5:05PM`, `5pm`, `17:05`, `505` -> `17:05`. A bare time with no
 * meridiem is read as 24-hour, so typing `9:30` means 09:30. Garbage -> null.
 */
export function parseUsTime(text: string | null | undefined): string | null {
  const raw = (text ?? "").trim().toLowerCase().replace(/[.\s]/g, "");
  if (!raw) return null;
  const clock = (h: number, min: number) => (h > 23 || min > 59 ? null : `${pad2(h)}:${pad2(min)}`);

  // A bare a/p is accepted too — "5:05p" is what a busy hand types.
  const meridiem = /^(\d{1,2}):?(\d{2})?(am|pm|a|p)$/.exec(raw);
  if (meridiem) {
    const h = Number(meridiem[1]);
    const min = meridiem[2] ? Number(meridiem[2]) : 0;
    if (h < 1 || h > 12) return null;
    const isAm = meridiem[3][0] === "a";
    const hour24 = isAm ? (h === 12 ? 0 : h) : h === 12 ? 12 : h + 12;
    return clock(hour24, min);
  }
  const colon = /^(\d{1,2}):(\d{2})$/.exec(raw);
  if (colon) return clock(Number(colon[1]), Number(colon[2]));
  const compact = /^\d{3,4}$/.exec(raw);
  if (compact) return clock(Number(raw.slice(0, -2)), Number(raw.slice(-2)));
  const hourOnly = /^\d{1,2}$/.exec(raw);
  if (hourOnly) return clock(Number(raw), 0);
  return null;
}
