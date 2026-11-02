//
//  power_popup.swift
//  Sensors
//
//  Popup for the Power module (fork addition, INFRA-45): an Intel-Power-Gadget-style stack of
//  four time-series panels (power, frequency, temperature, utilization), per the Claude Design
//  spec of 2026-11-02 (research-ui/claude-design-stats-power-2026-11-02.txt).
//

import Cocoa
import Kit

private let popupWidth: CGFloat = 360
private let historyLength: Int = 120

// one color per subsystem, consistent across every panel (dynamic for Increase Contrast)
private enum PowerColors {
    static var cpu: NSColor { .systemBlue }
    static var gpu: NSColor { .systemGreen }
    static var ane: NSColor { .systemPurple }
    static var pkg: NSColor { .systemGray }
    static var eCluster: NSColor { .systemTeal }
    static var tempAvg: NSColor { .systemOrange }
    static var tempMax: NSColor { .systemRed }
}

internal struct PowerSeries {
    let key: String
    var label: String
    var color: NSColor
    var filled: Bool = false
    var dashedWhenZero: Bool = false
    var values: [Double?] = []
    var current: Double? = nil
    var faulted: Bool = false

    mutating func push(_ value: Double?) {
        self.current = value
        self.values.append(value)
        if self.values.count > historyLength {
            self.values.removeFirst(self.values.count - historyLength)
        }
    }
}

internal class PowerPopup: PopupWrapper {
    private var header: PowerHeaderView? = nil
    private var powerPanel: PowerPanelView
    private var frequencyPanel: PowerPanelView
    private var temperaturePanel: PowerPanelView
    private var utilizationPanel: PowerPanelView

    // parked-P fault detection: red only when a P cluster is at 0 MHz while CPU use >50% for >=3 s
    private var faultCounters: [String: Int] = [:]

    public init() {
        self.powerPanel = PowerPanelView(title: "POWER", unit: "W", scale: .auto(floor: 5, steps: [5, 10, 20, 50, 100, 200, 300]))
        self.frequencyPanel = PowerPanelView(title: "FREQUENCY", unit: "GHz", scale: .fixed(0))
        self.temperaturePanel = PowerPanelView(title: "TEMPERATURE", unit: "°C", scale: .fixedRange(20, 110))
        self.utilizationPanel = PowerPanelView(title: "UTILIZATION", unit: "%", scale: .fixedRange(0, 100))

        super.init(.power, frame: NSRect(x: 0, y: 0, width: popupWidth, height: 560))

        self.orientation = .vertical
        self.alignment = .leading
        self.spacing = 8
        self.edgeInsets = NSEdgeInsets(top: 0, left: 0, bottom: 0, right: 0)

        let header = PowerHeaderView(width: popupWidth)
        self.header = header
        self.addArrangedSubview(header)
        self.addArrangedSubview(self.powerPanel)
        self.addArrangedSubview(self.frequencyPanel)
        self.addArrangedSubview(self.temperaturePanel)
        self.addArrangedSubview(self.utilizationPanel)

        let maxFreq = Double(SystemKit.shared.device.info.cpu?.pCoreFrequencies?.max() ?? 4050) / 1000
        self.frequencyPanel.scale = .fixedRange(0, max(maxFreq, 1))

        self.recalculateHeight()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    private func recalculateHeight() {
        let panels = [self.powerPanel, self.frequencyPanel, self.temperaturePanel, self.utilizationPanel]
        let height = 40 + panels.reduce(0) { $0 + $1.panelHeight } + CGFloat(panels.count) * self.spacing
        if self.frame.height != height {
            self.setFrameSize(NSSize(width: popupWidth, height: height))
            self.sizeCallback?(self.frame.size)
        }
    }

    internal func callback(_ snapshot: PowerSnapshot) {
        DispatchQueue.main.async { [weak self] in
            guard let self, self.window?.isVisible ?? false else {
                self?.store(snapshot)
                return
            }
            self.store(snapshot)
            self.powerPanel.refresh()
            self.frequencyPanel.refresh()
            self.temperaturePanel.refresh()
            self.utilizationPanel.refresh()
            self.recalculateHeight()
        }
    }

    private func store(_ snapshot: PowerSnapshot) {
        let visible = self.window?.isVisible ?? false
        for panel in [self.powerPanel, self.frequencyPanel, self.temperaturePanel, self.utilizationPanel] {
            panel.uiActive = visible
        }
        self.powerPanel.update([
            ("PKG", snapshot.packagePower, PowerColors.pkg, true, false),
            ("CPU", snapshot.cpuPower, PowerColors.cpu, false, false),
            ("GPU", snapshot.gpuPower, PowerColors.gpu, false, false),
            ("ANE", snapshot.anePower, PowerColors.ane, false, false)
        ], format: { String(format: "%.1f", $0) })

        // an empty cluster list means the IOReport tick failed - keep the panel's history and chips
        if !snapshot.clusters.isEmpty {
            let freqSeries: [(String, Double?, NSColor, Bool, Bool)] = snapshot.clusters.map { cluster in
                let color = cluster.type == .efficiency ? PowerColors.eCluster : PowerColors.cpu
                return (cluster.name, cluster.frequency.map { $0 / 1000 }, color, false, true)
            }
            self.frequencyPanel.update(freqSeries, format: { String(format: "%.2f", $0) })
        }

        // fault marking: P cluster parked at 0 while the CPU is clearly busy
        let busy = (snapshot.cpuUtilization ?? 0) > 0.5
        for cluster in snapshot.clusters where cluster.type == .performance {
            if cluster.frequency == 0 && busy {
                self.faultCounters[cluster.name, default: 0] += 1
            } else {
                self.faultCounters[cluster.name] = 0
            }
            self.frequencyPanel.setFault(cluster.name, (self.faultCounters[cluster.name] ?? 0) >= 3)
        }

        self.temperaturePanel.update([
            ("CPU avg", snapshot.cpuTempAvg, PowerColors.tempAvg, false, false),
            ("CPU max", snapshot.cpuTempMax, PowerColors.tempMax, false, false),
            ("GPU", snapshot.gpuTemp, PowerColors.gpu, false, false)
        ], format: { String(format: "%.0f", $0) })

        self.utilizationPanel.update([
            ("CPU", snapshot.cpuUtilization.map { $0 * 100 }, PowerColors.cpu, false, false),
            ("GPU", snapshot.gpuUtilization.map { $0 * 100 }, PowerColors.gpu, false, false)
        ], format: { String(format: "%.0f", $0) })

        self.header?.update()
    }
}

// MARK: - header

private class PowerHeaderView: NSStackView {
    private let titleField = NSTextField(labelWithString: "")
    private let subtitleField = NSTextField(labelWithString: "")
    private var filled = false

