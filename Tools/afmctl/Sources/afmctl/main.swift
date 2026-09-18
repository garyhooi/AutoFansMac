//
//  main.swift
//  afmctl
//
//  Hardware QA tool for AutoFansMac (PROMPT.md §7 Phase 1).
//
//  Read-only subcommands work unprivileged from any terminal. The write subcommands
//  (`set`, `auto`, `unlock`) need root because the SMC enforces the write privilege
//  on fan keys; run them under `sudo` (or let the privileged helper do it).
//
//      afmctl platform                 host identity and unlock-style hint
//      afmctl fans [--json]            fan table with Min/Current/Max + mode
//      afmctl sensors [--type T]       decoded sensor dump
//      afmctl dump-keys [--type T]     every SMC key with its type and value
//      afmctl read <KEY>               read one key
//      afmctl timing                   per-key read cost (finds slow keys)
//      afmctl watch [--interval ms]    live RPM/temperature table
//      afmctl set <fan> <rpm>          set a constant RPM      (root)
//      afmctl auto                     release every fan       (root)
//      afmctl diag                     diagnostics bundle for bug reports
//

import Foundation
import SMCKit

// MARK: - Output helpers

let isTTY = isatty(STDOUT_FILENO) == 1

func bold(_ text: String) -> String { isTTY ? "\u{1B}[1m\(text)\u{1B}[0m" : text }
func dim(_ text: String) -> String { isTTY ? "\u{1B}[2m\(text)\u{1B}[0m" : text }
func red(_ text: String) -> String { isTTY ? "\u{1B}[31m\(text)\u{1B}[0m" : text }
func yellow(_ text: String) -> String { isTTY ? "\u{1B}[33m\(text)\u{1B}[0m" : text }

func fail(_ message: String, code: Int32 = 1) -> Never {
    FileHandle.standardError.write(("afmctl: " + message + "\n").data(using: .utf8)!)
    exit(code)
}

func printUsage() {
    print("""
    \(bold("afmctl")) — AutoFansMac hardware QA tool

    \(bold("READ (no root needed)"))
      platform                 Host identity, chip generation, unlock-style hint
      fans [--json]            All fans: name, min/current/max RPM, hardware mode
      sensors [--type T]       Decoded temperature/voltage/power/current sensors
      dump-keys [--type T]     Every SMC key with its data type and decoded value
      read <KEY>               Read and decode a single SMC key
      timing                   Per-key read cost (flags keys slower than 5 ms)
      watch [--interval ms]    Live table (default 1000 ms; Ctrl-C to stop)
      diag                     Diagnostics bundle (platform, fans, sensors, counters)

    \(bold("WRITE (root required — sudo afmctl …)"))
      set <fan> <rpm>          Constant RPM for one fan
      auto                     Return every fan to macOS control
      unlock <fan>             Run the manual-mode unlock sequence only

    \(bold("OPTIONS"))
      --json                   Machine-readable output where supported
      --type <T|V|P|I|F>       Filter dump-keys/sensors by class
      -h, --help               This help
    """)
}

// MARK: - Argument parsing

struct Arguments {
    let command: String
    let flags: Set<String>
    let options: [String: String]
    let positional: [String]

    init(_ raw: [String]) {
        var flags = Set<String>()
        var options: [String: String] = [:]
        var positional: [String] = []
        var index = 0
        let commandsWithValues: Set<String> = ["--type", "--interval", "--threshold"]
        while index < raw.count {
            let token = raw[index]
            if token.hasPrefix("--") {
                if commandsWithValues.contains(token), index + 1 < raw.count {
                    options[token] = raw[index + 1]
                    index += 2
                    continue
                }
                flags.insert(token)
            } else {
                positional.append(token)
            }
            index += 1
        }
        self.command = positional.first ?? ""
        self.flags = flags
        self.options = options
        self.positional = Array(positional.dropFirst())
    }

    func has(_ flag: String) -> Bool { flags.contains(flag) }
    func value(_ option: String) -> String? { options[option] }
}

// MARK: - Formatting

func formatRPM(_ value: Double) -> String { String(format: "%6.0f", value) }

func formatValue(_ reading: SMCReading, type: SensorType) -> String {
    guard let value = reading.doubleValue else { return reading.stringValue ?? "-" }
    switch type {
    case .temperature: return String(format: "%7.2f °C", value)
    case .voltage: return String(format: "%7.3f V", value)
    case .current: return String(format: "%7.3f A", value)
    case .power: return String(format: "%7.2f W", value)
    case .fan: return String(format: "%7.0f RPM", value)
    case .energy: return String(format: "%7.2f J", value)
    }
}

