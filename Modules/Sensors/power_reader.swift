//
//  power_reader.swift
//  Sensors
//
//  Reader for the Power module (fork addition, INFRA-45): package/CPU/GPU/ANE power,
//  per-cluster frequency, temperature and utilization from IOReport/SMC/HID only.
//  powermetrics must never be spawned here (it piles up behind a 64 KB pipe on the M3 Ultra).
//

import Cocoa
import Kit
import IOKit.graphics

public enum PowerClusterType: String, Codable {
    case efficiency = "E"
    case performance = "P"
}

public struct PowerCluster: Codable {
    public let name: String
    public let type: PowerClusterType
    // nil when the cluster reported no residency this tick; 0 is a real measured zero (parked)
    public let frequency: Double?
}

public struct PowerSnapshot: Codable {
    public var packagePower: Double? = nil
    public var cpuPower: Double? = nil
    public var gpuPower: Double? = nil
    public var anePower: Double? = nil

    public var clusters: [PowerCluster] = []

    public var cpuTempAvg: Double? = nil
    public var cpuTempMax: Double? = nil
    public var gpuTemp: Double? = nil

    public var cpuUtilization: Double? = nil
    public var gpuUtilization: Double? = nil
}

public class PowerReader: Reader<PowerSnapshot> {
    private var channels: CFMutableDictionary? = nil
    private var subscription: IOReportSubscriptionRef? = nil
    private var prev: (samples: CFDictionary, time: TimeInterval)? = nil

    private var eCoreFreqs: [Int32] = []
    private var pCoreFreqs: [Int32] = []
    private var sCoreFreqs: [Int32] = []

    private var tick = 0
    private var deadEnergyTicks = 0
    private let macmon = MacmonPipe()
    private var prevCPUTicks: (user: Double, system: Double, idle: Double, nice: Double) = (0, 0, 0, 0)

    deinit {
        self.macmon.stop()
    }

    public override func setup() {
        self.setInterval(1)

        self.eCoreFreqs = SystemKit.shared.device.info.cpu?.eCoreFrequencies ?? []
        self.pCoreFreqs = SystemKit.shared.device.info.cpu?.pCoreFrequencies ?? []
        self.sCoreFreqs = SystemKit.shared.device.info.cpu?.sCoreFrequencies ?? []

        self.channels = self.getChannels()
        var dict: Unmanaged<CFMutableDictionary>?
        self.subscription = IOReportCreateSubscription(nil, self.channels, &dict, 0, nil)
        dict?.release()
    }

    public override func read() {
        self.tick += 1
        var snapshot = PowerSnapshot()
        
        if self.tick <= 2 {
            // warm-up: subscriptions and counters settle during the first ticks
            self.callback(PowerSnapshot())
            return
        }
        if let macmon = self.macmon.latest() {
            snapshot.cpuPower = macmon.cpu
            snapshot.gpuPower = macmon.gpu
            snapshot.anePower = macmon.ane
            snapshot.packagePower = macmon.cpu + macmon.gpu + macmon.ane
        }

        if let delta = self.sampleDelta() {
            self.parsePower(delta.samples, elapsed: delta.elapsed, into: &snapshot)
            self.parseFrequencies(delta.samples, into: &snapshot)
        }
        self.readTemperatures(into: &snapshot)
        snapshot.cpuUtilization = self.readCPUUtilization()
        snapshot.gpuUtilization = self.readGPUUtilization()

        // macOS 27 (Tahoe) zeroes the Energy Model CPU counters on some machines (verified on the
        // M3 Ultra: every CPU/ANE energy channel stays 0 while GPU Energy ticks). When the native
        // path is provably dead but the machine is busy, switch the power rails to a single
        // long-lived `macmon pipe` child. One process, one JSON line per second - it structurally
        // cannot pile up the way Mx Power Gadget's per-second powermetrics spawns did.
        // an exact 0 W CPU while the clusters are reporting frequencies is physically impossible -
        // it means the native counters are dead (macOS 27), regardless of how idle the machine is
        if !self.macmon.active && self.tick > 5 && snapshot.cpuPower == 0 && !snapshot.clusters.isEmpty {
            self.deadEnergyTicks += 1
            if self.deadEnergyTicks >= 5 {
                self.macmon.start()
            }
        }

        self.callback(snapshot)
    }

