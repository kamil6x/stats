//
//  power_popup.swift
//  Sensors
//
//  Popup for the Power module (fork addition, INFRA-45): an Intel-Power-Gadget-style stack of
//  four card panels (power, frequency, temperature, utilization), per the Claude Design spec
//  of 2026-11-02 and the Mx-Power-Gadget-reference critique round (research-ui/).
//

import Cocoa
import Kit

private let popupWidth: CGFloat = 360
private let cardWidth: CGFloat = 344
private let cardInset: CGFloat = 10
private let cardContentWidth: CGFloat = cardWidth - cardInset * 2
private let chartHeight: CGFloat = 72
private let axisGutter: CGFloat = 24
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
    private let header: PowerHeaderView
    private let powerPanel: PowerPanelView
    private let frequencyPanel: PowerPanelView
    private let temperaturePanel: PowerPanelView
    private let utilizationPanel: PowerPanelView

    // parked-P fault detection: red only when a P cluster is at 0 MHz while CPU use >50% for >=3 s
    private var faultCounters: [String: Int] = [:]
    internal var forceUI = false

    public init() {
        self.header = PowerHeaderView(width: popupWidth)
        self.powerPanel = PowerPanelView(title: "Power", unit: "W", accent: PowerColors.cpu, scale: .auto(floor: 10, steps: []))
        self.frequencyPanel = PowerPanelView(title: "Frequency", unit: "GHz", accent: PowerColors.eCluster, scale: .fixed(1))
        self.temperaturePanel = PowerPanelView(title: "Temperature", unit: "°C", accent: PowerColors.tempAvg, scale: .fixedRange(20, 110))
        self.utilizationPanel = PowerPanelView(title: "Utilization", unit: "%", accent: PowerColors.gpu, scale: .fixedRange(0, 100))

        super.init(.power, frame: NSRect(x: 0, y: 0, width: popupWidth, height: 560))

        self.orientation = .vertical
        self.alignment = .centerX
        self.spacing = 8

        self.addArrangedSubview(self.header)
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
        let height = self.header.frame.height + panels.reduce(0) { $0 + $1.panelHeight } + CGFloat(panels.count) * self.spacing
        if self.frame.height != height {
            self.setFrameSize(NSSize(width: popupWidth, height: height))
            self.sizeCallback?(self.frame.size)
        }
    }

    internal func feedSynchronously(_ snapshot: PowerSnapshot) {
        self.store(snapshot)
        [self.powerPanel, self.frequencyPanel, self.temperaturePanel, self.utilizationPanel].forEach { $0.refresh() }
        self.recalculateHeight()
    }

    internal func callback(_ snapshot: PowerSnapshot) {
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.store(snapshot)
            guard self.window?.isVisible ?? false else { return }
            [self.powerPanel, self.frequencyPanel, self.temperaturePanel, self.utilizationPanel].forEach { $0.refresh() }
            self.recalculateHeight()
        }
    }

    private func store(_ snapshot: PowerSnapshot) {
        let visible = self.forceUI || (self.window?.isVisible ?? false)
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

        self.header.update()
    }
}

// MARK: - header

private class PowerHeaderView: NSStackView {
    private let titleField = NSTextField(labelWithString: " ")
    private let subtitleField = NSTextField(labelWithString: " ")
    private var filled = false

    init(width: CGFloat) {
        super.init(frame: NSRect(x: 0, y: 0, width: width, height: 44))
        self.orientation = .vertical
        self.alignment = .leading
        self.spacing = 1
        self.edgeInsets = NSEdgeInsets(top: 6, left: 4, bottom: 0, right: 4)

        self.titleField.font = NSFont.systemFont(ofSize: 14, weight: .semibold)
        self.subtitleField.font = NSFont.systemFont(ofSize: 11, weight: .regular)
        self.subtitleField.textColor = .secondaryLabelColor
        self.addArrangedSubview(self.titleField)
        self.addArrangedSubview(self.subtitleField)
        self.heightAnchor.constraint(equalToConstant: 44).isActive = true
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
        self.filled = !self.titleField.stringValue.trimmingCharacters(in: .whitespaces).isEmpty
    }
}

// MARK: - panel card (title row + chips + chart)

internal enum PowerPanelScale {
    case auto(floor: Double, steps: [Double])
    case fixed(Double)
    case fixedRange(Double, Double)
}

