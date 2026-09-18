// Generates the PWA icons + favicon using only Node built-ins.
// Stopwatch glyph: dark rounded square, lime dial, cyan hand.
import { deflateSync } from "node:zlib";
import { writeFileSync, mkdirSync } from "node:fs";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";

const outDir = join(dirname(fileURLToPath(import.meta.url)), "..", "public", "icons");
mkdirSync(outDir, { recursive: true });

const INK = [11, 18, 32, 255]; // #0b1220
const BRAND = [163, 230, 53, 255]; // lime-400
const CYAN = [34, 211, 238, 255];

function crc32(buf) {
  let c, crc = 0xffffffff;
  for (let n = 0; n < buf.length; n++) {
    c = (crc ^ buf[n]) & 0xff;
    for (let k = 0; k < 8; k++) c = c & 1 ? 0xedb88320 ^ (c >>> 1) : c >>> 1;
    crc = crc ^ (c >>> 8);
  }
  return (crc ^ 0xffffffff) >>> 0;
}

function chunk(type, data) {
  const len = Buffer.alloc(4);
  len.writeUInt32BE(data.length);
  const body = Buffer.concat([Buffer.from(type, "ascii"), data]);
  const crc = Buffer.alloc(4);
  crc.writeUInt32BE(crc32(body));
  return Buffer.concat([len, body, crc]);
}

function encodePng(size, pixelFn) {
  const raw = Buffer.alloc(size * (size * 4 + 1));
  for (let y = 0; y < size; y++) {
    const rowStart = y * (size * 4 + 1);
    raw[rowStart] = 0; // filter: none
    for (let x = 0; x < size; x++) {
      const [r, g, b, a] = pixelFn(x, y, size);
      const i = rowStart + 1 + x * 4;
      raw[i] = r;
      raw[i + 1] = g;
      raw[i + 2] = b;
      raw[i + 3] = a;
    }
  }
  const ihdr = Buffer.alloc(13);
  ihdr.writeUInt32BE(size, 0);
  ihdr.writeUInt32BE(size, 4);
  ihdr[8] = 8; // bit depth
  ihdr[9] = 6; // RGBA
  return Buffer.concat([
    Buffer.from([0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a]),
    chunk("IHDR", ihdr),
    chunk("IDAT", deflateSync(raw, { level: 9 })),
    chunk("IEND", Buffer.alloc(0)),
  ]);
}

function inRoundedRect(x, y, size, pad, radius) {
  const x0 = pad, y0 = pad, x1 = size - pad, y1 = size - pad;
  if (x < x0 || x > x1 || y < y0 || y > y1) return false;
  const cx = Math.max(x0 + radius, Math.min(x, x1 - radius));
  const cy = Math.max(y0 + radius, Math.min(y, y1 - radius));
  return (
    (x - cx) ** 2 + (y - cy) ** 2 <= radius ** 2 ||
    (x >= x0 + radius && x <= x1 - radius) ||
    (y >= y0 + radius && y <= y1 - radius)
  );
}

function stopwatchPixel(x, y, size) {
  const u = x / size;
  const v = y / size;
  if (u > 0.44 && u < 0.56 && v > 0.04 && v < 0.16) return BRAND; // crown
  if ((u > 0.24 && u < 0.33 && v > 0.1 && v < 0.2) || (u > 0.67 && u < 0.76 && v > 0.1 && v < 0.2))
    return BRAND; // side buttons
  const cx = 0.5, cy = 0.56, rOut = 0.36, rIn = 0.27;
  const d = Math.hypot(u - cx, v - cy);
  if (d <= rOut && d >= rIn) return BRAND; // dial ring
  const ang = Math.atan2(v - cy, u - cx);
  const handAng = -Math.PI / 3;
  const diff = Math.atan2(Math.sin(ang - handAng), Math.cos(ang - handAng));
  if (d < rIn && d > 0.02 && Math.abs(diff) < 0.06) return CYAN; // hand
  if (d <= 0.035) return CYAN; // center
  if (Math.abs(u - 0.5) < 0.015 && v > cy - rIn && v < cy - rIn + 0.06) return CYAN; // 12 tick
  return INK;
}

for (const size of [192, 512]) {
  const png = encodePng(size, (x, y) =>
    inRoundedRect(x, y, size, 0, size * 0.18) ? stopwatchPixel(x, y, size) : [0, 0, 0, 0],
  );
  writeFileSync(join(outDir, `icon-${size}.png`), png);
  console.log(`icon-${size}.png ${(png.length / 1024).toFixed(1)} KB`);
}

writeFileSync(
  join(outDir, "icon-maskable-512.png"),
  encodePng(512, (x, y) => {
    if (!inRoundedRect(x, y, 512, 0, 512 * 0.18)) return [0, 0, 0, 0];
    const sx = ((x / 512 - 0.5) / 0.78 + 0.5) * 512;
    const sy = ((y / 512 - 0.5) / 0.78 + 0.5) * 512;
    return stopwatchPixel(sx, sy, 512);
  }),
);
console.log("icon-maskable-512.png written");

writeFileSync(
  join(dirname(outDir), "favicon.svg"),
  `<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 64 64">
<rect width="64" height="64" rx="12" fill="#0b1220"/>
<rect x="28" y="3" width="8" height="7" rx="2" fill="#a3e635"/>
<circle cx="32" cy="36" r="22" fill="none" stroke="#a3e635" stroke-width="6"/>
<line x1="32" y1="36" x2="43" y2="22" stroke="#22d3ee" stroke-width="4" stroke-linecap="round"/>
<circle cx="32" cy="36" r="3.5" fill="#22d3ee"/>
</svg>
`,
);
console.log("favicon.svg written");
