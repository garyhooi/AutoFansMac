"use client";

import { useAnimationFrame, useReducedMotion } from "motion/react";
import { useCallback, useEffect, useMemo, useRef, useState } from "react";
import { curve } from "@/lib/site";

/*
  An interactive model of the ramp the app actually ships.

  The maths is copied from AutoFansMac/Services/CurveEngine.swift:
    lo       = max(F%dMn, 500)          here 2317, the measured F0Mn on a Mac17,9
    hi       = F%dMx                    here 7826, the measured F0Mx on the same machine
    T <= Tmin                           the fan is handed back to macOS, which idles it
    T >= Tmax                           held at hi
    Tmin < T < Tmax                     lo + (hi - lo) x (T - Tmin) / (Tmax - Tmin)
    smoothing                           EMA with alpha 0.3
    T >= 95 C                           thermal floor, every fan to maximum

  Nothing here re-renders React on a frame: the simulation keeps its state in refs and
  writes to the DOM through refs, so a moving marker costs no reconciliation. It is
  also gated on the chart being visible.
*/

const T_MIN = 55;
const T_MAX = 85;
const FLOOR = 95;
const LO_RPM = curve.fan.minRPM;
const HI_RPM = curve.fan.maxRPM;

const TEMP_LO = 30;
const TEMP_HI = 100;
const RPM_HI = 8000;

const PLOT = { left: 46, right: 706, top: 24, bottom: 330 };
const VIEW = { w: 720, h: 360 };

const xFor = (temp: number) =>
  PLOT.left + ((temp - TEMP_LO) / (TEMP_HI - TEMP_LO)) * (PLOT.right - PLOT.left);
const yFor = (rpm: number) =>
  PLOT.bottom - (Math.min(rpm, RPM_HI) / RPM_HI) * (PLOT.bottom - PLOT.top);

type Mode = "auto" | "custom" | "floor";

/** The shipped ramp, plus the floor override that sits above it. */
function commanded(temp: number): { rpm: number; mode: Mode } {
  if (temp >= FLOOR) return { rpm: HI_RPM, mode: "floor" };
  if (temp <= T_MIN) return { rpm: 0, mode: "auto" };
  const fraction = Math.min(1, (temp - T_MIN) / (T_MAX - T_MIN));
  return { rpm: LO_RPM + (HI_RPM - LO_RPM) * fraction, mode: "custom" };
}

const MODE_LABEL: Record<Mode, string> = {
  auto: "Auto (macOS)",
  custom: "Custom (AutoFansMac)",
  floor: "Floor override",
};

const MODE_HINT: Record<Mode, string> = {
  auto: "macOS holds this fan and idles it at 0 RPM",
  custom: "AutoFansMac holds the fan on the ramp",
  floor: "A CPU, GPU or SOC sensor is at the thermal floor",
};

const PRESETS = [
  { label: "Idle", workload: 4 },
  { label: "Sustained", workload: 58 },
  { label: "Full load", workload: 97 },
] as const;

const BASE_AT_IDLE = 34;
const BASE_AT_LOAD = 98;
const baseTemp = (workload: number) =>
  BASE_AT_IDLE + (workload / 100) * (BASE_AT_LOAD - BASE_AT_IDLE);

/** Deterministic drift, so the trace is alive without being random between reloads. */
const drift = (time: number) =>
  1.7 * Math.sin(time * 0.63) + 2.3 * Math.sin(time * 0.21 + 1.2) + 1.1 * Math.sin(time * 1.7 + 0.4);

