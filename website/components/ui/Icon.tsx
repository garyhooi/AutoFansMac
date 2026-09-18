import {
  ArrowUUpLeft,
  ArrowUpRight,
  CaretRight,
  Check,
  CloudArrowDown,
  Copy,
  Cube,
  Feather,
  Fan,
  Gauge,
  Heartbeat,
  List,
  MagnifyingGlass,
  Scales,
  ShieldCheck,
  Sliders,
  Thermometer,
  Warning,
  X,
} from "@phosphor-icons/react/ssr";

/**
 * One icon family for the whole page (Phosphor), imported from the SSR entry so the
 * icons can render inside Server Components. Named here once so content data can stay
 * plain strings.
 *
 * Weight is a documented rule rather than a per-use choice: light strokes at 18px and
 * above, regular below that, because a light stroke disappears at 14px.
 */
const REGISTRY = {
  ArrowUUpLeft,
  ArrowUpRight,
  CaretRight,
  Check,
  CloudArrowDown,
  Copy,
  Cube,
  Feather,
  Fan,
  Gauge,
  Heartbeat,
  List,
  MagnifyingGlass,
  Scales,
  ShieldCheck,
  Sliders,
  Thermometer,
  Warning,
  X,
} as const;

export type IconName = keyof typeof REGISTRY;

export function Icon({
  name,
  size = 20,
  className,
  weight,
}: {
  name: IconName;
  size?: number;
  className?: string;
  weight?: "thin" | "light" | "regular" | "bold";
}) {
  const Glyph = REGISTRY[name];
  if (!Glyph) return null;
  return (
    <Glyph
      size={size}
      weight={weight ?? (size >= 18 ? "light" : "regular")}
      className={className}
      aria-hidden="true"
    />
  );
}