    // MARK: - IOReport

    private func getChannels() -> CFMutableDictionary? {
        let channelNames: [(String, String?)] = [
            ("Energy Model", nil),
            ("CPU Stats", "CPU Complex Performance States")
        ]

        var channels: [CFDictionary] = []
        for (gname, sname) in channelNames {
            let channel = IOReportCopyChannelsInGroup(gname as CFString?, sname as CFString?, 0, 0, 0)
            guard let channel = channel?.takeRetainedValue() else { continue }
            channels.append(channel)
        }

        guard let chan = channels.first else { return nil }
        for i in 1..<channels.count {
            IOReportMergeChannels(chan, channels[i], nil)
        }

        let size = CFDictionaryGetCount(chan)
        guard let channel = CFDictionaryCreateMutableCopy(kCFAllocatorDefault, size, chan),
              let chan = channel as? [String: Any], chan["IOReportChannels"] != nil else {
            return nil
        }

        return channel
    }

    private func sampleDelta() -> (samples: [CFDictionary], elapsed: TimeInterval)? {
        guard self.subscription != nil, self.channels != nil,
              let sample = IOReportCreateSamples(self.subscription, self.channels, nil)?.takeRetainedValue() else {
            return nil
        }
        let now = Date().timeIntervalSince1970
        defer { self.prev = (sample, now) }

        guard let prev = self.prev, now - prev.time >= 0.5,
              let diffCF = IOReportCreateSamplesDelta(prev.samples, sample, nil) else {
            return nil
        }
        let diff = diffCF.takeRetainedValue()

        guard let dict = diff as? [String: Any], let list = dict["IOReportChannels"] as? NSArray else { return nil }
        let items = list as CFArray
        var samples: [CFDictionary] = []
        for i in 0..<CFArrayGetCount(items) {
            samples.append(unsafeBitCast(CFArrayGetValueAtIndex(items, i), to: CFDictionary.self))
        }

        return (samples, now - prev.time)
    }

    private func parsePower(_ samples: [CFDictionary], elapsed: TimeInterval, into snapshot: inout PowerSnapshot) {
        var cpu: Double? = nil
        var gpu: Double? = nil
        var ane: Double? = nil

        for item in samples {
            guard let group = IOReportChannelGetGroup(item)?.takeUnretainedValue() as? String,
                  group == "Energy Model",
                  let channel = IOReportChannelGetChannelName(item)?.takeUnretainedValue() as? String,
                  let unit = IOReportChannelGetUnitLabel(item)?.takeUnretainedValue() as? String else { continue }

            // the delta sample holds the energy spent during `elapsed`, so energy/elapsed = W
            let raw = IOReportSimpleGetIntegerValue(item, 0)
            let watts = Double(raw).power(unit) / elapsed

            if channel.hasSuffix("CPU Energy") {
                cpu = (cpu ?? 0) + watts
            } else if channel.hasSuffix("GPU Energy") {
                gpu = (gpu ?? 0) + watts
            } else if channel.starts(with: "ANE") {
                ane = (ane ?? 0) + watts
            }
        }

        // never overwrite macmon-sourced rails with the dead native zeros
        guard snapshot.cpuPower == nil else { return }
        snapshot.cpuPower = cpu
        snapshot.gpuPower = gpu
        snapshot.anePower = ane
        // package defined as CPU+GPU+ANE: the same sum powermetrics reports as "Combined Power"
        if cpu != nil || gpu != nil || ane != nil {
            snapshot.packagePower = (cpu ?? 0) + (gpu ?? 0) + (ane ?? 0)
        }
    }