export function CurveInstrument() {
  const reduce = useReducedMotion();
  const [workload, setWorkload] = useState(24);
  const [sensorIndex, setSensorIndex] = useState(0);

  const svgRef = useRef<SVGSVGElement>(null);
  const markerRef = useRef<SVGCircleElement>(null);
  const markerRingRef = useRef<SVGCircleElement>(null);
  const dropVRef = useRef<SVGLineElement>(null);
  const dropHRef = useRef<SVGLineElement>(null);
  const trailRef = useRef<SVGPathElement>(null);
  const tempRef = useRef<HTMLSpanElement>(null);
  const rpmRef = useRef<HTMLSpanElement>(null);
  const badgeRef = useRef<HTMLSpanElement>(null);
  const badgeTextRef = useRef<HTMLSpanElement>(null);
  const hintRef = useRef<HTMLParagraphElement>(null);

  const workloadRef = useRef(workload);
  const smoothRef = useRef(baseTemp(workload));
  const trailPoints = useRef<Array<{ x: number; y: number }>>([]);
  const visible = useRef(true);

  workloadRef.current = workload;

  /** Single writer for every readout and every moving part of the chart. */
  const paint = useCallback((temp: number, withTrail: boolean) => {
    const { rpm, mode } = commanded(temp);
    const x = xFor(temp);
    const y = yFor(rpm);

    if (markerRef.current) {
      markerRef.current.setAttribute("cx", String(x));
      markerRef.current.setAttribute("cy", String(y));
    }
    if (markerRingRef.current) {
      markerRingRef.current.setAttribute("cx", String(x));
      markerRingRef.current.setAttribute("cy", String(y));
    }
    if (dropVRef.current) {
      dropVRef.current.setAttribute("x1", String(x));
      dropVRef.current.setAttribute("x2", String(x));
      dropVRef.current.setAttribute("y2", String(y));
    }
    if (dropHRef.current) {
      dropHRef.current.setAttribute("x2", String(x));
      dropHRef.current.setAttribute("y1", String(y));
      dropHRef.current.setAttribute("y2", String(y));
    }
    if (tempRef.current) tempRef.current.textContent = temp.toFixed(1);
    if (rpmRef.current) rpmRef.current.textContent = String(Math.round(rpm));
    if (badgeRef.current) badgeRef.current.setAttribute("data-mode", mode);
    if (badgeTextRef.current) badgeTextRef.current.textContent = MODE_LABEL[mode];
    if (hintRef.current) hintRef.current.textContent = MODE_HINT[mode];

    if (withTrail) {
      const points = trailPoints.current;
      points.push({ x, y });
      if (points.length > 64) points.shift();
      if (trailRef.current) {
        trailRef.current.setAttribute(
          "d",
          points.map((p, i) => `${i === 0 ? "M" : "L"}${p.x.toFixed(1)} ${p.y.toFixed(1)}`).join(" "),
        );
      }
    }
  }, []);

  /* Static path: the readouts follow the slider, with no animation at all. */
  useEffect(() => {
    if (!reduce) return;
    trailPoints.current = [];
    if (trailRef.current) trailRef.current.setAttribute("d", "");
    paint(baseTemp(workload), false);
  }, [reduce, workload, paint]);

  /* Animated path: the same maths, driven by a drifting simulated load. */
  useEffect(() => {
    if (!svgRef.current) return;
    const target = svgRef.current;
    const observer = new IntersectionObserver(
      (entries) => {
        visible.current = entries.some((entry) => entry.isIntersecting);
      },
      { threshold: 0.05 },
    );
    observer.observe(target);
    return () => observer.disconnect();
  }, []);

  useAnimationFrame((time) => {
    if (reduce || !visible.current) return;
    const seconds = time / 1000;
    const raw = Math.min(104, Math.max(TEMP_LO, baseTemp(workloadRef.current) + drift(seconds)));
    smoothRef.current = 0.3 * raw + 0.7 * smoothRef.current;
    paint(smoothRef.current, true);
  });

  const gradientStops = useMemo(
    () => [
      { temp: 40, label: "40" },
      { temp: 60, label: "60" },
      { temp: 80, label: "80" },
      { temp: 100, label: "100" },
    ],
    [],
  );

  const rpmTicks = [0, 2000, 4000, 6000, 8000];
  const sensor = curve.sensors[sensorIndex];
  /* The operating point React renders. The animation loop overwrites these same
     attributes every frame while the chart is on screen; when it is paused, React is
     what keeps the chart honest instead of leaving it showing a stale frame. */
  const staticTemp = baseTemp(workload);
  const staticState = commanded(staticTemp);
  const staticX = xFor(staticTemp);
  const staticY = yFor(staticState.rpm);

  return (
    <div className="flex flex-col gap-5">
      <div className="shell ambient">
        <div className="core p-4 sm:p-5">
          <div className="flex flex-wrap items-start justify-between gap-4">
            <div>
              <p className="font-mono text-[11px] text-ash-500">Tracked sensor</p>
              <p className="mt-1 flex flex-wrap items-baseline gap-x-2.5 gap-y-1">
                <span className="font-mono text-[13px] text-aqua-300">{sensor.key}</span>
                <span className="text-[13.5px] tracking-tight text-ash-200">{sensor.name}</span>
              </p>
            </div>
            <span
              ref={badgeRef}
              data-mode={staticState.mode}
              className="inline-flex items-center rounded-full border border-white/10 bg-white/[0.03] px-2.5 py-1 font-mono text-[11px] tracking-tight text-ash-300 data-[mode=custom]:border-aqua-700/45 data-[mode=custom]:bg-aqua-950/35 data-[mode=custom]:text-aqua-300 data-[mode=floor]:border-aqua-500/70 data-[mode=floor]:bg-aqua-500/15 data-[mode=floor]:text-aqua-200"
            >
              <span ref={badgeTextRef}>{MODE_LABEL[staticState.mode]}</span>
            </span>
          </div>

          <svg
            ref={svgRef}
            viewBox={`0 0 ${VIEW.w} ${VIEW.h}`}
            className="mt-4 h-auto w-full select-none"
            role="img"
            aria-label={`Fan ramp chart. The fan stays with macOS below ${T_MIN} degrees, ramps to full speed at ${T_MAX} degrees, and the thermal floor sits at ${FLOOR} degrees.`}
          >
            {/* RPM grid */}
            {rpmTicks.map((tick) => (
              <g key={tick}>
                <line
                  x1={PLOT.left}
                  x2={PLOT.right}
                  y1={yFor(tick)}
                  y2={yFor(tick)}
                  stroke="rgba(255,255,255,0.06)"
                  strokeWidth="1"
                />
                <text
                  x={PLOT.left - 10}
                  y={yFor(tick) + 3.5}
                  textAnchor="end"
                  className="fill-ash-500 font-mono text-[10px]"
                >
                  {tick}
                </text>
              </g>
            ))}

            {/* Maximum speed, as the firmware reports it */}
            <line
              x1={PLOT.left}
              x2={PLOT.right}
              y1={yFor(HI_RPM)}
              y2={yFor(HI_RPM)}
              stroke="rgba(140,245,253,0.28)"
              strokeWidth="1"
              strokeDasharray="2 4"
            />
            <text
              x={PLOT.right}
              y={yFor(HI_RPM) - 7}
              textAnchor="end"
              className="fill-ash-500 font-mono text-[10px]"
            >
              F0Mx {HI_RPM}
            </text>

            {/* Temperature axis */}
            {gradientStops.map((stop) => (
              <text
                key={stop.temp}
                x={xFor(stop.temp)}
                y={PLOT.bottom + 20}
                textAnchor="middle"
                className="fill-ash-500 font-mono text-[10px]"
              >
                {stop.label}
              </text>
            ))}

            {/* Ramp band */}
            <rect
              x={xFor(T_MIN)}
              y={PLOT.top}
              width={xFor(T_MAX) - xFor(T_MIN)}
              height={PLOT.bottom - PLOT.top}
              fill="rgba(140,245,253,0.05)"
            />
            <line
              x1={xFor(T_MIN)}
              x2={xFor(T_MIN)}
              y1={PLOT.top}
              y2={PLOT.bottom}
              stroke="rgba(255,255,255,0.14)"
              strokeWidth="1"
            />
            <line
              x1={xFor(T_MAX)}
              x2={xFor(T_MAX)}
              y1={PLOT.top}
              y2={PLOT.bottom}
              stroke="rgba(255,255,255,0.14)"
              strokeWidth="1"
            />
            <text x={xFor(T_MIN) + 6} y={PLOT.top + 14} className="fill-ash-400 font-mono text-[10px]">
              Tmin {T_MIN}
            </text>
            <text x={xFor(T_MAX) + 6} y={PLOT.top + 14} className="fill-ash-400 font-mono text-[10px]">
              Tmax {T_MAX}
            </text>

            {/* Thermal floor */}
            <line
              x1={xFor(FLOOR)}
              x2={xFor(FLOOR)}
              y1={PLOT.top}
              y2={PLOT.bottom}
              stroke="rgba(140,245,253,0.55)"
              strokeWidth="1"
              strokeDasharray="4 4"
            />
            <text
              x={xFor(FLOOR) - 6}
              y={PLOT.bottom - 8}
              textAnchor="end"
              className="fill-aqua-300 font-mono text-[10px]"
            >
              floor {FLOOR}
            </text>

            {/* Handed back to macOS below Tmin */}
            <line
              x1={xFor(TEMP_LO)}
              x2={xFor(T_MIN)}
              y1={yFor(0)}
              y2={yFor(0)}
              stroke="rgba(255,255,255,0.28)"
              strokeWidth="1.5"
              strokeDasharray="5 5"
            />

            {/* The ramp itself */}
            <path
              d={`M${xFor(T_MIN)} ${yFor(LO_RPM)} L${xFor(T_MAX)} ${yFor(HI_RPM)} L${xFor(TEMP_HI)} ${yFor(HI_RPM)}`}
              fill="none"
              stroke="var(--color-aqua-500)"
              strokeWidth="2.5"
              strokeLinecap="round"
            />
            <circle cx={xFor(T_MIN)} cy={yFor(LO_RPM)} r="3" fill="var(--color-aqua-500)" />

            {/* Trail of recent operating points */}
            <path ref={trailRef} fill="none" stroke="rgba(169,248,254,0.38)" strokeWidth="1.5" d="" />

            {/* Current operating point */}
            <line
              ref={dropVRef}
              x1={staticX}
              x2={staticX}
              y1={PLOT.top}
              y2={staticY}
              stroke="rgba(255,255,255,0.16)"
              strokeWidth="1"
            />
            <line
              ref={dropHRef}
              x1={PLOT.left}
              x2={staticX}
              y1={staticY}
              y2={staticY}
              stroke="rgba(255,255,255,0.16)"
              strokeWidth="1"
            />
            <circle
              ref={markerRingRef}
              cx={staticX}
              cy={staticY}
              r="10"
              fill="rgba(140,245,253,0.12)"
            />
            <circle
              ref={markerRef}
              cx={staticX}
              cy={staticY}
              r="4.5"
              fill="var(--color-aqua-500)"
            />
          </svg>
        </div>
      </div>

      <div className="grid gap-5 sm:grid-cols-2">
        <div className="core-flat p-4">
          <div className="flex items-baseline gap-2">
            <span ref={tempRef} className="font-mono text-3xl tracking-tight text-ash-100">
              {baseTemp(workload).toFixed(1)}
            </span>
            <span className="font-mono text-[13px] text-ash-400">C</span>
          </div>
          <p className="mt-1 text-[12.5px] text-ash-400">Smoothed temperature</p>

          <div className="mt-5 flex items-baseline gap-2">
            <span ref={rpmRef} className="font-mono text-3xl tracking-tight text-aqua-300">
              {Math.round(staticState.rpm)}
            </span>
            <span className="font-mono text-[13px] text-ash-400">RPM</span>
          </div>
          <p ref={hintRef} className="mt-1 text-[12.5px] text-ash-400">
            {MODE_HINT[staticState.mode]}
          </p>
        </div>

        <div className="core-flat flex flex-col justify-between gap-4 p-4">
          <div>
            <p className="font-mono text-[11px] text-ash-500">Workload</p>
            <div className="mt-3 flex gap-2">
              {PRESETS.map((preset) => (
                <button
                  key={preset.label}
                  type="button"
                  onClick={() => setWorkload(preset.workload)}
                  aria-pressed={workload === preset.workload}
                  className="rounded-full border border-white/[0.1] px-3 py-1 text-[12px] tracking-tight text-ash-300 transition-colors duration-300 ease-swift hover:bg-white/[0.05] hover:text-ash-100 aria-[pressed=true]:border-aqua-700/50 aria-[pressed=true]:bg-aqua-950/35 aria-[pressed=true]:text-aqua-300"
                >
                  {preset.label}
                </button>
              ))}
            </div>
          </div>
          <div>
            <input
              type="range"
              min={0}
              max={100}
              step={1}
              value={workload}
              onChange={(event) => setWorkload(Number(event.target.value))}
              aria-label="Simulated workload"
              className="slider"
            />
            <div className="mt-1 flex justify-between font-mono text-[11px] text-ash-500">
              <span>idle</span>
              <span>{workload}%</span>
              <span>saturated</span>
            </div>
          </div>
        </div>
      </div>

      <div className="flex flex-wrap items-center gap-2">
        <span className="font-mono text-[11px] text-ash-500">Sensor</span>
        {curve.sensors.map((entry, index) => (
          <button
            key={entry.key}
            type="button"
            onClick={() => setSensorIndex(index)}
            aria-pressed={index === sensorIndex}
            className="rounded-full border border-white/[0.09] px-3 py-1 font-mono text-[11.5px] tracking-tight text-ash-400 transition-colors duration-300 ease-swift hover:bg-white/[0.05] hover:text-ash-100 aria-[pressed=true]:border-white/[0.18] aria-[pressed=true]:bg-white/[0.06] aria-[pressed=true]:text-ash-100"
          >
            {entry.key}
          </button>
        ))}
        <span className="font-mono text-[11px] text-ash-500">
          {sensor.name}, {sensor.group}
        </span>
      </div>

      <p className="font-mono text-[11.5px] leading-relaxed text-ash-500">
        Live model of the shipped ramp maths. Values are simulated; the fan range
        {""} {LO_RPM} to {HI_RPM} RPM is measured on a MacBook Pro Mac17,9.
      </p>
    </div>
  );
}