internal class PowerPanelView: NSStackView {
    internal var uiActive: Bool = false
    internal var collapsed: Bool = false
    internal var scale: PowerPanelScale
    internal private(set) var panelHeight: CGFloat = 120

    private let unit: String
    private let accent: NSColor
    private let titleField = NSTextField(labelWithString: "")
    private let unitField = NSTextField(labelWithString: "")
    private var heightConstraint: NSLayoutConstraint? = nil
    private var chipsRows: [NSStackView] = []
    private var chips: [String: PowerChipView] = [:]
    private let chart: PowerChartView
    private var series: [PowerSeries] = []
    private var format: (Double) -> String

    init(title: String, unit: String, accent: NSColor, scale: PowerPanelScale) {
        self.unit = unit
        self.accent = accent
        self.scale = scale
        self.chart = PowerChartView(frame: NSRect(x: 0, y: 0, width: cardContentWidth, height: chartHeight))
        self.format = { String(format: "%.1f", $0) }

        super.init(frame: NSRect(x: 0, y: 0, width: popupWidth, height: 120))
        self.orientation = .vertical
        self.alignment = .leading
        self.spacing = 6
        self.edgeInsets = NSEdgeInsets(top: 8, left: cardInset, bottom: 10, right: cardInset)
        self.wantsLayer = true
        self.layer?.cornerRadius = 8
        self.layer?.borderWidth = 0.5
        self.widthAnchor.constraint(equalToConstant: cardWidth).isActive = true

        let titleRow = NSStackView(frame: .zero)
        titleRow.orientation = .horizontal
        titleRow.distribution = .fill
        self.titleField.stringValue = title
        self.titleField.font = NSFont.systemFont(ofSize: 12, weight: .semibold)
        self.titleField.textColor = accent
        self.unitField.stringValue = unit
        self.unitField.font = NSFont.systemFont(ofSize: 11, weight: .medium)
        self.unitField.textColor = .secondaryLabelColor
        titleRow.addArrangedSubview(self.titleField)
        titleRow.addArrangedSubview(NSView())
        titleRow.addArrangedSubview(self.unitField)
        titleRow.heightAnchor.constraint(equalToConstant: 16).isActive = true
        self.addArrangedSubview(titleRow)
        titleRow.widthAnchor.constraint(equalToConstant: cardContentWidth).isActive = true

        self.chart.heightAnchor.constraint(equalToConstant: chartHeight).isActive = true
        self.chart.widthAnchor.constraint(equalToConstant: cardContentWidth).isActive = true
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    private func applyCardStyle() {
        self.effectiveAppearance.performAsCurrentDrawingAppearance {
            let dark = self.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            self.layer?.backgroundColor = dark
                ? NSColor.white.withAlphaComponent(0.06).cgColor
                : NSColor.controlBackgroundColor.withAlphaComponent(0.85).cgColor
            self.layer?.borderColor = NSColor.separatorColor.cgColor
        }
    }

    override func updateLayer() {
        super.updateLayer()
        self.applyCardStyle()
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        self.applyCardStyle()
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        self.applyCardStyle()
    }

    func update(_ newValues: [(label: String, value: Double?, color: NSColor, filled: Bool, dashedWhenZero: Bool)], format: @escaping (Double) -> String) {
        if self.series.count != newValues.count {
            self.series = newValues.map { PowerSeries(key: $0.label, label: $0.label, color: $0.color, filled: $0.filled, dashedWhenZero: $0.dashedWhenZero) }
            self.rebuildChips()
        }
        self.format = format
        for (i, value) in newValues.enumerated() {
            self.series[i].push(value.value)
            if self.uiActive && !self.collapsed {
                self.chips[value.label]?.set(value: value.value.map(format) ?? "—")
            }
        }
        if self.uiActive && self.collapsed {
            let groups = Dictionary(grouping: newValues, by: { String($0.label.prefix(1)) })
            for (prefix, members) in groups {
                let present = members.compactMap { $0.value }
                let avg = present.isEmpty ? nil : present.reduce(0, +) / Double(present.count)
                let parked = members.filter { $0.value == 0 }.count
                var text = avg.map(format) ?? "—"
                if parked > 0 { text += " ·\(parked)⏸" }
                self.chips["summary-\(prefix)"]?.set(value: text)
            }
        }
        self.chart.series = self.series
        self.chart.axisMax = self.axisMax()
        self.chart.axisMin = self.axisMin()
        self.chart.axisFormat = self.format
    }

    private func summaryDefinitions() -> [(key: String, label: String, color: NSColor)] {
        var result: [(String, String, NSColor)] = []
        let groups = Dictionary(grouping: self.series, by: { String($0.label.prefix(1)) })
        for (prefix, members) in groups.sorted(by: { $0.key < $1.key }) {
            result.append(("summary-\(prefix)", "\(prefix) ×\(members.count)", members.first?.color ?? .labelColor))
        }
        return result
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
        case .auto(let floor, _):
            // tight MxPG-style scale: ~1.2x the visible 120 s max, rounded up to a clean step.
            // single-sample transients (launch bursts) above 3x the window median are excluded
            // from the scale - they draw clipped at the top instead of flattening everything else
            // filter outliers per series: a quiet series (ANE at 0) must not drag the median down
            var peak: Double = 0
            for s in self.series {
                let values = s.values.compactMap { $0 }.sorted()
                guard !values.isEmpty else { continue }
                let median = values[values.count / 2]
                let seriesPeak = values.last { median <= 0.5 || $0 <= median * 3 } ?? values.last ?? 0
                peak = max(peak, seriesPeak)
            }
            let target = max(peak * 1.2, floor)
            let step: Double = target <= 50 ? 5 : 25
            return (target / step).rounded(.up) * step
        }
    }

