//
//  SensorsView.swift
//  AutoFansMac
//
//  R1: every temperature (plus voltage/power/current as secondary groups) with its
//  friendly name, SMC key, live value and unit (PROMPT.md §6.1).
//
//  Grouped as Temperature → CPU/GPU/SOC/Storage/Battery/System/Unknown, then Voltage,
//  Power, Current, Fans. Unknown keys display their raw FourCC and can be hidden.
//

import SwiftUI
import SMCKit

struct SensorsView: View {
    @EnvironmentObject private var env: AppEnvironment
    @AppStorage(SettingsKey.temperatureUnit) private var temperatureUnitRaw = TemperatureUnit.celsius.rawValue
    @AppStorage(SettingsKey.showUnknownSensors) private var showUnknownSensors = true

    @State private var searchText = ""
    @State private var expandedTypes: Set<SensorType> = [.temperature, .fan]
    @State private var expandedGroups: Set<String> = ["CPU", "GPU", "HID"]

    private var temperatureUnit: TemperatureUnit {
        TemperatureUnit(rawValue: temperatureUnitRaw) ?? .celsius
    }

    /// Keys currently tracked by any fan curve — those rows are highlighted.
    private var trackedKeys: Set<String> {
        Set(env.fans.desiredSettings.compactMap { $0.mode == .sensor ? $0.sensorKey : nil })
    }

    private var filteredSamples: [SensorSample] {
        var samples = env.sensors.samples
        if !showUnknownSensors {
            samples = samples.filter { $0.isKnown }
        }
        let query = searchText.trimmingCharacters(in: .whitespaces).lowercased()
        if !query.isEmpty {
            samples = samples.filter {
                $0.name.lowercased().contains(query) || $0.key.lowercased().contains(query)
            }
        }
        return samples
    }

    /// A sensor type and its groups.
    ///
    /// Structs rather than tuples, deliberately: `ForEach` wants stable `Identifiable`
    /// identity, and tuples with key-path ids are not something SwiftUI's diffing handles
    /// well — it sits right next to the kind of internal confusion that produced
    /// `-[NSTaggedPointerString count]: unrecognized selector`.
    private struct SensorTypeSection: Identifiable {
        let type: SensorType
        let groups: [SensorGroupSection]
        var id: SensorType { type }
    }

    private struct SensorGroupSection: Identifiable {
        let group: SensorGroup
        let samples: [SensorSample]
        var id: SensorGroup { group }
    }

    private var grouped: [SensorTypeSection] {
        let byType = Dictionary(grouping: filteredSamples, by: { $0.type })
        return byType.keys.sorted { $0.sortOrder < $1.sortOrder }.map { type in
            let samples = byType[type] ?? []
            let byGroup = Dictionary(grouping: samples, by: { $0.group })
            let groups = byGroup.keys.sorted { $0.sortOrder < $1.sortOrder }.map { group in
                SensorGroupSection(
                    group: group,
                    samples: (byGroup[group] ?? []).sorted { lhs, rhs in
                        if lhs.isComputed != rhs.isComputed { return !lhs.isComputed }
                        return lhs.name.localizedStandardCompare(rhs.name) == .orderedAscending
                    }
                )
            }
            return SensorTypeSection(type: type, groups: groups)
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            toolbar
            Divider()
            content
        }
        .navigationTitle("Sensors")
        // Not a @Published assignment: that would mutate observable state during the view
        // update that is running when onAppear fires.
        .onAppear { env.sensors.setDetailedPolling(true) }
        .onDisappear { env.sensors.setDetailedPolling(false) }
    }

