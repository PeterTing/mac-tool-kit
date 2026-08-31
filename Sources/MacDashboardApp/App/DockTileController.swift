import AppKit

/// Draws a live CPU / RAM / GPU / temperature meter into the Dock icon, in the
/// spirit of Activity Monitor's "Show CPU Usage" Dock icon — but with all four
/// channels visible at once.
@MainActor
final class DockTileController {

    static let shared = DockTileController()

    private static let defaultsKey = "dockTileUsageEnabled"

    private let gaugeView = DockGaugeView(frame: NSRect(x: 0, y: 0, width: 128, height: 128))

    private(set) var isEnabled: Bool {
        get { UserDefaults.standard.object(forKey: Self.defaultsKey) as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: Self.defaultsKey) }
    }

    private init() {}

    func activate() {
        apply()
    }

    func setEnabled(_ enabled: Bool) {
        isEnabled = enabled
        apply()
    }

    func toggle() {
        setEnabled(!isEnabled)
    }

    /// Feed fresh utilization values in. Cheap: it only redraws when something
    /// moved enough to be visible at Dock resolution.
    func update(cpu: Double, ram: Double, gpu: Double) {
        guard isEnabled else { return }
        if gaugeView.setValues(cpu: cpu, ram: ram, gpu: gpu) {
            NSApp.dockTile.display()
        }
    }

    /// Temperature arrives from the thermal poller rather than the metrics
    /// sampler, so it updates on its own cadence. `nil` means no component
    /// reported a measurement, and the bar is drawn empty rather than as zero.
    func updateTemperature(_ celsius: Double?) {
        guard isEnabled else { return }
        if gaugeView.setTemperature(celsius) {
            NSApp.dockTile.display()
        }
    }

    private func apply() {
        NSApp.dockTile.contentView = isEnabled ? gaugeView : nil
        NSApp.dockTile.display()
    }
}

// MARK: - Gauge View

final class DockGaugeView: NSView {

    private var cpu: Double = 0
    private var ram: Double = 0
    private var gpu: Double = 0
    private var temperature: Double? = nil

    /// Dock bar scale for temperature. Below `min` a Mac is simply idle-cool
    /// and below `max` it has not yet reached the throttling range, so this
    /// window is where the useful resolution is.
    private enum TemperatureScale {
        static let min: Double = 30
        static let max: Double = 100
        static let hot: Double = 85
    }

    private enum Palette {
        static let background = NSColor(srgbRed: 0.07, green: 0.08, blue: 0.10, alpha: 0.94)
        static let border     = NSColor(white: 1.0, alpha: 0.14)
        static let track      = NSColor(white: 1.0, alpha: 0.13)
        static let label      = NSColor(white: 1.0, alpha: 0.62)
        static let cpu        = NSColor(srgbRed: 0.24, green: 0.66, blue: 1.00, alpha: 1.0)  // blue
        static let ram        = NSColor(srgbRed: 0.68, green: 0.40, blue: 0.98, alpha: 1.0)  // purple
        static let gpu        = NSColor(srgbRed: 1.00, green: 0.62, blue: 0.10, alpha: 1.0)  // amber
        static let temp       = NSColor(srgbRed: 0.16, green: 0.80, blue: 0.72, alpha: 1.0)  // teal
        static let hot        = NSColor(srgbRed: 1.00, green: 0.27, blue: 0.30, alpha: 1.0)  // red
    }

    /// Returns true when the change is big enough to be worth a redraw.
    func setValues(cpu: Double, ram: Double, gpu: Double) -> Bool {
        let c = cpu.clampedPercentage(), r = ram.clampedPercentage(), g = gpu.clampedPercentage()
        let moved = abs(c - self.cpu) >= 0.5 || abs(r - self.ram) >= 0.5 || abs(g - self.gpu) >= 0.5
        self.cpu = c; self.ram = r; self.gpu = g
        if moved { needsDisplay = true }
        return moved
    }

    func setTemperature(_ celsius: Double?) -> Bool {
        let sanitized: Double? = {
            guard let celsius, celsius.isFinite, celsius > 0 else { return nil }
            return celsius
        }()

        let moved: Bool
        switch (temperature, sanitized) {
        case (nil, nil): moved = false
        case let (old?, new?): moved = abs(old - new) >= 0.5
        default: moved = true
        }

        temperature = sanitized
        if moved { needsDisplay = true }
        return moved
    }

    override func draw(_ dirtyRect: NSRect) {
        let side = min(bounds.width, bounds.height)
        let scale = side / 128.0
        func s(_ v: CGFloat) -> CGFloat { v * scale }

        // Card background
        let card = NSRect(x: s(4), y: s(4), width: s(120), height: s(120))
        let cardPath = NSBezierPath(roundedRect: card, xRadius: s(27), yRadius: s(27))
        Palette.background.setFill()
        cardPath.fill()
        Palette.border.setStroke()
        cardPath.lineWidth = s(1.5)
        cardPath.stroke()

        let barWidth = s(18)
        let gap = s(9)
        let totalWidth = barWidth * 4 + gap * 3
        let startX = (bounds.width - totalWidth) / 2
        let barBottom = s(30)
        let barHeight = s(82)

        var entries: [(fraction: Double, color: NSColor, label: String)] = [
            (cpu / 100, cpu >= 90 ? Palette.hot : Palette.cpu, "C"),
            (ram / 100, ram >= 90 ? Palette.hot : Palette.ram, "R"),
            (gpu / 100, gpu >= 90 ? Palette.hot : Palette.gpu, "G")
        ]

        if let temperature {
            let span = TemperatureScale.max - TemperatureScale.min
            let fraction = (temperature - TemperatureScale.min) / span
            entries.append((
                min(1, max(0, fraction)),
                temperature >= TemperatureScale.hot ? Palette.hot : Palette.temp,
                "T"
            ))
        } else {
            // No measured sensor: an empty track is honest, a zero bar is not.
            entries.append((0, Palette.temp, "T"))
        }

        for (index, entry) in entries.enumerated() {
            let x = startX + CGFloat(index) * (barWidth + gap)
            let track = NSRect(x: x, y: barBottom, width: barWidth, height: barHeight)
            let radius = barWidth / 2
            let trackPath = NSBezierPath(roundedRect: track, xRadius: radius, yRadius: radius)

            Palette.track.setFill()
            trackPath.fill()

            if entry.fraction > 0.005 {
                NSGraphicsContext.saveGraphicsState()
                trackPath.addClip()

                let filledHeight = max(barWidth, barHeight * CGFloat(entry.fraction))
                let fillRect = NSRect(x: x, y: barBottom, width: barWidth, height: filledHeight)
                let bottom = entry.color.blended(withFraction: 0.35, of: .black) ?? entry.color
                NSGradient(starting: bottom, ending: entry.color)?.draw(in: fillRect, angle: 90)

                NSGraphicsContext.restoreGraphicsState()
            }

            // Channel letter beneath the bar
            let attributes: [NSAttributedString.Key: Any] = [
                .font: NSFont.systemFont(ofSize: s(14), weight: .bold),
                .foregroundColor: Palette.label
            ]
            let text = entry.label as NSString
            let size = text.size(withAttributes: attributes)
            text.draw(
                at: NSPoint(x: x + (barWidth - size.width) / 2, y: s(9)),
                withAttributes: attributes
            )
        }
    }
}

private extension Double {
    func clampedPercentage() -> Double {
        if isNaN || isInfinite { return 0 }
        return Swift.min(100, Swift.max(0, self))
    }
}
