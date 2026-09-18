//
//  FansView.swift
//  AutoFansMac
//
//  R2-R4: every detected fan with Min/Current/Max and its mode, plus the controls to
//  pin a constant RPM or attach a sensor-based curve (PROMPT.md §6.2).
//
//  Apply semantics: changes take effect immediately (no Save button) with a 0.5 s
//  debounce while a slider is being dragged, and every command reports a transient
//  status: Applying… → Active ✓ / Failed (with the reason).
//

import SwiftUI
import SMCKit

struct FansView: View {
    @EnvironmentObject private var env: AppEnvironment
    @AppStorage(SettingsKey.temperatureUnit) private var temperatureUnitRaw = TemperatureUnit.celsius.rawValue

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 14) {
                header

                if env.fans.snapshot.fans.isEmpty {
                    fanlessState
                } else {
                    ForEach(env.fans.states) { state in
                        FanCardView(state: state)
                    }
                }
            }
            .padding(16)
        }
        .navigationTitle("Fans")
        .toolbar {
            ToolbarItem(placement: .automatic) {
                Button {
                    Task { @MainActor in await env.setAutomatic() }
                } label: {
                    Label("Automatic", systemImage: "arrow.triangle.2.circlepath")
                }
                .help("Return every fan to macOS control")
            }
            ToolbarItem(placement: .automatic) {
                Button {
                    Task { @MainActor in await env.setFullBlast() }
                } label: {
                    Label("Full Blast", systemImage: "wind")
                }
                .help("Drive every fan to its maximum RPM")
            }
        }
    }

    private var temperatureUnit: TemperatureUnit {
        TemperatureUnit(rawValue: temperatureUnitRaw) ?? .celsius
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(env.fans.snapshot.fans.isEmpty
                 ? "No fans detected"
                 : "\(env.fans.snapshot.fanCount) fan\(env.fans.snapshot.fanCount == 1 ? "" : "s") detected")
                .font(.title2.weight(.semibold))
            Text("\(env.platform.modelIdentifier) · \(env.platform.chipName) · "
                 + "profile “\(env.profiles.activeProfileName)” · "
                 + "mode keys \(env.fans.snapshot.modeKeyIsLowercase ? "lowercase" : "uppercase")"
                 + (env.fans.snapshot.hasFtst ? " · unlock key present" : ""))
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    /// Fanless Macs (MacBook Air M1) are a supported configuration, not an error (N7).
    private var fanlessState: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label("No fans detected on this Mac", systemImage: "fan.slash")
                .font(.headline)
            Text("`FNum` reports 0 fans, which is normal on fanless models. Sensor monitoring "
                 + "works exactly as on a machine with fans.")
                .font(.callout)
                .foregroundStyle(.secondary)
            Button("Open Sensors") { env.selection = .sensors }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.secondary.opacity(0.08), in: RoundedRectangle(cornerRadius: 10))
    }
}

// MARK: - Fan card

struct FanCardView: View {
    @EnvironmentObject private var env: AppEnvironment
    let state: FanState

    @AppStorage(SettingsKey.temperatureUnit) private var temperatureUnitRaw = TemperatureUnit.celsius.rawValue

    @State private var constantRPM: Double = 0
    @State private var minTemp: Double = 50
    @State private var maxTemp: Double = 80
    /// The sensor this fan's curve tracks, straight from the model. There is deliberately no
    /// local copy: a second source of truth is what made the old Picker need two clicks.
    private var trackedSensorKey: String { state.setting.sensorKey ?? "" }
    @State private var debounceTask: Task<Void, Never>?
    @State private var localStatus: String?
    @State private var hasSeeded = false

    private var temperatureUnit: TemperatureUnit {
        TemperatureUnit(rawValue: temperatureUnitRaw) ?? .celsius
    }

    private var fan: FanDescriptor { state.descriptor }

