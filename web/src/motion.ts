/** The user's motion preference: follow the OS setting, or force full motion or a still picture. */
export type MotionPreference = "auto" | "full" | "static";

/**
 * Whether the stage animates. `prefers-reduced-motion: reduce` (with "auto") draws a static picture instead: a still
 * of the current sound, redrawn only on a user action (a visual change, a resize), never animated (WCAG 2.1 SC 2.3.3
 * and 2.2.2).
 */
export function isStatic(preference: MotionPreference, prefersReducedMotion: boolean): boolean {
  return preference === "static" || (preference === "auto" && prefersReducedMotion);
}

/** Reads and follows `prefers-reduced-motion`. Returns the current value and a function to stop listening. */
export function watchReducedMotion(onChange: (reduce: boolean) => void): { reduce: boolean; stop: () => void } {
  const query = typeof matchMedia === "function" ? matchMedia("(prefers-reduced-motion: reduce)") : null;
  if (!query) return { reduce: false, stop: () => {} };
  const listener = (event: MediaQueryListEvent) => onChange(event.matches);
  query.addEventListener("change", listener);
  return { reduce: query.matches, stop: () => query.removeEventListener("change", listener) };
}