    private func parseFrequencies(_ samples: [CFDictionary], into snapshot: inout PowerSnapshot) {
        var clusters: [PowerCluster] = []

        for item in samples {
            guard let group = IOReportChannelGetGroup(item)?.takeUnretainedValue() as? String,
                  let channel = IOReportChannelGetChannelName(item)?.takeUnretainedValue() as? String else { continue }

            if group == "CPU Stats" {
                // channel families: "ECPU"/"PCPU"/"MCPU" (M1-M4), "DIE_0_ECPU"/"DIE_0_PCPU1" (Ultra);
                // skip complex-level "ECPM"/"PCPM" and "_IDLE" variants
                guard !channel.hasSuffix("_IDLE"), !channel.contains("CPM") else { continue }
                let table: [Int32]
                let type: PowerClusterType
                if channel.contains("ECPU") {
                    table = self.eCoreFreqs
                    type = .efficiency
                } else if channel.contains("MCPU") {
                    table = self.pCoreFreqs
                    type = .performance
                } else if channel.contains("PCPU") {
                    table = self.sCoreFreqs.isEmpty ? self.pCoreFreqs : self.sCoreFreqs
                    type = .performance
                } else {
                    continue
                }
                clusters.append(PowerCluster(name: channel, type: type, frequency: self.stateFrequency(dict: item, freqs: table)))
            }
        }

        // stable order: E clusters first, then P, each by channel name; rename to E0/E1/P0...
        let eClusters = clusters.filter { $0.type == .efficiency }.sorted { $0.name < $1.name }
        let pClusters = clusters.filter { $0.type == .performance }.sorted { $0.name < $1.name }
        snapshot.clusters =
            eClusters.enumerated().map { PowerCluster(name: "E\($0.offset)", type: .efficiency, frequency: $0.element.frequency) } +
            pClusters.enumerated().map { PowerCluster(name: "P\($0.offset)", type: .performance, frequency: $0.element.frequency) }
    }

    // residency-weighted average frequency; 0 is reported as 0 (a parked cluster must stay visible),
    // unlike the CPU module's FrequencyReader which clamps to the table minimum
    private func stateFrequency(dict: CFDictionary, freqs: [Int32]) -> Double? {
        guard !freqs.isEmpty else { return nil }

        let count = IOReportStateGetCount(dict)
        var states: [(name: String, residency: Int64)] = []
        for i in 0..<count {
            let name = IOReportStateGetNameForIndex(dict, i)?.takeUnretainedValue() ?? ("" as CFString)
            states.append((name as String, IOReportStateGetResidency(dict, i)))
        }

        guard let offset = states.firstIndex(where: { $0.name != "IDLE" && $0.name != "DOWN" && $0.name != "OFF" }),
              states.count - offset == freqs.count else { return nil }

        let active = states.dropFirst(offset).reduce(0.0) { $0 + Double($1.residency) }
        guard active > 0 else { return 0 }

        var avg: Double = 0
        for i in 0..<freqs.count {
            let idx = i + offset
            guard states.indices.contains(idx) else { continue }
            avg += (Double(states[idx].residency) / active) * Double(freqs[i])
        }
        return avg
    }

    // MARK: - temperature (HID, same source the Sensors module uses)