    init(width: CGFloat) {
        super.init(frame: NSRect(x: 0, y: 0, width: width, height: 40))
        self.orientation = .vertical
        self.alignment = .leading
        self.spacing = 2
        self.edgeInsets = NSEdgeInsets(top: 4, left: 2, bottom: 0, right: 2)

        self.titleField.font = NSFont.systemFont(ofSize: 13, weight: .semibold)
        self.subtitleField.font = NSFont.systemFont(ofSize: 11, weight: .regular)
        self.subtitleField.textColor = .secondaryLabelColor
        self.addArrangedSubview(self.titleField)
        self.addArrangedSubview(self.subtitleField)
        self.heightAnchor.constraint(equalToConstant: 40).isActive = true
        self.widthAnchor.constraint(equalToConstant: width).isActive = true
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func update() {
        guard !self.filled else { return }
        let info = SystemKit.shared.device.info.cpu
        self.titleField.stringValue = info?.name ?? SystemKit.shared.device.model.name
        var parts: [String] = []
        if let e = info?.eCores, let p = info?.pCores {
            parts.append("\(e) E + \(p) P cores")
        }
        if let gpu = SystemKit.shared.device.info.gpu?.first?.cores {
            parts.append("\(gpu) GPU cores")
        }
        self.subtitleField.stringValue = parts.joined(separator: " · ")
        self.filled = !self.titleField.stringValue.isEmpty
    }
}

// MARK: - panel (title row + chips + chart)

internal enum PowerPanelScale {
    case auto(floor: Double, steps: [Double])
    case fixed(Double)
    case fixedRange(Double, Double)
}

internal class PowerPanelView: NSStackView {
    internal var uiActive: Bool = false
    internal var scale: PowerPanelScale
    private let unit: String
    private let titleField = NSTextField(labelWithString: "")
    private let axisField = NSTextField(labelWithString: "")
    internal private(set) var panelHeight: CGFloat = 110
    private var heightConstraint: NSLayoutConstraint? = nil
    private var chipsRows: [NSStackView] = []
    private var chips: [String: PowerChipView] = [:]
    private let chart: PowerChartView
    private var series: [PowerSeries] = []
    private var format: (Double) -> String

