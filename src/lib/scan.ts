/**
 * Barcode scanning with native BarcodeDetector (Chrome/Android) and a
 * zxing-wasm fallback (iOS Safari). zxing is loaded lazily so the wasm
 * payload never blocks first paint.
 */
export type ScanResult = { text: string; format: string };

type DetectorLike = {
  detect: (source: CanvasImageSource) => Promise<Array<{ rawValue: string; format: string }>>;
};

let nativeDetector: DetectorLike | null | undefined;
type ReadBarcodes = (
  image: ImageData,
  options?: { tryHarder?: boolean; formats?: string[] },
) => Promise<Array<{ text?: string; format?: string }>>;
let zxingRead: ReadBarcodes | null = null;

function getNative(): DetectorLike | null {
  if (nativeDetector !== undefined) return nativeDetector;
  const BD = (window as unknown as { BarcodeDetector?: new (o?: unknown) => DetectorLike })
    .BarcodeDetector;
  if (!BD) {
    nativeDetector = null;
    return null;
  }
  try {
    nativeDetector = new BD({
      formats: ["qr_code", "code_128", "code_39", "data_matrix"],
    });
  } catch {
    nativeDetector = null;
  }
  return nativeDetector;
}

async function loadZxing(): Promise<ReadBarcodes | null> {
  if (zxingRead) return zxingRead;
  try {
    const mod = await import("zxing-wasm/reader");
    zxingRead = ((image: ImageData, options?: { tryHarder?: boolean }) =>
      mod.readBarcodesFromImageData(image, {
        tryHarder: options?.tryHarder ?? true,
        formats: ["QRCode", "Code128", "Code39", "DataMatrix"],
      })) as ReadBarcodes;
    return zxingRead;
  } catch (e) {
    console.warn("zxing fallback unavailable", e);
    return null;
  }
}

/** Open a camera stream into `video`. Returns cleanup fn. */
export async function startCamera(
  video: HTMLVideoElement,
  onFrame: (found: ScanResult) => boolean,
): Promise<() => void> {
  const stream = await navigator.mediaDevices.getUserMedia({
    video: { facingMode: "environment", width: { ideal: 1280 } },
  });
  video.srcObject = stream;
  await video.play();

  const canvas = document.createElement("canvas");
  const ctx = canvas.getContext("2d", { willReadFrequently: true });
  let stopped = false;
  let lastText = "";
  let lastAt = 0;
  const useNative = getNative();
  if (!useNative) await loadZxing();

  const tick = async () => {
    if (stopped) return;
    if (video.readyState >= video.HAVE_CURRENT_DATA && ctx) {
      canvas.width = video.videoWidth;
      canvas.height = video.videoHeight;
      ctx.drawImage(video, 0, 0);
      let found: ScanResult | null = null;
      try {
        if (useNative) {
          const res = await useNative.detect(canvas);
          if (res.length > 0) {
            found = { text: res[0].rawValue, format: res[0].format };
          }
        } else if (zxingRead) {
          const img = ctx.getImageData(0, 0, canvas.width, canvas.height);
          const res = await zxingRead(img, { tryHarder: true });
          if (res.length > 0 && res[0].text) {
            found = { text: res[0].text, format: res[0].format ?? "qr" };
          }
        }
      } catch {
        /* frame decode failure — try next frame */
      }
      const now = Date.now();
      if (found && (found.text !== lastText || now - lastAt > 2500)) {
        lastText = found.text;
        lastAt = now;
        if (navigator.vibrate) navigator.vibrate(40);
        if (onFrame(found)) return; // consumer signals done
      }
    }
    requestAnimationFrame(tick);
  };
  requestAnimationFrame(tick);

  return () => {
    stopped = true;
    stream.getTracks().forEach((t) => t.stop());
  };
}