func typeForFilter(_ raw: String?) -> SensorType? {
    switch raw?.uppercased() {
    case "T": return .temperature
    case "V": return .voltage
    case "P": return .power
    case "I": return .current
    case "F": return .fan
    default: return nil
    }
}

func pad(_ text: String, _ width: Int) -> String {
    text.count >= width ? text : text + String(repeating: " ", count: width - text.count)
}

// MARK: - Subcommands

func commandPlatform(_ smc: SMCConnection) {
    let platform = Platform.current()
    print(bold("Platform"))
    print(platform.diagnosticsDescription)
    print("SMC connected:    \(smc.isConnected)")

    let snapshot = FanHardware.probe(smc, platform: platform)
    print("Fan count (FNum): \(snapshot.fanCount)")
    print("Mode key casing:  \(snapshot.modeKeyIsLowercase ? "lowercase F%dmd" : "uppercase F%dMd")")
    print("Ftst present:     \(snapshot.hasFtst)")
    print("FS! present:      \(snapshot.hasForceMask)")
    print("Unlock style:     \(snapshot.unlockStyle.rawValue)")
    if let count = smc.keyCount() { print("SMC keys (#KEY):  \(count)") }
}

func loadFans(_ smc: SMCConnection) -> FanHardwareSnapshot {
    FanHardware.probe(smc, platform: Platform.current())
}

func commandFans(_ smc: SMCConnection, json: Bool) {
    let snapshot = loadFans(smc)

    if json {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        if let data = try? encoder.encode(snapshot) {
            print(String(data: data, encoding: .utf8) ?? "{}")
        }
        return
    }

    guard snapshot.hasFans else {
        print("No fans detected on this Mac (FNum = 0).")
        print(dim("Sensor monitoring still works — this is the expected state on a fanless Mac."))
        return
    }

    print(bold(pad("FAN", 18) + pad("MIN", 8) + pad("CURRENT", 10) + pad("MAX", 8) + "MODE"))
    for fan in snapshot.fans {
        let mode: String
        switch fan.hardwareMode {
        case .manual: mode = yellow("Custom (manual, mode 1)")
        case .system: mode = "Auto (system mode 3)"
        case .auto: mode = "Auto (mode 0)"
        case .legacyForced: mode = yellow("Legacy forced (mode 2)")
        case .unknown: mode = red("Unknown")
        }
        print(
            pad("\(fan.displayName) [\(fan.index)]", 18)
                + pad(formatRPM(fan.minRPM), 8)
                + pad(formatRPM(fan.currentRPM), 10)
                + pad(formatRPM(fan.maxRPM), 8)
                + mode
        )
        print(dim("    keys: \(fan.actualKey)/\(fan.minKey)/\(fan.maxKey)/\(fan.targetKey) "
                  + "type=\(fan.valueType.trimmingCharacters(in: .whitespaces)) "
                  + "size=\(fan.valueSize) mode=\(fan.modeKey)"))
        for warning in fan.warnings { print(yellow("    ! " + warning)) }
    }
    print(dim("\nUnlock style: \(snapshot.unlockStyle.rawValue) · Ftst: \(snapshot.hasFtst) · FS!: \(snapshot.hasForceMask)"))
}

func commandSensors(_ smc: SMCConnection, filter: String?, json: Bool) {
    let platform = Platform.current()
    let fans = loadFans(smc)
    let result = SensorScanner.scan(smc, platform: platform, fans: fans)
    let wanted = typeForFilter(filter)
    let samples = wanted.map { result.samples(ofType: $0) } ?? result.samples

    if json {
        let payload: [[String: Any]] = samples.map {
            ["key": $0.key, "name": $0.name, "type": $0.type.rawValue, "group": $0.group.rawValue,
             "value": $0.rawValue, "unit": $0.unit, "dataType": $0.dataType, "known": $0.isKnown]
        }
        if let data = try? JSONSerialization.data(withJSONObject: payload, options: [.prettyPrinted, .sortedKeys]) {
            print(String(data: data, encoding: .utf8) ?? "[]")
        }
        return
    }

    print(bold("\(samples.count) sensor values") + dim("  (\(result.scannedKeyCount) keys scanned in \(String(format: "%.0f", result.duration * 1000)) ms, \(result.absentKeys.count) absent)"))
    print(bold(pad("KEY", 10) + pad("NAME", 34) + pad("TYPE", 13) + pad("DATATYPE", 11) + "VALUE"))
    for sample in samples {
        let name = sample.isKnown ? sample.name : "\(sample.name) (unknown)"
        let keyText = sample.isComputed ? "*agg" : sample.key
        print(
            pad(keyText, 10)
                + pad(String(name.prefix(33)), 34)
                + pad(sample.type.displayName, 13)
                + pad(sample.dataType.trimmingCharacters(in: .whitespaces), 11)
                + sample.displayValue(in: .celsius)
        )
    }
}

