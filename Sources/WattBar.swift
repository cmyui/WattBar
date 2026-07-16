import AppKit
import Darwin
import Foundation
import IOKit
import IOKit.ps
import SystemConfiguration

struct PowerSnapshot {
    let batteryPercent: Int?
    let externalConnected: Bool
    let isCharging: Bool
    let adapterAdvertisedWatts: Double?
    let adapterInputWatts: Double?
    let systemLoadWatts: Double?
    let batteryNetWatts: Double?
    let timestamp: Date

    var headlineWatts: Double? {
        if let batteryNetWatts {
            return batteryNetWatts
        }

        if let systemLoadWatts {
            return -systemLoadWatts
        }

        return adapterInputWatts
    }
}

struct NetworkSnapshot {
    let interfaceName: String
    let receivedBytesPerSecond: Double?
    let sentBytesPerSecond: Double?
    let receivedBytesSinceLaunch: UInt64
    let sentBytesSinceLaunch: UInt64
}

final class NetworkSampler {
    private var previous: (interfaceName: String, receivedBytes: UInt64, sentBytes: UInt64, timestamp: Date)?
    private var receivedBytesSinceLaunch: UInt64 = 0
    private var sentBytesSinceLaunch: UInt64 = 0

    func sample() -> NetworkSnapshot? {
        guard let interfaceName = primaryInterfaceName(),
              let counters = counters(for: interfaceName) else {
            previous = nil
            return nil
        }

        let now = Date()
        var receivedBytesPerSecond: Double?
        var sentBytesPerSecond: Double?

        if let previous,
           previous.interfaceName == interfaceName,
           counters.receivedBytes >= previous.receivedBytes,
           counters.sentBytes >= previous.sentBytes {
            let elapsed = now.timeIntervalSince(previous.timestamp)
            if elapsed > 0 {
                let receivedDelta = counters.receivedBytes - previous.receivedBytes
                let sentDelta = counters.sentBytes - previous.sentBytes
                receivedBytesPerSecond = Double(receivedDelta) / elapsed
                sentBytesPerSecond = Double(sentDelta) / elapsed
                receivedBytesSinceLaunch += receivedDelta
                sentBytesSinceLaunch += sentDelta
            }
        }

        previous = (interfaceName, counters.receivedBytes, counters.sentBytes, now)

        return NetworkSnapshot(
            interfaceName: interfaceName,
            receivedBytesPerSecond: receivedBytesPerSecond,
            sentBytesPerSecond: sentBytesPerSecond,
            receivedBytesSinceLaunch: receivedBytesSinceLaunch,
            sentBytesSinceLaunch: sentBytesSinceLaunch
        )
    }

    private func primaryInterfaceName() -> String? {
        for key in ["State:/Network/Global/IPv4", "State:/Network/Global/IPv6"] {
            if let value = SCDynamicStoreCopyValue(nil, key as CFString),
               let dictionary = value as? [String: Any],
               let interfaceName = dictionary["PrimaryInterface"] as? String {
                return interfaceName
            }
        }

        return nil
    }

    private func counters(for interfaceName: String) -> (receivedBytes: UInt64, sentBytes: UInt64)? {
        var interfaces: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&interfaces) == 0, let firstInterface = interfaces else {
            return nil
        }
        defer { freeifaddrs(interfaces) }

        var interface: UnsafeMutablePointer<ifaddrs>? = firstInterface
        while let current = interface {
            let value = current.pointee
            if String(cString: value.ifa_name) == interfaceName,
               value.ifa_addr?.pointee.sa_family == UInt8(AF_LINK),
               let data = value.ifa_data?.assumingMemoryBound(to: if_data.self) {
                return (UInt64(data.pointee.ifi_ibytes), UInt64(data.pointee.ifi_obytes))
            }
            interface = value.ifa_next
        }

        return nil
    }
}

final class PowerSampler {
    func sample() -> PowerSnapshot? {
        let service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("AppleSmartBattery"))
        guard service != 0 else {
            return nil
        }
        defer { IOObjectRelease(service) }