    private var toolbar: some View {
        HStack(spacing: 10) {
            Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
            TextField("Filter by name or key", text: $searchText)
                .textFieldStyle(.plain)

            Spacer()

            if env.sensors.isScanning {
                ProgressView().controlSize(.small)
            }
            Text("\(filteredSamples.count) values · \(env.sensors.lastScan?.scannedKeyCount ?? 0) keys · "
                 + "\(String(format: "%.0f", env.sensors.scanDuration * 1000)) ms")
                .font(.caption)
                .foregroundStyle(.secondary)
                .monospacedDigit()

            Toggle("Unknown", isOn: $showUnknownSensors)
                .toggleStyle(.checkbox)
                .help("Show keys that are not in the sensor catalog")

            Picker("", selection: $temperatureUnitRaw) {
                Text("°C").tag(TemperatureUnit.celsius.rawValue)
                Text("°F").tag(TemperatureUnit.fahrenheit.rawValue)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .frame(width: 80)

            Button {
                env.sensors.rescanEverything()
            } label: {
                Label("Rescan", systemImage: "arrow.clockwise")
            }
            .help("Re-enumerate every SMC key (a full sweep takes about a second)")
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    @ViewBuilder
    private var content: some View {
        if filteredSamples.isEmpty {
            VStack(spacing: 8) {
                Text(env.sensors.samples.isEmpty ? "Reading sensors…" : "No sensors match “\(searchText)”")
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            List {
                ForEach(grouped) { section in
                    Section {
                        if expandedTypes.contains(section.type) {
                            ForEach(section.groups) { group in
                                groupRows(type: section.type, group: group.group, samples: group.samples)
                            }
                        }
                    } header: {
                        typeHeader(section.type, sampleCount: section.groups.reduce(0) { $0 + $1.samples.count })
                    }
                }
            }
            .listStyle(.inset)
        }
    }

    private func typeHeader(_ type: SensorType, sampleCount: Int) -> some View {
        Button {
            if expandedTypes.contains(type) { expandedTypes.remove(type) } else { expandedTypes.insert(type) }
        } label: {
            HStack(spacing: 6) {
                Image(systemName: expandedTypes.contains(type) ? "chevron.down" : "chevron.right")
                    .font(.caption2)
                Text(type.displayName.uppercased()).font(.caption.weight(.semibold))
                Text("(\(sampleCount))").font(.caption2).foregroundStyle(.secondary)
                Spacer()
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    @ViewBuilder
    private func groupRows(type: SensorType, group: SensorGroup, samples: [SensorSample]) -> some View {
        let groupKey = "\(type.rawValue).\(group.rawValue)"
        DisclosureGroup(isExpanded: Binding(
            get: { expandedGroups.contains(groupKey) },
            set: { isOpen in
                if isOpen { expandedGroups.insert(groupKey) } else { expandedGroups.remove(groupKey) }
            }
        )) {
            ForEach(samples) { sample in
                SensorRow(
                    sample: sample,
                    unit: temperatureUnit,
                    isTracked: trackedKeys.contains(sample.key),
                    isHot: sample.type == .temperature && sample.rawValue >= AppSettings.thermalFloorCelsius
                )
            }
        } label: {
            HStack {
                Text(group.rawValue).font(.callout.weight(.medium))
                Text("\(samples.count)").font(.caption2).foregroundStyle(.secondary)
            }
        }
    }
}

/// One sensor row: name, key, value, and the tracked/hot indicators.
struct SensorRow: View {
    let sample: SensorSample
    let unit: TemperatureUnit
    let isTracked: Bool
    let isHot: Bool

    var body: some View {
        HStack(spacing: 8) {
            Text(sample.name)
                .lineLimit(1)
                .truncationMode(.middle)
                .help(sample.isKnown ? sample.name : "\(sample.key) is not in the sensor catalog")

            if isTracked {
                Image(systemName: "target")
                    .font(.caption2)
                    .foregroundStyle(Color.accentColor)
                    .help("A fan curve tracks this sensor")
            }

            Spacer(minLength: 8)

            Text(sample.dataType.trimmingCharacters(in: .whitespaces))
                .font(.caption2.monospaced())
                .foregroundStyle(.tertiary)
                .frame(width: 46, alignment: .trailing)

            Text(sample.key)
                .font(.caption.monospaced())
                .foregroundStyle(.secondary)
                .frame(width: 52, alignment: .trailing)

            Text(sample.displayValue(in: unit))
                .font(.callout.monospacedDigit())
                .foregroundStyle(isHot ? Color.red : Color.primary)
                .frame(width: 96, alignment: .trailing)
        }
        .padding(.vertical, 1)
    }
}
