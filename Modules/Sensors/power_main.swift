//
//  power_main.swift
//  Sensors
//
//  The Power module (fork addition, INFRA-45): an Intel-Power-Gadget-style live view of
//  package/CPU/GPU/ANE power, per-cluster frequency, temperature and utilization.
//  Lives in the Sensors framework to share its IOReport/HID bridging; ships its own
//  power-config.plist. Apple Silicon only, and never spawns powermetrics.
//

import Cocoa
import Kit

public class Power: Module {
    private let popupView: PowerPopup = PowerPopup()
    private var reader: PowerReader? = nil

    private var textValue: String {
        Store.shared.string(key: "\(self.name)_textWidgetValue", defaultValue: "$power W")
    }

    public init() {
        super.init(
            moduleType: .power,
            popup: self.popupView,
            configName: "power-config"
        )
        guard self.available else { return }

        self.reader = PowerReader(.power) { [weak self] value in
            if let value {
                self?.snapshotCallback(value)
            }
        }

        self.setReaders([self.reader])
    }

    public override func isAvailable() -> Bool {
        SystemKit.shared.device.arch == "arm64"
    }

    private func snapshotCallback(_ snapshot: PowerSnapshot) {
        guard self.enabled else { return }

        self.popupView.callback(snapshot)

        let package = snapshot.packagePower ?? 0
        self.menuBar.widgets.filter { $0.isActive }.forEach { (w: SWidget) in
            switch w.item {
            case let widget as TextWidget:
                var text = "\(self.textValue)"
                let pairs = TextWidget.parseText(text)
                pairs.forEach { pair in
                    var replacement: String? = nil
                    switch pair.key {
                    case "$power": replacement = String(format: "%.1f", package)
                    case "$cpu": replacement = String(format: "%.1f", snapshot.cpuPower ?? 0)
                    case "$gpu": replacement = String(format: "%.1f", snapshot.gpuPower ?? 0)
                    case "$ane": replacement = String(format: "%.1f", snapshot.anePower ?? 0)
                    default: return
                    }
                    if let replacement {
                        let key = pair.value.isEmpty ? pair.key : "\(pair.key).\(pair.value)"
                        text = text.replacingOccurrences(of: key, with: replacement)
                    }
                }
                widget.setValue(text)
            default: break
            }
        }
    }
}
