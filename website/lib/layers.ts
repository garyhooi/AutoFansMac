/**
 * The whole z-index scale. Nothing else on the page sets a z-index.
 *
 *   40  the floating navigation pill (and its mobile trigger)
 *   50  the full-screen mobile menu, which has to cover the navigation
 *   60  the fixed film-grain overlay (declared in globals.css as .grain::after)
 */
export const LAYER = {
  nav: "z-40",
  overlay: "z-50",
} as const;