    private var sliderRange: ClosedRange<Double> {
        let lower = max(fan.minRPM, SafetyBounds.absoluteMinimumRPM)
        let upper = fan.maxRPM > lower ? fan.maxRPM : lower + 1_000
        return lower...upper
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            header
            Divider()
            modePicker

            switch state.setting.mode {
            case .auto:
                autoSection
            case .constant:
                constantSection
            case .sensor:
                sensorSection
            }

            statusRow
        }
        .padding(14)
        .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 12))
        .overlay(
            RoundedRectangle(cornerRadius: 12)
                .stroke(state.statusIsProblem ? Color.red.opacity(0.55) : Color.secondary.opacity(0.18))
        )
        .onAppear(perform: seedFromState)
        // Deferred: `seedFromState` writes @State, and onChange runs inside the update.
        // Only on a mode change: re-seeding on every setting change overwrote the fields the
        // user was typing into, and made the card look like it was fighting them.
        .onChange(of: state.setting.mode) { _ in deferToNextRunLoop { seedFromState() } }
    }

    // MARK: Header

    private var header: some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(fan.displayName).font(.headline)
                Text("\(fan.actualKey) · \(fan.valueType.trimmingCharacters(in: .whitespaces)) · mode key \(fan.modeKey)")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            VStack(alignment: .trailing, spacing: 2) {
                Text("\(Int(fan.currentRPM)) RPM")
                    .font(.system(size: 26, weight: .semibold, design: .rounded))
                    .monospacedDigit()
                statusBadge
            }
        }
    }

    private var statusBadge: some View {
        Text(state.statusText)
            .font(.caption.weight(.medium))
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(badgeColor.opacity(0.18), in: Capsule())
            .foregroundStyle(badgeColor)
    }

    private var badgeColor: Color {
        if state.isSafetyOverride { return .red }
        switch state.commandState {
        case .active: return .green
        case .applying: return .orange
        case .failed, .unresponsive: return .red
        case .idle: return .secondary
        }
    }

    // MARK: Mode

    private var modePicker: some View {
        Picker("Mode", selection: Binding(
            get: { state.setting.mode },
            set: { newMode in
                Task { @MainActor in await env.setFanMode(newMode, fanIndex: fan.index) }
            }
        )) {
            ForEach(FanControlMode.allCases) { mode in
                Text(mode.displayName).tag(mode)
            }
        }
        .pickerStyle(.segmented)
        .labelsHidden()
    }

    private var autoSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            readouts
            Text("macOS controls this fan. AutoFansMac only reads it.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private var constantSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            readouts

            HStack {
                Text("Target").frame(width: 60, alignment: .leading)
                Slider(value: $constantRPM, in: sliderRange, step: 50) { editing in
                    if !editing { applyConstant() }
                }
                TextField("RPM", value: $constantRPM, format: .number.precision(.fractionLength(0)))
                    .frame(width: 72)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit(applyConstant)
                Text("RPM").font(.caption).foregroundStyle(.secondary)
                Button("Full blast") {
                    constantRPM = fan.maxRPM
                    applyConstant()
                }
                .help("Set this fan to its maximum RPM")
            }

            if isClampedByPolicy(constantRPM) {
                Label("Clamped to the fan's safe range (\(Int(sliderRange.lowerBound))–\(Int(sliderRange.upperBound)) RPM).",
                      systemImage: "exclamationmark.triangle")
                    .font(.caption)
                    .foregroundStyle(.orange)
            }
            Text("Value is applied immediately; dragging is debounced by 0.5 s.")
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
        .onChange(of: constantRPM) { _ in scheduleConstant() }
    }

    private var sensorSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            readouts

            HStack(spacing: 10) {
                Text("Sensor").frame(width: 60, alignment: .leading)
                SensorPicker(selection: trackedSensorKey) { key, name in
                    applyCurve(sensorKey: key, name: name)
                }
            }
            .id("curve-sensor-\(fan.index)")

            HStack(spacing: 10) {
                Text("Tmin").frame(width: 60, alignment: .leading)
                TemperatureField(celsius: $minTemp, unit: temperatureUnit)
                Text("Tmax")
                TemperatureField(celsius: $maxTemp, unit: temperatureUnit)
                if minTemp >= maxTemp {
                    Label("Tmin must be below Tmax", systemImage: "exclamationmark.triangle")
                        .font(.caption)
                        .foregroundStyle(.red)
                }
            }

            CurvePreview(
                setting: state.setting,
                fan: fan,
                currentTemperature: env.sensors.sample(forKey: trackedSensorKey)?.rawValue,
                currentTarget: env.curveEngine.lastAppliedRPM(fanIndex: fan.index),
                unit: temperatureUnit
            )
            .frame(height: 150)

            if env.curveEngine.isSensorLost(fanIndex: fan.index) {
                Label("Tracked sensor is unreadable — the fan is being held at maximum as a fail-safe.",
                      systemImage: "exclamationmark.triangle.fill")
                    .font(.caption)
                    .foregroundStyle(.red)
            }

            HStack(spacing: 10) {
                Button("Apply curve") {
                    let key = trackedSensorKey.isEmpty
                        ? (env.defaultCurveSensor()?.key ?? SensorScanner.ComputedKey.cpuHottest)
                        : trackedSensorKey
                    applyCurve(sensorKey: key, name: env.sensors.sample(forKey: key)?.name)
                }
                .buttonStyle(.borderedProminent)
                // One live line instead of labels on the chart: the tracked temperature, where
                // it sits relative to the ramp, and what is being commanded.
                Text(curveSummary)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
        // The Tmin/Tmax fields used to be inert until "Apply curve" was pressed, so editing them
        // and quitting lost the edit: they looked live and were not. Everything else on this
        // screen applies as you go, and now they do too.
        .onChange(of: minTemp) { _ in scheduleCurve() }
        .onChange(of: maxTemp) { _ in scheduleCurve() }
    }

    private var readouts: some View {
        HStack(spacing: 18) {
            readout("Min", fan.minRPM)
            readout("Current", fan.currentRPM)
            readout("Max", fan.maxRPM)
            if let target = state.targetRPM {
                readout("Target", target)
            }
            Spacer()
        }
    }

    private func readout(_ label: String, _ value: Double) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(label).font(.caption2).foregroundStyle(.secondary)
            Text("\(Int(value))").font(.callout.monospacedDigit())
        }
    }

    @ViewBuilder
    private var statusRow: some View {
        if let message = localStatus ?? state.message {
            Text(message)
                .font(.caption)
                .foregroundStyle(state.statusIsProblem ? .red : .secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        if !fan.warnings.isEmpty {
            VStack(alignment: .leading, spacing: 2) {
                ForEach(fan.warnings, id: \.self) { warning in
                    Label(warning, systemImage: "info.circle")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    // MARK: Actions

    /// "Now 42.1 °C · below Tmin 50 °C — macOS controls the fan" or
    /// "Now 61.0 °C · ramp 50 → 75 °C · 3 200 RPM".
    private var curveSummary: String {
        let setting = state.setting
        let temperature = env.sensors.sample(forKey: trackedSensorKey)?.rawValue
        let now = temperature.map { String(format: "%.1f °C", $0) } ?? "no reading"

        let ramp = "ramp \(Int(setting.minTemp)) → \(Int(setting.maxTemp)) °C"
        let released = setting.mode == .sensor
            && state.descriptor.hardwareMode.isAutomatic
            && setting.startRPM == nil

        if released {
            return "Now \(now) · below Tmin — macOS controls the fan"
        }
        if let target = env.curveEngine.lastAppliedRPM(fanIndex: fan.index) {
            return "Now \(now) · \(ramp) · \(Int(target)) RPM"
        }
        return "Now \(now) · \(ramp)"
    }

    private func seedFromState() {
        let setting = state.setting
        constantRPM = setting.mode == .constant
            ? setting.rpm.resolved(maxRPM: fan.maxRPM)
            : max(fan.currentRPM, sliderRange.lowerBound)
        minTemp = setting.minTemp
        maxTemp = setting.maxTemp
        hasSeeded = true
    }

    private func isClampedByPolicy(_ rpm: Double) -> Bool {
        env.fans.isClamped(rpm: rpm, fan: fan)
    }

    /// Debounced Tmin/Tmax application (0.5 s while typing), mirroring the RPM slider.
    private func scheduleCurve() {
        guard hasSeeded, state.setting.mode == .sensor else { return }
        guard !trackedSensorKey.isEmpty else { return }
        guard minTemp < maxTemp else { return }        // half-typed values are not applied
        debounceTask?.cancel()
        debounceTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: 500_000_000)
            guard !Task.isCancelled else { return }
            applyCurve(sensorKey: trackedSensorKey, name: env.sensors.sample(forKey: trackedSensorKey)?.name)
        }
    }

    /// Debounced slider application (0.5 s while dragging).
    private func scheduleConstant() {
        guard hasSeeded, state.setting.mode == .constant else { return }
        debounceTask?.cancel()
        debounceTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: 500_000_000)
            guard !Task.isCancelled else { return }
            applyConstant()
        }
    }

    private func applyConstant() {
        debounceTask?.cancel()
        localStatus = "Applying…"
        Task { @MainActor in
            let result = await env.fans.setConstant(fanIndex: fan.index, rpm: constantRPM)
            switch result {
            case .success(let statuses):
                let status = statuses.first { $0.index == fan.index }
                localStatus = status?.state == .unresponsive
                    ? "Active, but the fan did not respond (see Diagnostics)."
                    : "Active"
                env.persistCurrentSettingsIntoProfile()
            case .failure(let error):
                localStatus = "Failed — \(error.localizedDescription)"
            }
        }
    }

    private func applyCurve(sensorKey: String, name: String?) {
        guard minTemp < maxTemp else {
            localStatus = "Tmin must be below Tmax."
            return
        }

        // Applying an identical curve is a no-op. Without this, any redraw that looked like a
        // selection change re-commanded the fan, whose publish triggered another redraw — an
        // endless command→publish→redraw loop, one XPC round trip per iteration.
        let current = env.fans.setting(for: fan.index)
        guard current.differsFromCurve(sensorKey: sensorKey, minTemp: minTemp, maxTemp: maxTemp) else {
            localStatus = "Curve active (Tmin \(Int(minTemp)) °C → Tmax \(Int(maxTemp)) °C)"
            return
        }

        localStatus = "Applying…"
        Task { @MainActor in
            _ = await env.fans.setCurve(
                fanIndex: fan.index,
                sensorKey: sensorKey,
                sensorName: name,
                minTemp: minTemp,
                maxTemp: maxTemp
            )
            await env.reapplyDesiredState(reason: "curve changed")
            env.persistCurrentSettingsIntoProfile()
            localStatus = "Curve active (Tmin \(Int(minTemp)) °C → Tmax \(Int(maxTemp)) °C)"
        }
    }
}

// MARK: - Supporting controls

/// Grouped sensor menu: computed aggregates first, then every live temperature sensor.
/// Sensor chooser for a fan curve.
///
/// A `Menu` of commands rather than a `Picker`.
///
/// A Picker owns *selection state* that has to agree with the model, and the two drift apart:
/// the model is updated a run-loop turn later (so the card can apply a debounce), and when the
/// framework decides the selection matches none of its tags it writes a value back that looks
/// exactly like the user clicking. The visible symptom was "I have to click twice — the first
/// click jumps back".
///
/// A menu of buttons has no selection to drift: the label *displays* the applied sensor and
/// each item is an explicit command. It also does not rebuild when the selection changes.
///
/// Options come from `SensorService.lastScan` — a full-sweep snapshot that changes rarely —
/// rather than the live sample list, which is replaced on every poll tick.
struct SensorPicker: View {
    @EnvironmentObject private var env: AppEnvironment
    /// The sensor the fan's curve currently tracks; displayed, never written.
    let selection: String
    var onSelect: (String, String?) -> Void

    /// Computed aggregates first, then the known sensors grouped by area.
    private var computed: [SensorSample] {
        (env.sensors.lastScan?.samples ?? []).filter { $0.isComputed && $0.type == .temperature }
    }

    private var groups: [SensorGroup: [SensorSample]] {
        Dictionary(grouping: (env.sensors.lastScan?.temperatureSamples ?? []).filter { !$0.isComputed && $0.isKnown },
                   by: { $0.group })
    }

    /// The tracked sensor when the current sweep does not list it — a profile made on another
    /// Mac, or a sensor that has since gone away. Shown so the menu is never lying about what
    /// is being tracked, and because the label needs a name for it.
    private var selectionOutsideTheScan: String? {
        guard !selection.isEmpty else { return nil }
        if computed.contains(where: { $0.key == selection }) { return nil }
        if groups.values.contains(where: { group in group.contains(where: { $0.key == selection }) }) {
            return nil
        }
        return selection
    }

    private var selectionName: String {
        if selection.isEmpty { return "Choose sensor…" }
        if let sample = env.sensors.sample(forKey: selection) { return sample.name }
        if let entry = SensorCatalog.entry(for: selection, generation: env.platform.generation) {
            return SensorCatalog.expand(name: entry.name, pattern: entry.key, key: selection)
        }
        return selection
    }

    var body: some View {
        Menu {
            if let missing = selectionOutsideTheScan {
                Section("Tracked") {
                    Button(selectionName) { choose(missing) }
                }
            }
            if !computed.isEmpty {
                Section("Computed") {
                    ForEach(computed) { sample in
                        Button(sample.name) { choose(sample.key) }
                    }
                }
            }
            ForEach(groups.keys.sorted(by: { $0.sortOrder < $1.sortOrder }), id: \.self) { group in
                Section(group.rawValue) {
                    ForEach(groups[group]?.sorted { $0.name < $1.name } ?? []) { sample in
                        Button("\(sample.name)  (\(sample.key))") { choose(sample.key) }
                    }
                }
            }
        } label: {
            HStack(spacing: 6) {
                Text(selectionName).lineLimit(1).truncationMode(.middle)
                Spacer(minLength: 4)
                Image(systemName: "chevron.up.chevron.down").font(.caption2)
            }
        }
        .menuStyle(.borderlessButton)
        .frame(maxWidth: 320, alignment: .leading)
        .help("Sensor this fan's curve tracks")
    }

    private func choose(_ key: String) {
        // Only an actual click reaches here, so no idempotence check is needed for the UI's
        // sake — `applyCurve` still refuses to re-command an identical curve.
        let name = env.sensors.sample(forKey: key)?.name
        onSelect(key, name)
    }
}

/// A temperature entry that displays and edits in the user's unit while storing °C.
struct TemperatureField: View {
    @Binding var celsius: Double
    let unit: TemperatureUnit

    var body: some View {
        HStack(spacing: 3) {
            TextField("", value: Binding(
                get: { unit.convert(celsius) },
                set: { celsius = unit.toCelsius($0) }
            ), format: .number.precision(.fractionLength(0)))
            .frame(width: 58)
            .textFieldStyle(.roundedBorder)
            Text(unit.symbol).font(.caption).foregroundStyle(.secondary)
        }
    }
}
