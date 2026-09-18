//
//  SensorService.swift
//  AutoFansMac
//
//  The polling loop behind the Sensors view and the curve engine (PROMPT.md §5.4).
//
//  Cost control (requirement N6 — ≤ ~1-2 % CPU at 1 Hz):
//    * one FULL sweep at launch and on demand (enumerate every key, ~1 s once, then
//      cached key metadata makes repeats ~30 ms),
//    * a HOT subset polled every tick — known temperature keys plus fan keys plus
//      whatever the active curves track (~10 ms),
//    * the DETAILED set (every temperature/voltage/power/current key) only while a
//      window that shows all sensors is open.
//
//  SMC reads happen on a private queue; published state is always updated on the main
//  queue so SwiftUI never observes a half-updated snapshot.
//

import Foundation
import SMCKit

final class SensorService: ObservableObject {

    // MARK: - Published state

    @Published private(set) var samples: [SensorSample] = []
    @Published private(set) var lastScan: SensorScanResult?
    @Published private(set) var scanDuration: TimeInterval = 0
    @Published private(set) var isScanning = false

    /// True while a window showing the full sensor list is open.
    ///
    /// Deliberately NOT `@Published`: this is internal polling state, and flipping it from
    /// `onAppear` published a change *during* a view update, which SwiftUI answers with
    /// "Publishing changes from within view updates is not allowed, this will cause
    /// undefined behavior" — and the undefined behaviour includes the render pass being
    /// abandoned, leaving the window showing stale fan speeds.
    private var detailedPolling = false
    /// Keys the curve engine currently tracks; added to the hot poll set.
    @Published private(set) var trackedKeys: Set<String> = []

    // MARK: - Dependencies

    private let smc: SMCAccess
    private let platform: PlatformInfo
    private let log: DiagnosticsLog

    /// Queue that performs all SMC reads.
    private let queue = DispatchQueue(label: "com.autofansmac.sensors", qos: .utility)
    private var timer: DispatchSourceTimer?
    private var pollInterval: TimeInterval = 1.0

    // MARK: - Key plans

    /// Every classified sensor key (T/V/P/I) found by the last full enumeration.
    private var detailedKeys: [String] = []
    /// Known temperature keys — cheap enough to poll every tick.
    private var hotKeys: [String] = []
    private var absentKeys: Set<String> = []
    /// Latest value per key, so a partial poll can be merged into a full picture.
    private var samplesByKey: [String: SensorSample] = [:]
    private var lastFullEnumerations = 0

    init(smc: SMCAccess, platform: PlatformInfo, log: DiagnosticsLog) {
        self.smc = smc
        self.platform = platform
        self.log = log
    }

    // MARK: - Lifecycle

    func start() {
        queue.async { [weak self] in
            self?.performFullScan(reason: "launch")
        }
        restartTimer()
    }

    func stop() {
        timer?.cancel()
        timer = nil
    }

    /// Widens or narrows the per-tick poll set. Safe to call from a view lifecycle hook.
    func setDetailedPolling(_ enabled: Bool) {
        guard detailedPolling != enabled else { return }
        detailedPolling = enabled
        log.info("sensors", enabled
                 ? "detailed polling on (a window showing all sensors is open)"
                 : "detailed polling off (hot subset only)")
        if enabled { rebuildPlans() }
    }

    func setPollingInterval(_ interval: TimeInterval) {
        pollInterval = max(interval, 0.25)
        restartTimer()
    }