        var unmanagedProperties: Unmanaged<CFMutableDictionary>?
        let result = IORegistryEntryCreateCFProperties(service, &unmanagedProperties, kCFAllocatorDefault, 0)
        guard result == KERN_SUCCESS, let unmanagedProperties else {
            return nil
        }

        let properties = unmanagedProperties.takeRetainedValue() as NSDictionary
        let adapterDetails = properties["AdapterDetails"] as? NSDictionary
        let telemetry = properties["PowerTelemetryData"] as? NSDictionary

        let batteryPercent = int(properties["CurrentCapacity"])
        let externalConnected = bool(properties["ExternalConnected"])
        let isCharging = bool(properties["IsCharging"])
        let adapterAdvertisedWatts = watts(adapterDetails?["Watts"])
        let adapterInputWatts = positiveMilliwatts(telemetry?["SystemPowerIn"])
        let currentBatteryNetWatts = batteryNetFromVoltageAndCurrent(properties)
        let telemetryBatteryNetWatts = normalizedBatteryPower(
            signedMilliwatts(telemetry?["BatteryPower"]),
            externalConnected: externalConnected
        )
        let batteryNetWatts = currentBatteryNetWatts ?? telemetryBatteryNetWatts
        let systemLoadWatts = positiveMilliwatts(telemetry?["SystemLoad"])
            ?? batteryNetWatts.map(abs)

        return PowerSnapshot(
            batteryPercent: batteryPercent,
            externalConnected: externalConnected,
            isCharging: isCharging,
            adapterAdvertisedWatts: adapterAdvertisedWatts,
            adapterInputWatts: adapterInputWatts,
            systemLoadWatts: systemLoadWatts,
            batteryNetWatts: batteryNetWatts,
            timestamp: Date()
        )
    }

    private func batteryNetFromVoltageAndCurrent(_ properties: NSDictionary) -> Double? {
        guard let voltageMillivolts = double(properties["Voltage"] ?? properties["AppleRawBatteryVoltage"]),
              let amperageMilliamps = signedDouble(properties["Amperage"]) else {
            return nil
        }

        return voltageMillivolts * amperageMilliamps / 1_000_000.0
    }

    private func watts(_ value: Any?) -> Double? {
        double(value)
    }

    private func positiveMilliwatts(_ value: Any?) -> Double? {
        guard let value = double(value) else {
            return nil
        }

        guard value >= 0, value < 1_000_000 else {
            return nil
        }

        return value / 1_000.0
    }

    private func signedMilliwatts(_ value: Any?) -> Double? {
        guard let value = signedDouble(value) else {
            return nil
        }

        return value / 1_000.0
    }

    private func normalizedBatteryPower(_ value: Double?, externalConnected: Bool) -> Double? {
        guard let value else {
            return nil
        }

        if externalConnected {
            return value
        }

        return -abs(value)
    }

    private func int(_ value: Any?) -> Int? {
        guard let number = value as? NSNumber else {
            return nil
        }

        return number.intValue
    }

    private func bool(_ value: Any?) -> Bool {
        guard let number = value as? NSNumber else {
            return false
        }

        return number.boolValue
    }

    private func double(_ value: Any?) -> Double? {
        guard let number = value as? NSNumber else {
            return nil
        }

        return number.doubleValue
    }

    private func signedDouble(_ value: Any?) -> Double? {
        guard let number = value as? NSNumber else {
            return nil
        }

        let unsigned = number.uint64Value
        let signed = Int64(bitPattern: unsigned)
        return Double(signed)
    }
}