func commandDumpKeys(_ smc: SMCConnection, filter: String?) {
    let keys = smc.allKeys()
    guard !keys.isEmpty else { fail("no SMC keys could be enumerated") }

    let wanted = typeForFilter(filter)
    var printed = 0
    let platform = Platform.current()

    print(bold(pad("KEY", 7) + pad("DATATYPE", 11) + pad("SIZE", 6) + pad("VALUE", 16) + "NAME"))
    for key in keys.sorted() {
        let sensorType = SensorScanner.classify(key)
        if let wanted, sensorType != wanted { continue }
        guard let info = smc.keyInfo(key), let reading = smc.read(key) else { continue }

        let valueText: String
        if let value = reading.doubleValue {
            switch sensorType {
            case .temperature: valueText = String(format: "%.2f °C", value)
            case .voltage: valueText = String(format: "%.3f V", value)
            case .power: valueText = String(format: "%.2f W", value)
            case .current: valueText = String(format: "%.3f A", value)
            default: valueText = String(format: "%.0f", value)
            }
        } else {
            valueText = reading.stringValue.map { "\"\($0)\"" } ?? "-"
        }

        let name = SensorCatalog.name(for: key, generation: platform.generation) ?? ""
        print(
            pad(key, 7)
                + pad(info.dataType.trimmingCharacters(in: .whitespaces), 11)
                + pad("\(info.dataSize)", 6)
                + pad(valueText, 16)
                + name
        )
        printed += 1
    }
    print(dim("\n\(printed) of \(keys.count) keys shown (total #KEY count: \(smc.keyCount() ?? -1))"))
}

func commandRead(_ smc: SMCConnection, key: String) {
    guard let info = smc.keyInfo(key) else { fail("key \(key) does not exist on this Mac (SMC 0x84)") }
    guard let reading = smc.read(key) else { fail("key \(key) could not be read") }

    print("key:        \(key)")
    print("dataType:   \(info.dataType.trimmingCharacters(in: .whitespaces))")
    print("dataSize:   \(info.dataSize)")
    print("attributes: 0x\(String(info.dataAttributes, radix: 16))"
          + " (readable: \(info.isReadable), writable: \(info.isWritable), private: \(info.isPrivateWrite))")
    print("bytes:      \(reading.bytes.map { String(format: "%02X", $0) }.joined(separator: " "))")
    if let value = reading.doubleValue { print("value:      \(value)") }
    if let string = reading.stringValue { print("string:     \"\(string)\"") }
    if let name = SensorCatalog.name(for: key, generation: Platform.current().generation) {
        print("catalog:    \(name) [\(SensorCatalog.entry(for: key, generation: Platform.current().generation)?.group.rawValue ?? "-")]")
    }
}

func commandTiming(_ smc: SMCConnection) {
    let keys = smc.allKeys()
    guard !keys.isEmpty else { fail("no SMC keys could be enumerated") }

    var timings: [(key: String, milliseconds: Double)] = []
    let overall = Date()
    for key in keys {
        let start = Date()
        _ = smc.read(key)
        timings.append((key, Date().timeIntervalSince(start) * 1000))
    }
    let total = Date().timeIntervalSince(overall)

    timings.sort { $0.milliseconds > $1.milliseconds }
    print(bold("Read cost per key") + dim(" (\(keys.count) keys in \(String(format: "%.0f", total * 1000)) ms total)"))
    print("slowest:")
    for entry in timings.prefix(10) {
        let flag = entry.milliseconds > 5 ? red(" SLOW") : ""
        print(String(format: "  %-6@ %7.2f ms%@", entry.key as NSString, entry.milliseconds, flag))
    }
    let slow = timings.filter { $0.milliseconds > 5 }
    let average = timings.map(\.milliseconds).reduce(0, +) / Double(max(timings.count, 1))
    print(String(format: "  average: %.2f ms · keys slower than 5 ms: %d", average, slow.count))
    print(dim("  Statistics: calls=\(smc.snapshotStatistics().callCount) errors=\(smc.snapshotStatistics().errorCount) reconnects=\(smc.snapshotStatistics().reconnectCount)"))
}

