import Foundation

struct PowerSnapshot {
    let batteryPercent: Int?
    let externalConnected: Bool
    let isCharging: Bool
    let adapterAdvertisedWatts: Double?
    let adapterInputWatts: Double?
    let systemLoadWatts: Double?
    let batteryNetWatts: Double?
    let telemetryTimestamp: Date?
    let readTimestamp: Date

    var headlineWatts: Double? {
        batteryNetWatts ?? systemLoadWatts.map(-) ?? adapterInputWatts
    }

    var telemetryAge: TimeInterval? {
        telemetryTimestamp.map { max(0, Date().timeIntervalSince($0)) }
    }
}

struct NetworkSnapshot {
    let interfaceName: String
    let receivedBytesPerSecond: Double?
    let sentBytesPerSecond: Double?
    let receivedBytesForConnection: UInt64
    let sentBytesForConnection: UInt64
    let receivedBytesToday: UInt64
    let sentBytesToday: UInt64
    let isExpensive: Bool
    let isConstrained: Bool
}

struct NetworkSample {
    let received: Double
    let sent: Double
}

enum RateUnit: Int {
    case bytes
    case bits
}

final class AppSettings {
    private enum Key {
        static let showGraph = "showGraph"
        static let showNetworkTotals = "showNetworkTotals"
        static let colorPower = "colorPower"
        static let rateUnit = "rateUnit"
        static let graphWindow = "graphWindow"
    }

    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        defaults.register(defaults: [
            Key.showGraph: true,
            Key.showNetworkTotals: true,
            Key.colorPower: true,
            Key.rateUnit: RateUnit.bytes.rawValue,
            Key.graphWindow: 45
        ])
    }

    var showGraph: Bool {
        get { defaults.bool(forKey: Key.showGraph) }
        set { defaults.set(newValue, forKey: Key.showGraph) }
    }

    var showNetworkTotals: Bool {
        get { defaults.bool(forKey: Key.showNetworkTotals) }
        set { defaults.set(newValue, forKey: Key.showNetworkTotals) }
    }

    var colorPower: Bool {
        get { defaults.bool(forKey: Key.colorPower) }
        set { defaults.set(newValue, forKey: Key.colorPower) }
    }

    var rateUnit: RateUnit {
        get { RateUnit(rawValue: defaults.integer(forKey: Key.rateUnit)) ?? .bytes }
        set { defaults.set(newValue.rawValue, forKey: Key.rateUnit) }
    }

    var graphWindow: Int {
        get {
            let value = defaults.integer(forKey: Key.graphWindow)
            return [30, 45, 60].contains(value) ? value : 45
        }
        set { defaults.set(newValue, forKey: Key.graphWindow) }
    }
}