    private func axisMin() -> Double {
        if case .fixedRange(let bottom, _) = self.scale { return bottom }
        return 0
    }

    private func rebuildChips() {
        self.chipsRows.forEach { $0.removeFromSuperview() }
        self.chart.removeFromSuperview()
        self.chipsRows = []
        self.chips = [:]

        // every chip shares ONE row, sized evenly to the card width; below a readable minimum
        // the panel collapses to per-type summary chips (E avg / P avg + parked count) - per-cluster
        // detail stays visible as the chart lines (the reason this card exists, ROD-4)
        let minChipWidth: CGFloat = 46
        let fits = CGFloat(self.series.count) * minChipWidth + CGFloat(max(self.series.count - 1, 0)) * 6 <= cardContentWidth
        self.collapsed = !fits
        let chipKeys: [(key: String, label: String, color: NSColor)] = self.collapsed
            ? self.summaryDefinitions()
            : self.series.map { ($0.key, $0.label, $0.color) }

        let row = NSStackView(frame: .zero)
        row.orientation = .horizontal
        row.alignment = .top
        row.distribution = .fillEqually
        row.spacing = 6
        row.widthAnchor.constraint(equalToConstant: cardContentWidth).isActive = true
        row.heightAnchor.constraint(equalToConstant: 30).isActive = true
        self.addArrangedSubview(row)
        self.chipsRows.append(row)
        for definition in chipKeys {
            let chip = PowerChipView(label: definition.label, color: definition.color)
            self.chips[definition.key] = chip
            row.addArrangedSubview(chip)
        }
        self.addArrangedSubview(self.chart)

        let rows = CGFloat(self.chipsRows.count)
        // 8 top + 16 title + 6 gap + rows*(30+6) + chart + 10 bottom
        self.panelHeight = 8 + 16 + 6 + rows * 36 + chartHeight + 10
        if let constraint = self.heightConstraint {
            constraint.constant = self.panelHeight
        } else {
            self.heightConstraint = self.heightAnchor.constraint(equalToConstant: self.panelHeight)
            self.heightConstraint?.isActive = true
        }
    }
}

// MARK: - chip (label over value, colored underline under the value)

private class PowerChipView: NSView {
    private let labelField: NSTextField
    private let valueField: NSTextField
    private let underline: NSView
    private let color: NSColor

