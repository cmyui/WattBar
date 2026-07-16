import AppKit

enum NetworkGraphRenderer {
    static func statusImage(samples: [NetworkSample], window: Int) -> NSImage? {
        let visible = Array(samples.suffix(window))
        guard !visible.isEmpty else { return nil }

        let chartWidth: CGFloat = 42
        let leadingPadding: CGFloat = 8
        let size = NSSize(width: leadingPadding + chartWidth, height: 16)
        return NSImage(size: size, flipped: false) { bounds in
            let chartBounds = NSRect(
                x: bounds.minX + leadingPadding,
                y: bounds.minY,
                width: chartWidth,
                height: bounds.height
            )
            draw(samples: visible, in: chartBounds, lineWidth: 1)
            return true
        }
    }

    static func draw(samples: [NetworkSample], in bounds: NSRect, lineWidth: CGFloat) {
        guard !samples.isEmpty else { return }
        let centerY = bounds.midY
        let maximum = max(samples.flatMap { [$0.received, $0.sent] }.max() ?? 1, 1)

        NSColor.separatorColor.withAlphaComponent(0.7).setStroke()
        let baseline = NSBezierPath()
        baseline.move(to: NSPoint(x: bounds.minX, y: centerY))
        baseline.line(to: NSPoint(x: bounds.maxX, y: centerY))
        baseline.lineWidth = 0.5
        baseline.stroke()

        draw(
            values: samples.map(\.received),
            maximum: maximum,
            direction: 1,
            color: .systemCyan,
            bounds: bounds,
            lineWidth: lineWidth
        )
        draw(
            values: samples.map(\.sent),
            maximum: maximum,
            direction: -1,
            color: .systemRed,
            bounds: bounds,
            lineWidth: lineWidth
        )
    }

    private static func draw(
        values: [Double],
        maximum: Double,
        direction: Double,
        color: NSColor,
        bounds: NSRect,
        lineWidth: CGFloat
    ) {
        let path = NSBezierPath()
        let step = bounds.width / CGFloat(max(values.count - 1, 1))

        for (index, value) in values.enumerated() {
            let x = bounds.minX + CGFloat(index) * step
            let height = CGFloat(value / maximum) * (bounds.height / 2 - 1)
            let point = NSPoint(x: x, y: bounds.midY + direction * height)
            index == 0 ? path.move(to: point) : path.line(to: point)
        }

        color.setStroke()
        path.lineWidth = lineWidth
        path.stroke()
    }
}

final class NetworkGraphView: NSView {
    var samples: [NetworkSample] = [] {
        didSet { needsDisplay = true }
    }
    var snapshot: NetworkSnapshot? {
        didSet { needsDisplay = true }
    }
    var rateUnit: RateUnit = .bytes {
        didSet { needsDisplay = true }
    }

    init() {
        super.init(frame: NSRect(x: 0, y: 0, width: 280, height: 120))
    }

    required init?(coder: NSCoder) {
        nil
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)

        let labelFont = NSFont.systemFont(ofSize: 11)
        let secondary: [NSAttributedString.Key: Any] = [
            .font: labelFont,
            .foregroundColor: NSColor.secondaryLabelColor
        ]
        let cyan: [NSAttributedString.Key: Any] = [.font: labelFont, .foregroundColor: NSColor.systemCyan]
        let red: [NSAttributedString.Key: Any] = [.font: labelFont, .foregroundColor: NSColor.systemRed]

        "Network · last 5 minutes".draw(at: NSPoint(x: 14, y: 100), withAttributes: secondary)
        if let snapshot,
           let received = snapshot.receivedBytesPerSecond,
           let sent = snapshot.sentBytesPerSecond {
            "↓ \(formatRate(received))".draw(at: NSPoint(x: 142, y: 100), withAttributes: cyan)
            "↑ \(formatRate(sent))".draw(at: NSPoint(x: 214, y: 100), withAttributes: red)
        }

        let receivedPeak = samples.map(\.received).max() ?? 0
        let sentPeak = samples.map(\.sent).max() ?? 0
        "5m peak".draw(at: NSPoint(x: 14, y: 83), withAttributes: secondary)
        "↓ \(formatRate(receivedPeak))".draw(at: NSPoint(x: 142, y: 83), withAttributes: cyan)
        "↑ \(formatRate(sentPeak))".draw(at: NSPoint(x: 214, y: 83), withAttributes: red)

        let chartBounds = NSRect(x: 14, y: 12, width: 252, height: 64)
        NSColor.separatorColor.withAlphaComponent(0.35).setStroke()
        let border = NSBezierPath(roundedRect: chartBounds, xRadius: 4, yRadius: 4)
        border.lineWidth = 0.5
        border.stroke()
        NetworkGraphRenderer.draw(samples: samples, in: chartBounds.insetBy(dx: 2, dy: 2), lineWidth: 1.25)
    }

    private func formatRate(_ bytesPerSecond: Double) -> String {
        let value = rateUnit == .bits ? bytesPerSecond * 8 : bytesPerSecond
        let suffix = rateUnit == .bits ? "b/s" : "B/s"
        let units: [(Double, String)] = [(1_000_000_000, "G"), (1_000_000, "M"), (1_000, "K")]
        for (divisor, prefix) in units where value >= divisor {
            return String(format: value / divisor >= 10 ? "%.0f %@%@" : "%.1f %@%@", value / divisor, prefix, suffix)
        }
        return String(format: "%.0f %@", value, suffix)
    }
}
