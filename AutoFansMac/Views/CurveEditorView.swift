//
//  CurveEditorView.swift
//  AutoFansMac
//
//  Live curve preview for the sensor-based fan mode (PROMPT.md §6.2, §6.3).
//
//  x-axis: sensor temperature from Tmin − 10 to Tmax + 10
//  y-axis: RPM from the fan's min to its max
//  The chart also marks where the sensor is now and the RPM currently being commanded,
//  so the ramp can be verified at a glance without reading numbers.
//

import SwiftUI
import Charts
import SMCKit

struct CurvePreview: View {
    let setting: FanSetting
    let fan: FanDescriptor
    let currentTemperature: Double?
    let currentTarget: Double?
    let unit: TemperatureUnit

    /// One sampled point on the drawn curve.
    private struct CurvePlotPoint: Identifiable {
        let temperature: Double
        let rpm: Double
        var id: Double { temperature }
    }

    /// Sampled curve for the chart.
    private var points: [CurvePlotPoint] {
        let lo = setting.startRPM ?? max(fan.minRPM, SafetyBounds.absoluteMinimumRPM)
        let hi = setting.capRPM ?? (fan.maxRPM > 0 ? fan.maxRPM : lo + 1_000)
        let lower = setting.minTemp - 10
        let upper = setting.maxTemp + 10
        let steps = 40
        return (0...steps).map { index in
            let temperature = lower + (upper - lower) * Double(index) / Double(steps)
            // Below Tmin the fan is handed back to macOS (which idles it at 0 RPM), so the
            // chart shows that rather than pretending it sits at the fan's minimum.
            let released = setting.startRPM == nil && temperature < setting.minTemp
            let rpm = released ? 0 : CurveMath.targetRPM(
                temperature: temperature,
                minTemp: setting.minTemp,
                maxTemp: setting.maxTemp,
                startRPM: lo,
                capRPM: hi
            )
            return CurvePlotPoint(temperature: temperature, rpm: rpm)
        }
    }

    private var lo: Double { setting.startRPM ?? max(fan.minRPM, SafetyBounds.absoluteMinimumRPM) }
    private var hi: Double { setting.capRPM ?? (fan.maxRPM > 0 ? fan.maxRPM : lo + 1_000) }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Chart {
                ForEach(points) { point in
                    LineMark(
                        x: .value("Temperature", unit.convert(point.temperature)),
                        y: .value("RPM", point.rpm)
                    )
                    .interpolationMethod(.linear)
                    .foregroundStyle(Color.accentColor)
                }

                // Tmin / Tmax guide lines.
                // Both threshold labels sit at the TOP and grow *outward* — Tmin's to the left
                // of its line, Tmax's to the right of its.
                //
                // Two earlier layouts were wrong in ways worth remembering:
                //   * both at `.top` growing inward → they met in the middle and overlapped;
                //   * Tmin moved to `.bottom` → it landed on the x-axis tick labels.
                // Growing outward is not a matter of taste: Tmin < Tmax always (validated), so
                // a label ending at the Tmin line and one starting at the Tmax line cannot
                // intersect, at any spacing.
                RuleMark(x: .value("Tmin", unit.convert(setting.minTemp)))
                    .lineStyle(StrokeStyle(lineWidth: 1, dash: [3, 3]))
                    .foregroundStyle(.secondary)
                    .annotation(position: .top, alignment: .trailing) {
                        // Deliberately just the number: the fields right above the chart show
                        // the same values, and a sentence here was what caused the collision.
                        Text("Tmin \(Int(unit.convert(setting.minTemp)))°")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                RuleMark(x: .value("Tmax", unit.convert(setting.maxTemp)))
                    .lineStyle(StrokeStyle(lineWidth: 1, dash: [3, 3]))
                    .foregroundStyle(.secondary)
                    .annotation(position: .top, alignment: .leading) {
                        Text("Tmax \(Int(unit.convert(setting.maxTemp)))°")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }

                // Where the tracked sensor is right now. The rule carries no label of its own:
                // a moving label will sooner or later land on a threshold label, so its value
                // is reported in the line under the chart instead.
                if let currentTemperature {
                    RuleMark(x: .value("Current", unit.convert(currentTemperature)))
                        .lineStyle(StrokeStyle(lineWidth: 1.5))
                        .foregroundStyle(.orange)
                }

                // The RPM we are currently commanding.
                if let currentTarget {
                    PointMark(
                        x: .value("Temp", unit.convert(currentTemperature ?? setting.minTemp)),
                        y: .value("Target", currentTarget)
                    )
                    .symbolSize(60)
                    .foregroundStyle(.green)
                }
            }
            .chartYScale(domain: 0...max(hi, 1))
            .chartXAxisLabel("\(unit.symbol) · \(fan.displayName)")
            .chartYAxisLabel("RPM")
        }
    }
}