    init(title: String, unit: String, scale: PowerPanelScale) {
        self.unit = unit
        self.scale = scale
        self.chart = PowerChartView(frame: NSRect(x: 0, y: 0, width: popupWidth - 4, height: 72))
        self.format = { String(format: "%.1f", $0) }

        super.init(frame: NSRect(x: 0, y: 0, width: popupWidth, height: 110))
        self.orientation = .vertical
        self.alignment = .leading
        self.spacing = 4
        self.widthAnchor.constraint(equalToConstant: popupWidth).isActive = true

        let titleRow = NSStackView(frame: NSRect(x: 0, y: 0, width: popupWidth, height: 16))
        titleRow.orientation = .horizontal
        titleRow.distribution = .fill
        self.titleField.stringValue = "\(title)  \(unit)"
        self.titleField.font = NSFont.systemFont(ofSize: 10, weight: .semibold)
        self.titleField.textColor = .secondaryLabelColor
        self.axisField.font = NSFont.monospacedDigitSystemFont(ofSize: 9, weight: .regular)
        self.axisField.textColor = .tertiaryLabelColor
        titleRow.addArrangedSubview(self.titleField)
        titleRow.addArrangedSubview(NSView())
        titleRow.addArrangedSubview(self.axisField)
        titleRow.heightAnchor.constraint(equalToConstant: 16).isActive = true
        self.addArrangedSubview(titleRow)
        titleRow.widthAnchor.constraint(equalTo: self.widthAnchor).isActive = true

        self.chart.heightAnchor.constraint(equalToConstant: 72).isActive = true
        self.chart.widthAnchor.constraint(equalToConstant: popupWidth - 4).isActive = true
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func update(_ newValues: [(label: String, value: Double?, color: NSColor, filled: Bool, dashedWhenZero: Bool)], format: @escaping (Double) -> String) {
        // create series + chips lazily on the first tick that defines them
        if self.series.count != newValues.count {
            self.series = newValues.map { PowerSeries(key: $0.label, label: $0.label, color: $0.color, filled: $0.filled, dashedWhenZero: $0.dashedWhenZero) }
            self.rebuildChips(format: format)
        }
        self.format = format
        for (i, value) in newValues.enumerated() {
            self.series[i].push(value.value)
            if self.uiActive {
                self.chips[value.label]?.set(value: value.value.map(format) ?? "—")
            }
        }
        self.chart.series = self.series
        if self.uiActive {
            self.axisField.stringValue = "\(self.format(self.axisMax())) \(self.unit)"
        }
        self.chart.axisMax = self.axisMax()
        self.chart.axisMin = self.axisMin()
    }

    func setFault(_ key: String, _ faulted: Bool) {
        if let idx = self.series.firstIndex(where: { $0.key == key }) {
            self.series[idx].faulted = faulted
        }
        self.chips[key]?.set(faulted: faulted)
    }

    func refresh() {
        self.chart.needsDisplay = true
    }

    private func axisMax() -> Double {
        switch self.scale {
        case .fixedRange(_, let top): return top
        case .fixed(let top): return top
        case .auto(let floor, let steps):
            let peak = self.series.flatMap { $0.values.compactMap { $0 } }.max() ?? 0
            return steps.first(where: { $0 >= peak * 1.11 }) ?? max(steps.last ?? floor, peak)
        }
    }

    private func axisMin() -> Double {
        if case .fixedRange(let bottom, _) = self.scale { return bottom }
        return 0
    }

    private func rebuildChips(format: @escaping (Double) -> String) {
        self.chipsRows.forEach { $0.removeFromSuperview() }
        self.chart.removeFromSuperview()
        self.chipsRows = []
        self.chips = [:]

        var row: NSStackView? = nil
        for (i, s) in self.series.enumerated() {
            if i % 5 == 0 {
                row = NSStackView(frame: NSRect(x: 0, y: 0, width: popupWidth, height: 20))
                row?.orientation = .horizontal
                row?.spacing = 4
                row?.heightAnchor.constraint(equalToConstant: 20).isActive = true
                self.addArrangedSubview(row!)
                self.chipsRows.append(row!)
            }
            let chip = PowerChipView(label: s.label, color: s.color)
            self.chips[s.key] = chip
            row?.addArrangedSubview(chip)
        }
        self.addArrangedSubview(self.chart)

        let rows = CGFloat(self.chipsRows.count)
        self.panelHeight = 16 + 4 + rows * 24 + 72
        if let constraint = self.heightConstraint {
            constraint.constant = self.panelHeight
        } else {
            self.heightConstraint = self.heightAnchor.constraint(equalToConstant: self.panelHeight)
            self.heightConstraint?.isActive = true
        }
    }
}

// MARK: - chip

private class PowerChipView: NSStackView {
    private let valueField: NSTextField
    private let labelField: NSTextField
    private let swatch: NSView

