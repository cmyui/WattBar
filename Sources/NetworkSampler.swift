import Darwin
import Foundation
import Network
import SystemConfiguration

final class NetworkSampler {
    private enum PersistenceKey {
        static let day = "networkTotalsDay"
        static let received = "networkReceivedToday"
        static let sent = "networkSentToday"
    }

    // A longer gap (such as display sleep) still counts toward totals, but its average is not a current rate.
    private static let maximumRateInterval: TimeInterval = 5

    private static let dayFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.calendar = .autoupdatingCurrent
        formatter.timeZone = .autoupdatingCurrent
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter
    }()

    private let defaults: UserDefaults
    private let pathMonitor = NWPathMonitor()
    private let pathQueue = DispatchQueue(label: "com.cmyui.WattBar.network-path")
    private let pathLock = NSLock()
    private var pathState = (isExpensive: false, isConstrained: false, generation: UInt64(0), updates: UInt64(0))
    private var primaryInterface: (name: String, pathUpdates: UInt64)?
    private var previous: (interfaceName: String, generation: UInt64, receivedBytes: UInt64, sentBytes: UInt64, timestamp: Date)?
    private var receivedBytesForConnection: UInt64 = 0
    private var sentBytesForConnection: UInt64 = 0
    private var receivedBytesToday: UInt64
    private var sentBytesToday: UInt64
    private var totalsDay: String
    private var lastPersistence = Date.distantPast

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        totalsDay = defaults.string(forKey: PersistenceKey.day) ?? Self.dayKey(Date())
        receivedBytesToday = UInt64(max((defaults.object(forKey: PersistenceKey.received) as? NSNumber)?.int64Value ?? 0, 0))
        sentBytesToday = UInt64(max((defaults.object(forKey: PersistenceKey.sent) as? NSNumber)?.int64Value ?? 0, 0))
        rollDayIfNeeded()

        pathMonitor.pathUpdateHandler = { [weak self] path in
            guard let self else { return }
            pathLock.lock()
            if pathState.isExpensive != path.isExpensive || pathState.isConstrained != path.isConstrained {
                pathState.generation += 1
            }
            pathState.isExpensive = path.isExpensive
            pathState.isConstrained = path.isConstrained
            pathState.updates += 1
            pathLock.unlock()
        }
        pathMonitor.start(queue: pathQueue)
    }

    deinit {
        pathMonitor.cancel()
    }

    func sample() -> NetworkSnapshot? {
        rollDayIfNeeded()
        let path = currentPathState()
        guard let interfaceName = primaryInterfaceName(pathUpdates: path.updates),
              let counters = counters(for: interfaceName) else {
            primaryInterface = nil
            previous = nil
            receivedBytesForConnection = 0
            sentBytesForConnection = 0
            return nil
        }

        let now = Date()
        var receivedBytesPerSecond: Double?
        var sentBytesPerSecond: Double?
        var rateInterval: TimeInterval?

        if let previous,
           previous.interfaceName == interfaceName,
           previous.generation == path.generation,
           counters.receivedBytes >= previous.receivedBytes,
           counters.sentBytes >= previous.sentBytes {
            let elapsed = now.timeIntervalSince(previous.timestamp)
            if elapsed > 0 {
                let receivedDelta = counters.receivedBytes - previous.receivedBytes
                let sentDelta = counters.sentBytes - previous.sentBytes
                if elapsed <= Self.maximumRateInterval {
                    receivedBytesPerSecond = Double(receivedDelta) / elapsed
                    sentBytesPerSecond = Double(sentDelta) / elapsed
                    rateInterval = elapsed
                }
                receivedBytesForConnection += receivedDelta
                sentBytesForConnection += sentDelta
                receivedBytesToday += receivedDelta
                sentBytesToday += sentDelta
            }
        } else if previous != nil {
            receivedBytesForConnection = 0
            sentBytesForConnection = 0
        }

        previous = (interfaceName, path.generation, counters.receivedBytes, counters.sentBytes, now)
        persistIfNeeded(now: now)

        return NetworkSnapshot(
            interfaceName: interfaceName,
            receivedBytesPerSecond: receivedBytesPerSecond,
            sentBytesPerSecond: sentBytesPerSecond,
            rateInterval: rateInterval,
            receivedBytesForConnection: receivedBytesForConnection,
            sentBytesForConnection: sentBytesForConnection,
            receivedBytesToday: receivedBytesToday,
            sentBytesToday: sentBytesToday,
            isExpensive: path.isExpensive,
            isConstrained: path.isConstrained
        )
    }

    func persist() {
        defaults.set(totalsDay, forKey: PersistenceKey.day)
        defaults.set(Int64(clamping: receivedBytesToday), forKey: PersistenceKey.received)
        defaults.set(Int64(clamping: sentBytesToday), forKey: PersistenceKey.sent)
        lastPersistence = Date()
    }

    private func currentPathState() -> (isExpensive: Bool, isConstrained: Bool, generation: UInt64, updates: UInt64) {
        pathLock.lock()
        defer { pathLock.unlock() }
        return pathState
    }

    private func rollDayIfNeeded() {
        let today = Self.dayKey(Date())
        guard totalsDay != today else { return }
        totalsDay = today
        receivedBytesToday = 0
        sentBytesToday = 0
        persist()
    }

    private func persistIfNeeded(now: Date) {
        if now.timeIntervalSince(lastPersistence) >= 30 {
            persist()
        }
    }

    private static func dayKey(_ date: Date) -> String {
        dayFormatter.string(from: date)
    }

    // The primary interface changes only with the network path, so skip the configd lookup between path updates.
    private func primaryInterfaceName(pathUpdates: UInt64) -> String? {
        if let primaryInterface, primaryInterface.pathUpdates == pathUpdates {
            return primaryInterface.name
        }
        for key in ["State:/Network/Global/IPv4", "State:/Network/Global/IPv6"] {
            if let value = SCDynamicStoreCopyValue(nil, key as CFString),
               let dictionary = value as? [String: Any],
               let interfaceName = dictionary["PrimaryInterface"] as? String {
                primaryInterface = (interfaceName, pathUpdates)
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