func commandWatch(_ smc: SMCConnection, intervalMilliseconds: Int) {
    let platform = Platform.current()
    let snapshot = FanHardware.probe(smc, platform: platform)
    print(bold("Watching every \(intervalMilliseconds) ms — Ctrl-C to stop"))
    print(dim(snapshot.hasFans
              ? "fans: " + snapshot.fans.map { "\($0.displayName)=\($0.actualKey)" }.joined(separator: ", ")
              : "no fans on this Mac"))
    print("")

    var iterations = 0
    while true {
        let scan = SensorScanner.scan(smc, platform: platform, fans: loadFans(smc))
        let temperatures = scan.temperatureSamples.filter { !$0.isComputed }.prefix(6)
        let fans = scan.fanSamples.filter { !$0.isComputed }

        var line = String(format: "[%3d] ", iterations)
        line += temperatures.map { "\($0.key)=\(String(format: "%.1f", $0.rawValue))" }.joined(separator: " ")
        if !fans.isEmpty {
            line += "  |  "
            line += fans.map { "\($0.name)=\(String(format: "%.0f", $0.rawValue))rpm" }.joined(separator: " ")
        }
        print(line)
        iterations += 1
        Thread.sleep(forTimeInterval: Double(intervalMilliseconds) / 1000.0)
    }
}

func commandDiag(_ smc: SMCConnection) {
    let platform = Platform.current()
    let snapshot = FanHardware.probe(smc, platform: platform)
    let scan = SensorScanner.scan(smc, platform: platform, fans: snapshot)

    print("=== AutoFansMac diagnostics (afmctl) ===")
    print("generated:        \(ISO8601DateFormatter().string(from: Date()))")
    print("")
    print(platform.diagnosticsDescription)
    print("SMC connected:    \(smc.isConnected)")
    print("SMC keys:         \(smc.keyCount() ?? -1)")
    print("root:             \(getuid() == 0)")
    print("")
    print("--- fans ---")
    print("fanCount:         \(snapshot.fanCount)")
    print("modeKeyLowercase: \(snapshot.modeKeyIsLowercase)")
    print("hasFtst:          \(snapshot.hasFtst)")
    print("hasForceMask:     \(snapshot.hasForceMask)")
    print("unlockStyle:      \(snapshot.unlockStyle.rawValue)")
    for fan in snapshot.fans {
        print("fan \(fan.index): \(fan.displayName) min=\(Int(fan.minRPM)) cur=\(Int(fan.currentRPM)) max=\(Int(fan.maxRPM)) mode=\(fan.hardwareMode.rawValue) type=\(fan.valueType)")
        for warning in fan.warnings { print("  ! \(warning)") }
    }
    print("")
    print("--- sensors ---")
    print("scanned keys:     \(scan.scannedKeyCount)")
    print("samples:          \(scan.samples.count) (temperatures: \(scan.temperatureSamples.count))")
    print("absent keys:      \(scan.absentKeys.count)")
    print("unknown keys:     \(scan.unknownKeys.count) \(scan.unknownKeys.prefix(20).joined(separator: " "))")
    print("scan duration:    \(String(format: "%.1f", scan.duration * 1000)) ms")
    print("")
    print("--- smc counters ---")
    let statistics = smc.snapshotStatistics()
    print("calls:            \(statistics.callCount)")
    print("errors:           \(statistics.errorCount)")
    print("reconnects:       \(statistics.reconnectCount)")
    print("lastError:        \(statistics.lastError ?? "none")")
}

