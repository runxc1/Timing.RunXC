/**
 * Scan feedback tones built with WebAudio: no audio files to ship, loud enough
 * to hear over a noisy finish line, and short so they never mask the next one.
 * Browsers only allow sound after a user gesture, so the context is created
 * lazily and resumed on each play (the scanner always taps or scans first).
 */

import { ref } from "vue";

const MUTE_KEY = "runxc.scanner.muted";

let ctx: AudioContext | null = null;

function audio(): AudioContext | null {
  if (typeof window === "undefined") return null;
  if (!ctx) {
    const AC =
      window.AudioContext ??
      (window as unknown as { webkitAudioContext?: typeof AudioContext }).webkitAudioContext;
    if (!AC) return null;
    ctx = new AC();
  }
  if (ctx.state === "suspended") void ctx.resume();
  return ctx;
}

function tone(freq: number, delayS: number, durS: number, peak = 0.22): void {
  const c = audio();
  if (!c) return;
  const t0 = c.currentTime + delayS;
  const osc = c.createOscillator();
  const gain = c.createGain();
  osc.type = "square"; // cuts through crowd noise better than a sine
  osc.frequency.setValueAtTime(freq, t0);
  gain.gain.setValueAtTime(0.0001, t0);
  gain.gain.exponentialRampToValueAtTime(peak, t0 + 0.012);
  gain.gain.exponentialRampToValueAtTime(0.0001, t0 + durS);
  osc.connect(gain).connect(c.destination);
  osc.start(t0);
  osc.stop(t0 + durS + 0.03);
}

const muted = ref(localStorage.getItem(MUTE_KEY) === "1");

export function isMuted(): boolean {
  return muted.value;
}

/** Reactive so the UI can show a speaker toggle; muting also hushes vibration. */
export function setMuted(value: boolean): void {
  muted.value = value;
  localStorage.setItem(MUTE_KEY, value ? "1" : "0");
  if (!value) beepAccepted(); // let them hear that sound is back on
}

/** Rising two-note chirp: the runner is recorded. */
export function beepAccepted(): void {
  if (muted.value) return;
  tone(1150, 0, 0.07);
  tone(1600, 0.075, 0.09);
  if (navigator.vibrate) navigator.vibrate(30);
}

/** Low buzz: nothing was recorded — look at the screen. */
export function beepRejected(): void {
  if (muted.value) return;
  tone(320, 0, 0.11, 0.26);
  tone(240, 0.12, 0.14, 0.26);
  if (navigator.vibrate) navigator.vibrate([40, 40, 40]);
}