private func powerSourceChanged(_ context: UnsafeMutableRawPointer?) {
    guard let context else {
        return
    }

    let delegate = Unmanaged<AppDelegate>.fromOpaque(context).takeUnretainedValue()
    Task { @MainActor in
        delegate.handlePowerSourceChange()
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private static let networkHistoryLimit = 45

    private let sampler = PowerSampler()
    private let networkSampler = NetworkSampler()
    private let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    private let menu = NSMenu()
    private let headlineItem = NSMenuItem()
    private let adapterItem = NSMenuItem()
    private let batteryItem = NSMenuItem()
    private let sourceItem = NSMenuItem()
    private let networkItem = NSMenuItem()
    private let networkTotalItem = NSMenuItem()
    private let updatedItem = NSMenuItem()
    private var powerTimer: Timer?
    private var networkTimer: Timer?
    private var powerSourceNotification: CFRunLoopSource?
    private var lastSnapshot: PowerSnapshot?
    private var lastNetworkSnapshot: NetworkSnapshot?
    private var networkHistory: [(received: Double, sent: Double)] = []

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)

        statusItem.button?.title = "-- W"
        statusItem.button?.toolTip = "WattBar"

        configureMenu()
        configurePowerSourceNotification()
        updateNetwork()
        updatePower()

        networkTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.updateNetwork()
            }
        }

        powerTimer = Timer.scheduledTimer(withTimeInterval: 5.0, repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.updatePower()
            }
        }
    }

    private func configurePowerSourceNotification() {
        let context = Unmanaged.passUnretained(self).toOpaque()
        guard let source = IOPSNotificationCreateRunLoopSource(powerSourceChanged, context)?.takeRetainedValue() else {
            return
        }

        powerSourceNotification = source
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
    }

    fileprivate func handlePowerSourceChange() {
        updatePower()
    }

    private func configureMenu() {
        for item in [headlineItem, adapterItem, batteryItem, sourceItem, networkItem, networkTotalItem, updatedItem] {
            item.isEnabled = false
            menu.addItem(item)
        }

        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: "Refresh Now", action: #selector(refreshNow), keyEquivalent: "r"))
        menu.addItem(NSMenuItem(title: "Copy Snapshot", action: #selector(copySnapshot), keyEquivalent: "c"))
        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: "Quit WattBar", action: #selector(quit), keyEquivalent: "q"))
        menu.items.forEach { $0.target = self }

        statusItem.menu = menu
    }

    private func updateNetwork() {
        let networkSnapshot = networkSampler.sample()
        lastNetworkSnapshot = networkSnapshot
        updateNetworkMenu(networkSnapshot)

        if let received = networkSnapshot?.receivedBytesPerSecond,
           let sent = networkSnapshot?.sentBytesPerSecond {
            networkHistory.append((received, sent))
            if networkHistory.count > Self.networkHistoryLimit {
                networkHistory.removeFirst(networkHistory.count - Self.networkHistoryLimit)
            }
        }

        statusItem.button?.image = networkGraph()
        statusItem.button?.imagePosition = .imageTrailing
        updateStatusTitle()
    }

    private func updatePower() {
        guard let snapshot = sampler.sample() else {
            statusItem.button?.title = "-- W"
            statusItem.button?.toolTip = "WattBar could not read battery telemetry."
            headlineItem.title = "Power: unavailable"
            adapterItem.title = "Adapter: unavailable"
            batteryItem.title = "Battery: unavailable"
            sourceItem.title = "Source: unavailable"
            updatedItem.title = "Updated: \(timeString(Date()))"
            return
        }

        lastSnapshot = snapshot

        if let watts = snapshot.headlineWatts {
            updateStatusTitle()
            headlineItem.title = "Battery net: \(signedFormat(watts)) W"
        } else {
            statusItem.button?.title = "-- W"
            headlineItem.title = "Battery net: unavailable"
        }

        if let adapterInputWatts = snapshot.adapterInputWatts,
           let adapterAdvertisedWatts = snapshot.adapterAdvertisedWatts {
            adapterItem.title = "Adapter: \(format(adapterInputWatts)) W in / \(format(adapterAdvertisedWatts)) W max"
        } else if let adapterAdvertisedWatts = snapshot.adapterAdvertisedWatts {
            adapterItem.title = "Adapter: \(format(adapterAdvertisedWatts)) W max"
        } else {
            adapterItem.title = "Adapter: unavailable"
        }

        batteryItem.title = batteryLine(snapshot)
        sourceItem.title = sourceLine(snapshot)
        updatedItem.title = "Updated: \(timeString(snapshot.timestamp))"
        statusItem.button?.toolTip = tooltip(snapshot)
    }

    private func updateNetworkMenu(_ snapshot: NetworkSnapshot?) {
        guard let snapshot else {
            networkItem.title = "Network: unavailable"
            networkTotalItem.title = "Since launch: unavailable"
            return
        }

        if let received = snapshot.receivedBytesPerSecond,
           let sent = snapshot.sentBytesPerSecond {
            networkItem.title = "Network (\(snapshot.interfaceName)): ↓ \(byteRate(received))  ↑ \(byteRate(sent))"
        } else {
            networkItem.title = "Network (\(snapshot.interfaceName)): measuring…"
        }

        networkTotalItem.title = "Since launch: ↓ \(byteCount(snapshot.receivedBytesSinceLaunch))  ↑ \(byteCount(snapshot.sentBytesSinceLaunch))"
    }

    private func updateStatusTitle() {
        let font = NSFont.monospacedDigitSystemFont(ofSize: NSFont.systemFontSize, weight: .regular)
        let title = NSMutableAttributedString()

        if let watts = lastSnapshot?.headlineWatts {
            let color: NSColor = watts > 0.1 ? .systemGreen : watts < -0.1 ? .systemOrange : .labelColor
            title.append(NSAttributedString(
                string: String(format: "%+6.1fW", watts),
                attributes: [.font: font, .foregroundColor: color]
            ))
        } else {
            title.append(NSAttributedString(
                string: "  -- W",
                attributes: [.font: font, .foregroundColor: NSColor.secondaryLabelColor]
            ))
        }

        guard let received = lastNetworkSnapshot?.receivedBytesPerSecond,
              let sent = lastNetworkSnapshot?.sentBytesPerSecond else {
            statusItem.button?.attributedTitle = title
            return
        }

        title.append(NSAttributedString(string: "   ", attributes: [.font: font]))
        title.append(NSAttributedString(
            string: "↓\(compactByteRate(received))",
            attributes: [.font: font, .foregroundColor: NSColor.systemCyan]
        ))
        title.append(NSAttributedString(string: "  ", attributes: [.font: font]))
        title.append(NSAttributedString(
            string: "↑\(compactByteRate(sent))",
            attributes: [.font: font, .foregroundColor: NSColor.systemRed]
        ))
        statusItem.button?.attributedTitle = title
    }

    private func batteryLine(_ snapshot: PowerSnapshot) -> String {
        let percent = snapshot.batteryPercent.map { "\($0)%" } ?? "unknown"
        guard let batteryNetWatts = snapshot.batteryNetWatts else {
            if let systemLoadWatts = snapshot.systemLoadWatts {
                return "System: \(format(systemLoadWatts)) W"
            }

            return "Battery: \(percent)"
        }

        let direction: String
        if batteryNetWatts > 0.1 {
            direction = "charging"
        } else if batteryNetWatts < -0.1 {
            direction = "draining"
        } else {
            direction = "neutral"
        }

        if let systemLoadWatts = snapshot.systemLoadWatts {
            return "Battery: \(percent), \(direction); system \(format(systemLoadWatts)) W"
        }

        return "Battery: \(percent), \(direction)"
    }

    private func sourceLine(_ snapshot: PowerSnapshot) -> String {
        if snapshot.externalConnected {
            return snapshot.isCharging ? "Source: AC, charging" : "Source: AC"
        }

        return "Source: battery"
    }

    private func tooltip(_ snapshot: PowerSnapshot) -> String {
        [
            snapshot.batteryNetWatts.map { "Battery net \(signedFormat($0)) W" },
            snapshot.systemLoadWatts.map { "System \(format($0)) W" },
            snapshot.adapterInputWatts.map { "Adapter in \(format($0)) W" },
            snapshot.adapterAdvertisedWatts.map { "Adapter max \(format($0)) W" },
            snapshot.batteryPercent.map { "Charge \($0)%" }
        ]
        .compactMap { $0 }
        .joined(separator: "\n")
    }

    private func format(_ value: Double) -> String {
        String(format: "%.1f", value)
    }

    private func signedFormat(_ value: Double) -> String {
        String(format: "%+.1f", value)
    }

    private func byteRate(_ bytesPerSecond: Double) -> String {
        ByteCountFormatter.string(fromByteCount: Int64(bytesPerSecond), countStyle: .file) + "/s"
    }

    private func compactByteRate(_ bytesPerSecond: Double) -> String {
        let units: [(threshold: Double, divisor: Double, suffix: String)] = [
            (1_000_000_000_000, 1_000_000_000_000, "T"),
            (1_000_000_000, 1_000_000_000, "G"),
            (1_000_000, 1_000_000, "M"),
            (1_000, 1_000, "K")
        ]

        for unit in units where bytesPerSecond >= unit.threshold {
            let value = bytesPerSecond / unit.divisor
            let formatted = String(format: value >= 10 ? "%.0f%@" : "%.1f%@", value, unit.suffix)
            return String(repeating: " ", count: max(5 - formatted.count, 0)) + formatted
        }

        let formatted = String(format: "%.0fB", bytesPerSecond)
        return String(repeating: " ", count: max(5 - formatted.count, 0)) + formatted
    }

    private func byteCount(_ bytes: UInt64) -> String {
        ByteCountFormatter.string(fromByteCount: Int64(clamping: bytes), countStyle: .file)
    }

    private func networkGraph() -> NSImage? {
        guard !networkHistory.isEmpty else {
            return nil
        }

        let chartWidth: CGFloat = 42
        let leadingPadding: CGFloat = 8
        let size = NSSize(width: leadingPadding + chartWidth, height: 16)
        let historyLimit = Self.networkHistoryLimit
        return NSImage(size: size, flipped: false) { [networkHistory, historyLimit] bounds in
            let bounds = NSRect(x: bounds.minX + leadingPadding, y: bounds.minY, width: chartWidth, height: bounds.height)
            let centerY = bounds.midY
            let maximum = max(networkHistory.flatMap { [$0.received, $0.sent] }.max() ?? 1, 1)

            NSColor.separatorColor.withAlphaComponent(0.7).setStroke()
            let baseline = NSBezierPath()
            baseline.move(to: NSPoint(x: bounds.minX, y: centerY))
            baseline.line(to: NSPoint(x: bounds.maxX, y: centerY))
            baseline.lineWidth = 0.5
            baseline.stroke()

            func draw(_ values: [Double], color: NSColor, direction: Double) {
                let path = NSBezierPath()
                let step = bounds.width / CGFloat(max(historyLimit - 1, 1))
                let startX = bounds.maxX - CGFloat(values.count - 1) * step

                for (index, value) in values.enumerated() {
                    let x = startX + CGFloat(index) * step
                    let height = CGFloat(value / maximum) * (bounds.height / 2 - 1)
                    let point = NSPoint(x: x, y: centerY + direction * height)
                    index == 0 ? path.move(to: point) : path.line(to: point)
                }

                color.setStroke()
                path.lineWidth = 1
                path.stroke()
            }

            draw(networkHistory.map(\.received), color: .systemCyan, direction: 1)
            draw(networkHistory.map(\.sent), color: .systemRed, direction: -1)
            return true
        }
    }

    private func timeString(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.timeStyle = .medium
        formatter.dateStyle = .none
        return formatter.string(from: date)
    }

    @objc private func refreshNow() {
        updateNetwork()
        updatePower()
    }

    @objc private func copySnapshot() {
        guard let lastSnapshot else {
            return
        }

        let text = [
            headlineItem.title,
            adapterItem.title,
            batteryItem.title,
            sourceItem.title,
            networkItem.title,
            networkTotalItem.title,
            "Updated: \(lastSnapshot.timestamp)"
        ].joined(separator: "\n")

        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }

    @objc private func quit() {
        NSApp.terminate(nil)
    }
}

@main
struct WattBar {
    @MainActor
    static func main() {
        let app = NSApplication.shared
        let delegate = AppDelegate()
        app.delegate = delegate
        app.run()
    }
}