    private func restartTimer() {
        timer?.cancel()
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + pollInterval, repeating: pollInterval)
        timer.setEventHandler { [weak self] in
            self?.tick()
        }
        timer.resume()
        self.timer = timer
    }

    /// Adds/removes the keys the curve engine tracks so their values stay fresh.
    func setTrackedKeys(_ keys: Set<String>) {
        queue.async { [weak self] in
            guard let self else { return }
            if self.trackedKeys != keys {
                DispatchQueue.main.async { self.trackedKeys = keys }
            }
        }
    }

    /// One full sweep (used by launch, by the Sensors window's Refresh and after wake).
    func rescanEverything() {
        queue.async { [weak self] in
            self?.performFullScan(reason: "manual refresh")
        }
    }

    /// Every published temperature sample (convenience for the pickers).
    var temperatureSamples: [SensorSample] {
        samples.filter { $0.type == .temperature }
    }

    /// The current value for a key across every published sample.
    func sample(forKey key: String) -> SensorSample? {
        samples.first { $0.key == key }
    }

    /// The current temperature in °C for a key (or computed aggregate).
    func temperature(forKey key: String) -> Double? {
        sample(forKey: key)?.rawValue
    }

    // MARK: - Polling

    /// One tick: refresh the poll set, then recompute the derived aggregates.
    private func tick() {
        let keys = detailedPolling ? detailedKeys : hotKeys + Array(trackedKeysSnapshot)
        guard !keys.isEmpty else { return }
        refresh(keys: keys, full: false)
    }

    private var trackedKeysSnapshot: Set<String> {
        if Thread.isMainThread { return trackedKeys }
        return DispatchQueue.main.sync { trackedKeys }
    }

    private func rebuildPlans() {
        queue.async { [weak self] in
            guard let self else { return }
            if self.detailedPolling, self.detailedKeys.isEmpty, self.smc.isConnected {
                self.performFullScan(reason: "detailed polling requested")
            }
        }
    }

    /// Reads the given keys, merges them into the sample table and republishes.
    private func refresh(keys: [String], full: Bool) {
        let fans = currentFanSnapshot()
        let result = SensorScanner.scan(
            smc,
            platform: platform,
            fans: fans,
            options: scanOptions,
            keys: keys
        )

        for sample in result.samples where !sample.isComputed {
            samplesByKey[sample.key] = sample
        }
        if full {
            // A full sweep is the only thing that can prune sensors that went away.
            let fresh = Set(result.samples.map(\.key))
            for key in samplesByKey.keys where !fresh.contains(key) && !absentKeys.contains(key) {
                samplesByKey.removeValue(forKey: key)
            }
            absentKeys.formUnion(result.absentKeys)
        }

        publish(result: result, full: full)
    }

    private func performFullScan(reason: String) {
        DispatchQueue.main.async { self.isScanning = true }

        let keys = smc.allKeys()
        buildPlans(from: keys)

        let fans = currentFanSnapshot()
        let result = SensorScanner.scan(
            smc,
            platform: platform,
            fans: fans,
            options: scanOptions,
            keys: keys
        )

        samplesByKey = Dictionary(uniqueKeysWithValues: result.samples.filter { !$0.isComputed }.map { ($0.key, $0) })
        absentKeys = Set(result.absentKeys)
        lastFullEnumerations += 1

        log.info("sensors", "full sweep: \(keys.count) keys, \(result.samples.count) samples, "
                 + "\(result.absentKeys.count) absent, \(String(format: "%.0f", result.duration * 1000)) ms (\(reason))")
        publish(result: result, full: true)

        DispatchQueue.main.async { self.isScanning = false }
    }

    /// Classifies the full key list into the detailed and hot plans.
    private func buildPlans(from keys: [String]) {
        var detailed: [String] = []
        var hot: [String] = []

        for key in keys {
            guard let type = SensorScanner.classify(key) else { continue }
            detailed.append(key)
            if type == .temperature {
                hot.append(key)
            }
        }

        detailedKeys = detailed
        hotKeys = hot
        log.info("sensors", "poll plan: \(detailed.count) detailed keys, \(hot.count) hot temperature keys")
    }

    private var scanOptions: SensorScanner.Options {
        var options = SensorScanner.Options()
        options.includeUnknown = AppSettings.showUnknownSensors
        options.includeComputed = true
        return options
    }

    /// The latest fan readings, pushed by the environment on every tick.
    ///
    /// This used to be a callback into `FanService`, which meant the sensor queue (a
    /// background thread) reached into a fan service whose state belongs to the main actor.
    /// A pushed, lock-protected snapshot keeps the two layers on their own threads.
    private let fanSnapshotLock = NSLock()
    private var latestFanSnapshot: FanHardwareSnapshot?

    func updateFanSnapshot(_ snapshot: FanHardwareSnapshot) {
        fanSnapshotLock.lock()
        latestFanSnapshot = snapshot
        fanSnapshotLock.unlock()
    }

    private func currentFanSnapshot() -> FanHardwareSnapshot? {
        fanSnapshotLock.lock()
        defer { fanSnapshotLock.unlock() }
        return latestFanSnapshot
    }

    /// Republish with recomputed aggregates and a stable sort.
    private func publish(result: SensorScanResult, full: Bool) {
        var samples = Array(samplesByKey.values)
        samples.append(contentsOf: SensorScanner.computedSensors(from: samples))

        samples.sort { lhs, rhs in
            if lhs.type.sortOrder != rhs.type.sortOrder { return lhs.type.sortOrder < rhs.type.sortOrder }
            if lhs.group.sortOrder != rhs.group.sortOrder { return lhs.group.sortOrder < rhs.group.sortOrder }
            if lhs.isComputed != rhs.isComputed { return !lhs.isComputed }
            return lhs.name.localizedStandardCompare(rhs.name) == .orderedAscending
        }

        let published = samples
        let scan = full
            ? result
            : SensorScanResult(
                samples: published,
                scannedKeyCount: samples.count,
                absentKeys: Array(absentKeys),
                duration: result.duration
            )

        DispatchQueue.main.async {
            self.samples = published
            // Only a full sweep replaces `lastScan`. Partial polls run every tick, and the
            // controls that derive their options from it (the curve sensor picker) must not
            // rebuild a few hundred menu items once a second.
            if full { self.lastScan = scan }
            self.scanDuration = result.duration
        }
    }
}