    init(label: String, color: NSColor) {
        self.swatch = NSView(frame: NSRect(x: 0, y: 0, width: 3, height: 12))
        self.swatch.wantsLayer = true
        self.swatch.layer?.backgroundColor = color.cgColor
        self.swatch.widthAnchor.constraint(equalToConstant: 3).isActive = true
        self.swatch.heightAnchor.constraint(equalToConstant: 12).isActive = true

        self.labelField = NSTextField(labelWithString: label)
        self.labelField.font = NSFont.systemFont(ofSize: 10)
        self.labelField.textColor = .secondaryLabelColor

        self.valueField = NSTextField(labelWithString: "—")
        self.valueField.font = NSFont.monospacedDigitSystemFont(ofSize: 10, weight: .medium)
        self.valueField.textColor = .labelColor

        super.init(frame: NSRect(x: 0, y: 0, width: 66, height: 20))
        self.orientation = .horizontal
        self.spacing = 3
        self.addArrangedSubview(self.swatch)
        self.addArrangedSubview(self.labelField)
        self.addArrangedSubview(self.valueField)
        self.widthAnchor.constraint(greaterThanOrEqualToConstant: 62).isActive = true
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func set(value: String) {
        if self.valueField.stringValue != value {
            self.valueField.stringValue = value
        }
    }

    func set(faulted: Bool) {
        self.valueField.textColor = faulted ? .systemRed : .labelColor
        if faulted {
            self.valueField.stringValue = "OFF"
        }
    }
}

// MARK: - chart (multi-series, ring-buffered, no layout on tick)

internal class PowerChartView: NSView {
    internal var series: [PowerSeries] = []
    internal var axisMax: Double = 1
    internal var axisMin: Double = 0

    override func draw(_ dirtyRect: NSRect) {
        guard let context = NSGraphicsContext.current?.cgContext else { return }
        let bounds = self.bounds

        context.setFillColor(NSColor.textBackgroundColor.withAlphaComponent(0.4).cgColor)
        context.fill(bounds)

        // hairline at 50%
        context.setStrokeColor(NSColor.separatorColor.cgColor)
        context.setLineWidth(0.5)
        context.move(to: CGPoint(x: 0, y: bounds.height / 2))
        context.addLine(to: CGPoint(x: bounds.width, y: bounds.height / 2))
        context.strokePath()

        let range = max(self.axisMax - self.axisMin, 0.001)
        let stepX = bounds.width / CGFloat(historyLength - 1)

        // filled series behind the lines
        for s in self.series.sorted(by: { $0.filled && !$1.filled }) {
            guard !s.values.isEmpty else { continue }
            let offset = historyLength - s.values.count
            
            // contiguous segments, split on missing ticks, so fills never bridge a gap
            var segments: [[CGPoint]] = []
            var current: [CGPoint] = []
            for (i, value) in s.values.enumerated() {
                guard let value else {
                    if !current.isEmpty { segments.append(current); current = [] }
                    continue
                }
                let x = CGFloat(offset + i) * stepX
                let y = CGFloat((min(max(value, self.axisMin), self.axisMax) - self.axisMin) / range) * (bounds.height - 2) + 1
                current.append(CGPoint(x: x, y: y))
            }
            if !current.isEmpty { segments.append(current) }
            guard !segments.isEmpty else { continue }
            
            if s.filled {
                context.setFillColor(s.color.withAlphaComponent(0.18).cgColor)
                for segment in segments {
                    let fill = CGMutablePath()
                    fill.addLines(between: segment)
                    fill.addLine(to: CGPoint(x: segment.last!.x, y: 0))
                    fill.addLine(to: CGPoint(x: segment.first!.x, y: 0))
                    fill.closeSubpath()
                    context.addPath(fill)
                }
                context.fillPath()
            }
            
            let path = CGMutablePath()
            for segment in segments {
                path.addLines(between: segment)
            }
            context.setStrokeColor((s.faulted ? NSColor.systemRed : s.color).cgColor)
            context.setLineWidth(s.filled ? 1.5 : 1)
            if s.dashedWhenZero && (s.current ?? 1) == 0 {
                context.setLineDash(phase: 0, lengths: [3, 3])
            } else {
                context.setLineDash(phase: 0, lengths: [])
            }
            context.addPath(path)
            context.strokePath()
            context.setLineDash(phase: 0, lengths: [])
        }
    }
}
