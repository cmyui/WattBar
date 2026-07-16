import AppKit
import IOKit.ps
import ServiceManagement

private func powerSourceChanged(_ context: UnsafeMutableRawPointer?) {
    guard let context else { return }
    let delegate = Unmanaged<AppDelegate>.fromOpaque(context).takeUnretainedValue()
    Task { @MainActor in
        delegate.handlePowerSourceChange()
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private static let networkHistoryLimit = 300

    private let powerSampler = PowerSampler()
    private let networkSampler = NetworkSampler()
    private let settings = AppSettings()
    private let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    private let menu = NSMenu()
    private let headlineItem = NSMenuItem()
    private let adapterItem = NSMenuItem()
    private let batteryItem = NSMenuItem()
    private let sourceItem = NSMenuItem()
    private let telemetryItem = NSMenuItem()
    private let networkItem = NSMenuItem()
    private let connectionTotalItem = NSMenuItem()
    private let dailyTotalItem = NSMenuItem()
    private let graphItem = NSMenuItem()
    private let graphView = NetworkGraphView()
    private let launchAtLoginItem = NSMenuItem(title: "Launch at Login", action: #selector(toggleLaunchAtLogin), keyEquivalent: "")
    private let showGraphItem = NSMenuItem(title: "Show Network Graph", action: #selector(toggleGraph), keyEquivalent: "")
    private let showTotalsItem = NSMenuItem(title: "Show Network Totals", action: #selector(toggleNetworkTotals), keyEquivalent: "")
    private let bitsItem = NSMenuItem(title: "Use Bits per Second", action: #selector(toggleRateUnit), keyEquivalent: "")
    private let colorPowerItem = NSMenuItem(title: "Color Battery Flow", action: #selector(togglePowerColor), keyEquivalent: "")
    private var graphWindowItems: [NSMenuItem] = []
    private var powerTimer: Timer?
    private var networkTimer: Timer?
    private var powerSourceNotification: CFRunLoopSource?
    private var transitionTimers: [Timer] = []
    private var lastSnapshot: PowerSnapshot?
    private var lastNetworkSnapshot: NetworkSnapshot?
    private var lastTelemetryTimestamp: Date?
    private var telemetryChangedOnLastRead = false
    private var lastProvidingPowerSource: String?
    private var networkHistory: [NetworkSample] = []

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        statusItem.button?.title = "-- W"
        statusItem.button?.toolTip = "WattBar"

        configureMenu()
        configurePowerSourceNotification()
        lastProvidingPowerSource = providingPowerSource()
        updateNetwork()
        updatePower()

        networkTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.updateNetwork() }
        }
        powerTimer = Timer.scheduledTimer(withTimeInterval: 5.0, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.updatePower() }
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        networkSampler.persist()
    }

    func menuWillOpen(_ menu: NSMenu) {
        updatePreferenceStates()
        updateTelemetryLine()
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
        let source = providingPowerSource()
        let sourceChanged = source != lastProvidingPowerSource
        lastProvidingPowerSource = source
        updatePower()
        if sourceChanged {
            scheduleTransitionSamples()
        }
    }

    private func providingPowerSource() -> String? {
        let blob = IOPSCopyPowerSourcesInfo().takeRetainedValue()
        guard let source = IOPSGetProvidingPowerSourceType(blob)?.takeUnretainedValue() else {
            return nil
        }
        return source as String
    }

    private func scheduleTransitionSamples() {
        transitionTimers.forEach { $0.invalidate() }
        transitionTimers = [1.0, 5.0, 15.0].map { delay in
            Timer.scheduledTimer(withTimeInterval: delay, repeats: false) { [weak self] _ in
                Task { @MainActor in self?.updatePower() }
            }
        }
    }

    private func configureMenu() {
        for item in [headlineItem, adapterItem, batteryItem, sourceItem, telemetryItem, networkItem, connectionTotalItem, dailyTotalItem] {
            item.isEnabled = false
            menu.addItem(item)
        }

        graphItem.view = graphView
        menu.addItem(graphItem)
        menu.addItem(.separator())

        let preferencesItem = NSMenuItem(title: "Preferences", action: nil, keyEquivalent: "")
        preferencesItem.submenu = preferencesMenu()
        menu.addItem(preferencesItem)
        menu.addItem(NSMenuItem(title: "Refresh Now", action: #selector(refreshNow), keyEquivalent: "r"))
        menu.addItem(NSMenuItem(title: "Copy Snapshot", action: #selector(copySnapshot), keyEquivalent: "c"))
        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: "Quit WattBar", action: #selector(quit), keyEquivalent: "q"))

        menu.items.forEach { $0.target = self }
        updatePreferenceStates()
        menu.delegate = self
        statusItem.menu = menu
    }

    private func preferencesMenu() -> NSMenu {
        let preferences = NSMenu()
        for item in [launchAtLoginItem, showGraphItem, showTotalsItem, bitsItem, colorPowerItem] {
            item.target = self
            preferences.addItem(item)
        }
        preferences.addItem(.separator())

        let windowItem = NSMenuItem(title: "Menu Bar Graph Window", action: nil, keyEquivalent: "")
        let windowMenu = NSMenu()
        graphWindowItems = [30, 45, 60].map { seconds in
            let item = NSMenuItem(title: "\(seconds) seconds", action: #selector(setGraphWindow(_:)), keyEquivalent: "")
            item.tag = seconds
            item.target = self
            windowMenu.addItem(item)
            return item
        }
        windowItem.submenu = windowMenu
        preferences.addItem(windowItem)
        return preferences
    }

    private func updateNetwork() {
        let snapshot = networkSampler.sample()
        lastNetworkSnapshot = snapshot
        updateNetworkMenu(snapshot)

        if let received = snapshot?.receivedBytesPerSecond,
           let sent = snapshot?.sentBytesPerSecond {
            networkHistory.append(NetworkSample(received: received, sent: sent))
            if networkHistory.count > Self.networkHistoryLimit {
                networkHistory.removeFirst(networkHistory.count - Self.networkHistoryLimit)
            }
        }

        graphView.samples = networkHistory
        graphView.snapshot = snapshot
        graphView.rateUnit = settings.rateUnit
        updateGraphVisibility()
        updateTelemetryLine()
        updateStatusTitle()
    }

    private func updatePower() {
        guard let snapshot = powerSampler.sample() else {
            lastSnapshot = nil
            headlineItem.title = "Battery net: unavailable"
            adapterItem.title = "Adapter: unavailable"
            batteryItem.title = "Battery: unavailable"
            sourceItem.title = "Source: unavailable"
            telemetryItem.title = "Telemetry: unavailable"
            statusItem.button?.toolTip = "WattBar could not read battery telemetry."
            updateStatusTitle()
            return
        }

        telemetryChangedOnLastRead = snapshot.telemetryTimestamp != lastTelemetryTimestamp
        lastTelemetryTimestamp = snapshot.telemetryTimestamp
        lastSnapshot = snapshot

        headlineItem.title = snapshot.batteryNetWatts.map { "Battery net: \(signedFormat($0)) W" }
            ?? "Battery net: unavailable"
        updateAdapterLine(snapshot)
        batteryItem.title = batteryLine(snapshot)
        sourceItem.title = sourceLine(snapshot)
        updateTelemetryLine()
        statusItem.button?.toolTip = tooltip(snapshot)
        updateStatusTitle()
    }

    private func updateAdapterLine(_ snapshot: PowerSnapshot) {
        if let input = snapshot.adapterInputWatts, let maximum = snapshot.adapterAdvertisedWatts {
            adapterItem.title = "Adapter: \(format(input)) W in / \(format(maximum)) W max"
        } else if let maximum = snapshot.adapterAdvertisedWatts {
            adapterItem.title = "Adapter: \(format(maximum)) W max"
        } else {
            adapterItem.title = "Adapter: unavailable"
        }
    }

    private func updateTelemetryLine() {
        guard let snapshot = lastSnapshot else { return }
        if let age = snapshot.telemetryAge {
            let state = telemetryChangedOnLastRead ? "new sample" : "unchanged"
            telemetryItem.title = "Telemetry: \(state) · \(duration(age)) old"
        } else {
            telemetryItem.title = "Telemetry age: unavailable"
        }
    }

    private func updateNetworkMenu(_ snapshot: NetworkSnapshot?) {
        guard let snapshot else {
            networkItem.title = "Network: unavailable"
            connectionTotalItem.title = "Connection total: unavailable"
            dailyTotalItem.title = "Today: unavailable"
            return
        }

        let pathFlags = [snapshot.isExpensive ? "expensive / hotspot" : nil, snapshot.isConstrained ? "Low Data Mode" : nil]
            .compactMap { $0 }
        let pathDescription = pathFlags.isEmpty ? "" : " · \(pathFlags.joined(separator: ", "))"
        if let received = snapshot.receivedBytesPerSecond, let sent = snapshot.sentBytesPerSecond {
            networkItem.title = "Network (\(snapshot.interfaceName)\(pathDescription)): ↓ \(rate(received))  ↑ \(rate(sent))"
        } else {
            networkItem.title = "Network (\(snapshot.interfaceName)\(pathDescription)): measuring…"
        }
        connectionTotalItem.title = "Connection: ↓ \(byteCount(snapshot.receivedBytesForConnection))  ↑ \(byteCount(snapshot.sentBytesForConnection))"
        dailyTotalItem.title = "Today: ↓ \(byteCount(snapshot.receivedBytesToday))  ↑ \(byteCount(snapshot.sentBytesToday))"
        connectionTotalItem.isHidden = !settings.showNetworkTotals
        dailyTotalItem.isHidden = !settings.showNetworkTotals
    }

    private func updateGraphVisibility() {
        graphItem.isHidden = !settings.showGraph
        statusItem.button?.image = settings.showGraph
            ? NetworkGraphRenderer.statusImage(samples: networkHistory, window: settings.graphWindow)
            : nil
        statusItem.button?.imagePosition = .imageTrailing
    }

    private func updateStatusTitle() {
        let font = NSFont.monospacedDigitSystemFont(ofSize: NSFont.systemFontSize, weight: .regular)
        let title = NSMutableAttributedString()

        if let watts = lastSnapshot?.batteryNetWatts {
            let staleAlpha = (lastSnapshot?.telemetryAge ?? 0) > 10 ? 0.58 : 1
            let directionalColor: NSColor = watts > 0.1 ? .systemGreen : watts < -0.1 ? .systemOrange : .labelColor
            let color = (settings.colorPower ? directionalColor : NSColor.labelColor).withAlphaComponent(staleAlpha)
            title.append(NSAttributedString(string: String(format: "%+6.1fW", watts), attributes: [.font: font, .foregroundColor: color]))
        } else {
            title.append(NSAttributedString(string: "  -- W", attributes: [.font: font, .foregroundColor: NSColor.secondaryLabelColor]))
        }

        if let received = lastNetworkSnapshot?.receivedBytesPerSecond,
           let sent = lastNetworkSnapshot?.sentBytesPerSecond {
            title.append(NSAttributedString(string: "   ", attributes: [.font: font]))
            title.append(NSAttributedString(string: "↓\(compactRate(received))", attributes: [.font: font, .foregroundColor: NSColor.systemCyan]))
            title.append(NSAttributedString(string: "  ", attributes: [.font: font]))
            title.append(NSAttributedString(string: "↑\(compactRate(sent))", attributes: [.font: font, .foregroundColor: NSColor.systemRed]))
        }
        statusItem.button?.attributedTitle = title
    }

    private func updatePreferenceStates() {
        switch SMAppService.mainApp.status {
        case .enabled:
            launchAtLoginItem.title = "Launch at Login"
            launchAtLoginItem.state = .on
        case .requiresApproval:
            launchAtLoginItem.title = "Launch at Login (Approval Required)"
            launchAtLoginItem.state = .mixed
        default:
            launchAtLoginItem.title = "Launch at Login"
            launchAtLoginItem.state = .off
        }
        showGraphItem.state = settings.showGraph ? .on : .off
        showTotalsItem.state = settings.showNetworkTotals ? .on : .off
        bitsItem.state = settings.rateUnit == .bits ? .on : .off
        colorPowerItem.state = settings.colorPower ? .on : .off
        graphWindowItems.forEach { $0.state = $0.tag == settings.graphWindow ? .on : .off }
    }

    private func batteryLine(_ snapshot: PowerSnapshot) -> String {
        let percent = snapshot.batteryPercent.map { "\($0)%" } ?? "unknown"
        guard let batteryNetWatts = snapshot.batteryNetWatts else {
            return snapshot.systemLoadWatts.map { "System: \(format($0)) W" } ?? "Battery: \(percent)"
        }
        let direction = batteryNetWatts > 0.1 ? "charging" : batteryNetWatts < -0.1 ? "draining" : "neutral"
        if let systemLoadWatts = snapshot.systemLoadWatts {
            return "Battery: \(percent), \(direction); system \(format(systemLoadWatts)) W"
        }
        return "Battery: \(percent), \(direction)"
    }

    private func sourceLine(_ snapshot: PowerSnapshot) -> String {
        snapshot.externalConnected ? (snapshot.isCharging ? "Source: AC, charging" : "Source: AC") : "Source: battery"
    }

    private func tooltip(_ snapshot: PowerSnapshot) -> String {
        [
            snapshot.batteryNetWatts.map { "Battery net \(signedFormat($0)) W" },
            snapshot.telemetryAge.map { "Telemetry \(duration($0)) old" },
            snapshot.systemLoadWatts.map { "System \(format($0)) W" },
            snapshot.adapterInputWatts.map { "Adapter in \(format($0)) W" },
            snapshot.adapterAdvertisedWatts.map { "Adapter max \(format($0)) W" },
            snapshot.batteryPercent.map { "Charge \($0)%" }
        ].compactMap { $0 }.joined(separator: "\n")
    }

    private func format(_ value: Double) -> String { String(format: "%.1f", value) }
    private func signedFormat(_ value: Double) -> String { String(format: "%+.1f", value) }

    private func duration(_ seconds: TimeInterval) -> String {
        if seconds < 60 { return "\(Int(seconds))s" }
        return "\(Int(seconds / 60))m \(Int(seconds) % 60)s"
    }

    private func rate(_ bytesPerSecond: Double) -> String {
        let value = settings.rateUnit == .bits ? bytesPerSecond * 8 : bytesPerSecond
        let suffix = settings.rateUnit == .bits ? "b/s" : "B/s"
        return scaled(value, suffix: suffix, padded: false)
    }

    private func compactRate(_ bytesPerSecond: Double) -> String {
        let value = settings.rateUnit == .bits ? bytesPerSecond * 8 : bytesPerSecond
        let suffix = settings.rateUnit == .bits ? "b" : ""
        return scaled(value, suffix: suffix, padded: true)
    }

    private func scaled(_ value: Double, suffix: String, padded: Bool) -> String {
        let units: [(Double, String)] = [(1_000_000_000_000, "T"), (1_000_000_000, "G"), (1_000_000, "M"), (1_000, "K")]
        var formatted = ""
        for (divisor, prefix) in units where value >= divisor {
            let scaled = value / divisor
            formatted = String(format: scaled >= 10 ? "%.0f%@%@" : "%.1f%@%@", scaled, prefix, suffix)
            break
        }
        if formatted.isEmpty { formatted = String(format: "%.0f%@", value, suffix.isEmpty ? "B" : suffix) }
        return padded ? String(repeating: " ", count: max(5 - formatted.count, 0)) + formatted : formatted
    }

    private func byteCount(_ bytes: UInt64) -> String {
        ByteCountFormatter.string(fromByteCount: Int64(clamping: bytes), countStyle: .file)
    }

    @objc private func toggleLaunchAtLogin() {
        do {
            if SMAppService.mainApp.status == .enabled {
                try SMAppService.mainApp.unregister()
            } else {
                try SMAppService.mainApp.register()
            }
        } catch {
            launchAtLoginItem.toolTip = error.localizedDescription
            NSSound.beep()
        }
        updatePreferenceStates()
    }

    @objc private func toggleGraph() {
        settings.showGraph.toggle()
        updatePreferenceStates()
        updateGraphVisibility()
    }

    @objc private func toggleNetworkTotals() {
        settings.showNetworkTotals.toggle()
        updatePreferenceStates()
        updateNetworkMenu(lastNetworkSnapshot)
    }

    @objc private func toggleRateUnit() {
        settings.rateUnit = settings.rateUnit == .bytes ? .bits : .bytes
        updatePreferenceStates()
        updateNetworkMenu(lastNetworkSnapshot)
        graphView.rateUnit = settings.rateUnit
        updateStatusTitle()
    }

    @objc private func togglePowerColor() {
        settings.colorPower.toggle()
        updatePreferenceStates()
        updateStatusTitle()
    }

    @objc private func setGraphWindow(_ sender: NSMenuItem) {
        settings.graphWindow = sender.tag
        updatePreferenceStates()
        updateGraphVisibility()
    }

    @objc private func refreshNow() {
        updateNetwork()
        updatePower()
    }

    @objc private func copySnapshot() {
        let text = [headlineItem, adapterItem, batteryItem, sourceItem, telemetryItem, networkItem, connectionTotalItem, dailyTotalItem]
            .map(\.title)
            .joined(separator: "\n")
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }

    @objc private func quit() {
        NSApp.terminate(nil)
    }
}