    // SMC key candidates per Apple Silicon generation (from values.swift) - keys are chip-specific,
    // and a key that exists on another chip can mean a different sensor, so never probe across generations
    private static var chipGeneration: String {
        let name = (SystemKit.shared.device.info.cpu?.name ?? "").lowercased()
        for generation in ["m1", "m2", "m3", "m4"] where name.contains(generation) { return generation }
        return ""
    }
    private static let gpuSMCKeysByGen: [String: [String]] = [
        "m1": ["Tg05", "Tg0D", "Tg0L", "Tg0T"],
        "m2": ["Tg0f", "Tg0j"],
        "m3": ["Tf14", "Tf18", "Tf19", "Tf1A", "Tf24", "Tf28", "Tf29", "Tf2A"],
        "m4": ["Tg0G", "Tg0H"]
    ]
    private static let cpuSMCKeysByGen: [String: [String]] = [
        "m1": ["Tp01", "Tp05", "Tp09", "Tp0D", "Tp0X", "Tp0b", "Tp0f", "Tp0j"],
        "m2": ["Tp01", "Tp05", "Tp09", "Tp0D", "Tp0X", "Tp0b", "Tp0f", "Tp0j"],
        "m3": ["Te05", "Te0L", "Te0P", "Te0S", "Tf04", "Tf09", "Tf0A", "Tf0B", "Tf0D", "Tf0E", "Tf44", "Tf49", "Tf4A", "Tf4B", "Tf4D", "Tf4E"],
        "m4": ["Te05", "Te09", "Te0H", "Te0S", "Tp01", "Tp05", "Tp09", "Tp0D", "Tp0V", "Tp0Y", "Tp0b", "Tp0e"]
    ]
    private static let gpuSMCKeys = gpuSMCKeysByGen[chipGeneration] ?? []
    private static let cpuSMCKeys = cpuSMCKeysByGen[chipGeneration] ?? []

    private func readTemperatures(into snapshot: inout PowerSnapshot) {
        var cpuValues: [Double] = []
        var gpuValues: [Double] = []

        // CPU die temps via HID; key families differ per chip/OS (xACC MTR vs PMU tdie)
        if let sensors = AppleSiliconSensors(0xff00, 5, kIOHIDEventTypeTemperature) {
            sensors.forEach { key, value in
                guard let key = key as? String, let value = value as? Double, value > 10, value < 120 else { return }
                if key.hasPrefix("pACC MTR Temp") || key.hasPrefix("eACC MTR Temp") || key.hasPrefix("PMU tdie") {
                    cpuValues.append(value)
                } else if key.hasPrefix("GPU MTR Temp") {
                    gpuValues.append(value)
                }
            }
        }
        // per-core SMC sensors run hotter and match powermetrics/macmon; prefer them over the HID die sensors
        let smcCPU = Self.cpuSMCKeys.compactMap { SMC.shared.getValue($0) }.filter { $0 > 10 && $0 < 120 }
        if !smcCPU.isEmpty {
            cpuValues = smcCPU
        }
        if gpuValues.isEmpty {
            gpuValues = Self.gpuSMCKeys.compactMap { SMC.shared.getValue($0) }.filter { $0 > 10 && $0 < 120 }
        }

        if !cpuValues.isEmpty {
            snapshot.cpuTempAvg = cpuValues.reduce(0, +) / Double(cpuValues.count)
            snapshot.cpuTempMax = cpuValues.max()
        }
        if !gpuValues.isEmpty {
            snapshot.gpuTemp = gpuValues.reduce(0, +) / Double(gpuValues.count)
        }
    }

    // MARK: - utilization

    private func readCPUUtilization() -> Double? {
        var count = mach_msg_type_number_t(MemoryLayout<host_cpu_load_info_data_t>.size / MemoryLayout<integer_t>.size)
        var info = host_cpu_load_info_data_t()
        let result = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                host_statistics(mach_host_self(), HOST_CPU_LOAD_INFO, $0, &count)
            }
        }
        guard result == KERN_SUCCESS else { return nil }

        let user = Double(info.cpu_ticks.0)
        let system = Double(info.cpu_ticks.1)
        let idle = Double(info.cpu_ticks.2)
        let nice = Double(info.cpu_ticks.3)

        let prev = self.prevCPUTicks
        self.prevCPUTicks = (user, system, idle, nice)
        guard prev.user != 0 || prev.system != 0 || prev.idle != 0 else { return nil }

        let busy = (user - prev.user) + (system - prev.system) + (nice - prev.nice)
        let total = busy + (idle - prev.idle)
        guard total > 0 else { return nil }
        return min(max(busy / total, 0), 1)
    }

    private func readGPUUtilization() -> Double? {
        guard let matching = IOServiceMatching(kIOAcceleratorClassName) else { return nil }
        var iterator: io_iterator_t = 0
        guard IOServiceGetMatchingServices(kIOMainPortDefault, matching, &iterator) == kIOReturnSuccess else { return nil }
        defer { IOObjectRelease(iterator) }

        var utilization: Double? = nil
        while case let entry = IOIteratorNext(iterator), entry != 0 {
            defer { IOObjectRelease(entry) }
            var propertiesRef: Unmanaged<CFMutableDictionary>? = nil
            guard IORegistryEntryCreateCFProperties(entry, &propertiesRef, kCFAllocatorDefault, 0) == kIOReturnSuccess,
                  let properties = propertiesRef?.takeRetainedValue() as? [String: Any],
                  let stats = properties["PerformanceStatistics"] as? [String: Any] else { continue }
            if let value = stats["Device Utilization %"] as? Int ?? stats["GPU Activity(%)"] as? Int {
                utilization = max(utilization ?? 0, min(max(Double(value) / 100, 0), 1))
            }
        }
        return utilization
    }
}