func commandSet(_ smc: SMCConnection, fanIndex: Int, rpm: Double) {
    let platform = Platform.current()
    let snapshot = FanHardware.probe(smc, platform: platform)
    guard let fan = snapshot.fans.first(where: { $0.index == fanIndex }) else {
        fail("fan \(fanIndex) does not exist (FNum = \(snapshot.fanCount))")
    }
    if getuid() != 0 {
        print(yellow("warning: not running as root — SMC fan writes will be refused (kIOReturnNotPrivileged)."))
        print(dim("         run: sudo afmctl set \(fanIndex) \(Int(rpm))"))
    }

    let sequencer = UnlockSequencer(access: smc, snapshot: snapshot)
    sequencer.onEvent = { print(dim("  · " + $0.message)) }

    switch sequencer.setTarget(fan: fan, rpm: rpm) {
    case .success(let outcome):
        print("fan \(fanIndex) → \(Int(outcome.targetRPM)) RPM (applied: \(outcome.applied), verified: \(outcome.verified), actual: \(Int(outcome.actualRPM)))")
        if outcome.unresponsive {
            print(yellow("warning: the fan did not respond to the commanded RPM."))
        }
    case .failure(let failure):
        fail(failure.localizedDescription)
    }
}

func commandAuto(_ smc: SMCConnection) {
    let snapshot = loadFans(smc)
    guard snapshot.hasFans else { print("no fans on this Mac — nothing to release"); return }
    if getuid() != 0 { print(yellow("warning: not running as root — writes will be refused.")) }

    let sequencer = UnlockSequencer(access: smc, snapshot: snapshot)
    sequencer.onEvent = { print(dim("  · " + $0.message)) }
    let results = sequencer.releaseAll()

    var failed = 0
    for (index, result) in results.sorted(by: { $0.key < $1.key }) {
        switch result {
        case .success: print("fan \(index) → auto")
        case .failure(let failure):
            failed += 1
            print(red("fan \(index) → FAILED: \(failure.localizedDescription)"))
        }
    }
    if failed > 0 { exit(1) }
}

func commandUnlock(_ smc: SMCConnection, fanIndex: Int) {
    let platform = Platform.current()
    let snapshot = FanHardware.probe(smc, platform: platform)
    guard let fan = snapshot.fans.first(where: { $0.index == fanIndex }) else {
        fail("fan \(fanIndex) does not exist (FNum = \(snapshot.fanCount))")
    }
    if getuid() != 0 { print(yellow("warning: not running as root — the unlock will fail with a privilege error.")) }

    let sequencer = UnlockSequencer(access: smc, snapshot: snapshot)
    sequencer.onEvent = { print(dim("  · " + $0.message)) }

    switch sequencer.ensureManualMode(fan) {
    case .success:
        print("fan \(fanIndex) is in manual mode (Ftst held: \(sequencer.isFtstHeld))")
        print(dim("releasing again so nothing is left pinned…"))
        _ = sequencer.releaseAll()
        print("released.")
    case .failure(let failure):
        fail(failure.localizedDescription)
    }
}

// MARK: - Entry point

let arguments = Arguments(Array(CommandLine.arguments.dropFirst()))

if arguments.command.isEmpty || arguments.has("-h") || arguments.has("--help") || arguments.command == "help" {
    printUsage()
    exit(arguments.command.isEmpty ? 2 : 0)
}

let smc = SMCConnection()
guard smc.connect() else {
    fail("could not open the AppleSMC user client (\(smc.snapshotStatistics().lastError ?? "unknown error"))")
}

switch arguments.command {
case "platform":
    commandPlatform(smc)
case "fans":
    commandFans(smc, json: arguments.has("--json"))
case "sensors":
    commandSensors(smc, filter: arguments.value("--type"), json: arguments.has("--json"))
case "dump-keys":
    commandDumpKeys(smc, filter: arguments.value("--type"))
case "read":
    guard let key = arguments.positional.first, key.count == 4 else { fail("usage: afmctl read <4-char KEY>") }
    commandRead(smc, key: key)
case "timing":
    commandTiming(smc)
case "watch":
    let interval = Int(arguments.value("--interval") ?? "1000") ?? 1000
    commandWatch(smc, intervalMilliseconds: max(interval, 100))
case "diag":
    commandDiag(smc)
case "set":
    guard arguments.positional.count >= 2,
          let fanIndex = Int(arguments.positional[0]),
          let rpm = Double(arguments.positional[1]) else {
        fail("usage: sudo afmctl set <fan index> <rpm>")
    }
    commandSet(smc, fanIndex: fanIndex, rpm: rpm)
case "auto":
    commandAuto(smc)
case "unlock":
    guard let raw = arguments.positional.first, let fanIndex = Int(raw) else {
        fail("usage: sudo afmctl unlock <fan index>")
    }
    commandUnlock(smc, fanIndex: fanIndex)
default:
    fail("unknown command \"\(arguments.command)\" — run afmctl --help", code: 2)
}