    init(label: String, color: NSColor) {
        self.color = color
        self.labelField = NSTextField(labelWithString: label)
        self.labelField.font = NSFont.systemFont(ofSize: 10, weight: .regular)
        self.labelField.textColor = .secondaryLabelColor

        self.valueField = NSTextField(labelWithString: "—")
        self.valueField.font = NSFont.monospacedDigitSystemFont(ofSize: 13, weight: .semibold)
        self.valueField.textColor = .labelColor

        self.underline = NSView(frame: .zero)
        self.underline.wantsLayer = true
        self.underline.layer?.cornerRadius = 1

        super.init(frame: NSRect(x: 0, y: 0, width: 56, height: 30))
        self.translatesAutoresizingMaskIntoConstraints = false
        [self.labelField, self.valueField, self.underline].forEach {
            $0.translatesAutoresizingMaskIntoConstraints = false
            self.addSubview($0)
        }

        NSLayoutConstraint.activate([
            self.widthAnchor.constraint(greaterThanOrEqualToConstant: 52),
            self.heightAnchor.constraint(equalToConstant: 30),
            self.labelField.topAnchor.constraint(equalTo: self.topAnchor),
            self.labelField.leadingAnchor.constraint(equalTo: self.leadingAnchor),
            self.valueField.topAnchor.constraint(equalTo: self.labelField.bottomAnchor),
            self.valueField.leadingAnchor.constraint(equalTo: self.leadingAnchor),
            self.valueField.trailingAnchor.constraint(lessThanOrEqualTo: self.trailingAnchor),
            self.underline.topAnchor.constraint(equalTo: self.valueField.bottomAnchor, constant: 1),
            self.underline.leadingAnchor.constraint(equalTo: self.leadingAnchor),
            self.underline.trailingAnchor.constraint(equalTo: self.trailingAnchor, constant: -6),
            self.underline.heightAnchor.constraint(equalToConstant: 2)
        ])
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func updateLayer() {
        super.updateLayer()
        self.underline.layer?.backgroundColor = self.color.cgColor
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        self.effectiveAppearance.performAsCurrentDrawingAppearance {
            self.underline.layer?.backgroundColor = self.color.cgColor
        }
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        self.effectiveAppearance.performAsCurrentDrawingAppearance {
            self.underline.layer?.backgroundColor = self.color.cgColor
        }
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

// MARK: - chart (multi-series, dotted grid, right-edge axis labels)

internal class PowerChartView: NSView {
    internal var series: [PowerSeries] = []
    internal var axisMax: Double = 1
    internal var axisMin: Double = 0
    internal var axisFormat: (Double) -> String = { String(format: "%.0f", $0) }

    override func draw(_ dirtyRect: NSRect) {
        guard let context = NSGraphicsContext.current?.cgContext else { return }
        let bounds = self.bounds
        let range = max(self.axisMax - self.axisMin, 0.001)
        let plotWidth = bounds.width - axisGutter
        let plotHeight = bounds.height - 2
        
        // dotted grid: horizontals at 0/25/50/75/100%, verticals every 20 s
        context.setStrokeColor(NSColor.separatorColor.withAlphaComponent(0.6).cgColor)
        context.setLineWidth(0.5)
        context.setLineDash(phase: 0, lengths: [1, 2])
        for fraction in [0.0, 0.25, 0.5, 0.75, 1.0] {
            let y = CGFloat(fraction) * (plotHeight - 2) + 1
            context.move(to: CGPoint(x: 0, y: y))
            context.addLine(to: CGPoint(x: plotWidth, y: y))
        }
        for i in 1...6 {
            let x = CGFloat(i) * plotWidth / 6
            context.move(to: CGPoint(x: x, y: 1))
            context.addLine(to: CGPoint(x: x, y: plotHeight - 1))
        }
        context.strokePath()
        context.setLineDash(phase: 0, lengths: [])
        
        // axis labels in the right gutter at max and mid
        let labelFont = NSFont.monospacedDigitSystemFont(ofSize: 9, weight: .regular)
        let attributes: [NSAttributedString.Key: Any] = [.font: labelFont, .foregroundColor: NSColor.tertiaryLabelColor]
        for (fraction, value) in [(1.0, self.axisMax), (0.5, self.axisMin + range / 2)] {
            let text = NSAttributedString(string: self.axisFormat(value), attributes: attributes)
            let size = text.size()
            let y = CGFloat(fraction) * (plotHeight - 2) + 1
            text.draw(at: NSPoint(x: plotWidth + 3, y: min(y - size.height / 2, bounds.height - size.height)))
        }
        
        let stepX = plotWidth / CGFloat(historyLength - 1)
        
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
                let y = CGFloat((min(max(value, self.axisMin), self.axisMax) - self.axisMin) / range) * (plotHeight - 4) + 1
                current.append(CGPoint(x: x, y: y))
            }
            if !current.isEmpty { segments.append(current) }
            guard !segments.isEmpty else { continue }
            
            if s.filled {
                context.setFillColor(s.color.withAlphaComponent(0.12).cgColor)
                for segment in segments {
                    let fill = CGMutablePath()
                    fill.addLines(between: segment)
                    fill.addLine(to: CGPoint(x: segment.last!.x, y: 1))
                    fill.addLine(to: CGPoint(x: segment.first!.x, y: 1))
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
            context.setLineWidth(s.filled ? 1.5 : 1.25)
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

// MARK: - offscreen render harness

// Renders the popup from the REAL PowerReader after `seconds` of live sampling.
public func renderPowerPopupLive(prefix: String, seconds: Int) {
    let popup = PowerPopup()
    popup.forceUI = true

    let reader = PowerReader(.power) { snapshot in
        if let snapshot {
            DispatchQueue.main.async { popup.feedSynchronously(snapshot) }
        }
    }
    reader.read()
    let timer = Timer(timeInterval: 1, repeats: true) { _ in reader.read() }
    RunLoop.main.add(timer, forMode: .common)
    RunLoop.main.run(until: Date().addingTimeInterval(TimeInterval(seconds)))
    timer.invalidate()

    writePopupRenders(popup, prefix: prefix)
}

// Draws the popup with synthetic M3-Ultra-shaped data into PNGs, so the design can be reviewed
// without launching the app (no status items, no TCC).
public func renderPowerPopup(prefix: String) {
    let popup = PowerPopup()
    popup.forceUI = true

    var snapshots: [PowerSnapshot] = []
    for i in 0..<120 {
        let t = Double(i)
        var s = PowerSnapshot()
        let burst = (40..<75).contains(i) ? 1.0 : 0.15
        s.cpuPower = 8 + 22 * burst + 3 * sin(t / 5)
        s.gpuPower = 2 + 9 * burst * max(0, sin(t / 9))
        s.anePower = (55..<70).contains(i) ? 3.5 : 0.1
        s.packagePower = (s.cpuPower ?? 0) + (s.gpuPower ?? 0) + (s.anePower ?? 0)
        s.clusters = [
            PowerCluster(name: "E0", type: .efficiency, frequency: 1400 + 500 * burst + 60 * sin(t / 4)),
            PowerCluster(name: "E1", type: .efficiency, frequency: 1350 + 480 * burst + 50 * cos(t / 5)),
            PowerCluster(name: "P0", type: .performance, frequency: 1200 + 2800 * burst + 100 * sin(t / 3)),
            PowerCluster(name: "P1", type: .performance, frequency: 1100 + 2850 * burst + 90 * cos(t / 4)),
            PowerCluster(name: "P2", type: .performance, frequency: i > 90 ? 0 : 1150 + 2800 * burst),
            PowerCluster(name: "P3", type: .performance, frequency: 1180 + 2750 * burst)
        ]
        s.cpuTempAvg = 48 + 18 * burst + sin(t / 6)
        s.cpuTempMax = (s.cpuTempAvg ?? 50) + 6
        s.gpuTemp = 45 + 10 * burst
        s.cpuUtilization = 0.12 + 0.75 * burst
        s.gpuUtilization = 0.05 + 0.5 * burst * max(0, sin(t / 9))
        snapshots.append(s)
    }

    for s in snapshots {
        popup.feedSynchronously(s)
    }
    writePopupRenders(popup, prefix: prefix)
}

private func writePopupRenders(_ popup: PowerPopup, prefix: String) {
    let container = NSView(frame: NSRect(x: 0, y: 0, width: popupWidth + 16, height: 800))
    container.wantsLayer = true
    container.addSubview(popup)
    popup.setFrameOrigin(NSPoint(x: 8, y: 8))

    let window = NSWindow(contentRect: container.frame, styleMask: .borderless, backing: .buffered, defer: false)
    window.contentView = container

    for (name, appearance) in [("light", NSAppearance.Name.aqua), ("dark", NSAppearance.Name.darkAqua)] {
        window.appearance = NSAppearance(named: appearance)
        container.appearance = NSAppearance(named: appearance)
        container.setFrameSize(NSSize(width: popupWidth + 16, height: popup.frame.height + 16))
        window.setContentSize(container.frame.size)
        container.effectiveAppearance.performAsCurrentDrawingAppearance {
            container.layer?.backgroundColor = NSColor.windowBackgroundColor.cgColor
        }
        container.layoutSubtreeIfNeeded()
        container.needsDisplay = true
        guard let rep = container.bitmapImageRepForCachingDisplay(in: container.bounds) else { continue }
        container.cacheDisplay(in: container.bounds, to: rep)
        if let png = rep.representation(using: .png, properties: [:]) {
            try? png.write(to: URL(fileURLWithPath: "\(prefix)-\(name).png"))
        }
    }
}