// A single supervised `macmon pipe -i 1000` child used only when the native IOReport power path is
// dead (macOS 27 M3 Ultra). Restarts are rate-limited; stdout is consumed line-by-line as it arrives.
internal class MacmonPipe {
    private let queue = DispatchQueue(label: "eu.exelban.Stats.Power.macmon")
    private var process: Process? = nil
    private var lastStart: Date = .distantPast
    private var value: (cpu: Double, gpu: Double, ane: Double, at: Date)? = nil
    private var lastGood: (cpu: Double, gpu: Double, ane: Double, at: Date)? = nil
    private var started: Bool = false
    var active: Bool { self.queue.sync { self.started } }

    func latest() -> (cpu: Double, gpu: Double, ane: Double)? {
        self.queue.sync {
            guard self.started else { return nil }
            if self.process?.isRunning != true {
                self.startLocked()
            }
            guard let value = self.value, Date().timeIntervalSince(value.at) < 5 else { return nil }
            return (value.cpu, value.gpu, value.ane)
        }
    }

    func start() {
        self.queue.sync {
            self.started = true
            self.startLocked()
        }
    }

    func stop() {
        self.queue.sync {
            self.started = false
            self.process?.terminate()
            self.process = nil
        }
    }

    private func startLocked() {
        guard Date().timeIntervalSince(self.lastStart) > 30 else { return }
        self.lastStart = Date()

        let candidates = ["/opt/homebrew/bin/macmon", "/usr/local/bin/macmon"]
        guard let binary = candidates.first(where: { FileManager.default.isExecutableFile(atPath: $0) }) else { return }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: binary)
        process.arguments = ["pipe", "-i", "1000"]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice

        pipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard !data.isEmpty, let self else { return }
            for line in data.split(separator: UInt8(ascii: "\n")) {
                guard let json = try? JSONSerialization.jsonObject(with: Data(line)) as? [String: Any] else { continue }
                let cpu = json["cpu_power"] as? Double ?? 0
                let gpu = json["gpu_power"] as? Double ?? 0
                let ane = json["ane_power"] as? Double ?? 0
                self.queue.async {
                    let now = Date()
                    // macmon <0.9 on macOS 27 emits cpu_power=0 on most samples (measured on the
                    // M3 Ultra: one real reading in four). An exact 0 right after a busy reading
                    // is that artifact, not real idle - hold the last good value instead.
                    if cpu == 0, let lastGood = self.lastGood, lastGood.cpu > 1, now.timeIntervalSince(lastGood.at) < 15 {
                        self.value = (lastGood.cpu, lastGood.gpu, lastGood.ane, now)
                        return
                    }
                    self.value = (cpu, gpu, ane, now)
                    if cpu > 0 {
                        self.lastGood = (cpu, gpu, ane, now)
                    }
                }
            }
        }
        process.terminationHandler = { _ in
            pipe.fileHandleForReading.readabilityHandler = nil
        }

        do {
            try process.run()
            self.process = process
        } catch {
            self.process = nil
        }
    }
}
