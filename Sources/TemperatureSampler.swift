import Foundation

// Apple silicon publishes its temperature sensors as HID event services. The IOHIDEventSystemClient
// functions that read them are not in the public SDK, so they are looked up at runtime.
// Unchecked Sendable: every stored property is immutable after init, and AppDelegate calls sample()
// from a single serial queue.
final class TemperatureSampler: @unchecked Sendable {
    private typealias CreateClient = @convention(c) (CFAllocator?) -> Unmanaged<CFTypeRef>?
    private typealias SetMatching = @convention(c) (CFTypeRef, CFDictionary) -> Int32
    private typealias CopyServices = @convention(c) (CFTypeRef) -> Unmanaged<CFArray>?
    private typealias CopyProperty = @convention(c) (CFTypeRef, CFString) -> Unmanaged<CFTypeRef>?
    private typealias CopyEvent = @convention(c) (CFTypeRef, Int64, Int32, Int64) -> Unmanaged<CFTypeRef>?
    private typealias GetFloatValue = @convention(c) (CFTypeRef, Int32) -> Double

    private enum Component {
        case soc
        case battery
        case ssd
    }

    private static let temperatureEventType: Int64 = 15 // kIOHIDEventTypeTemperature
    private static let temperatureField = Int32(15 << 16) // IOHIDEventFieldBase(kIOHIDEventTypeTemperature)

    // Kept alive for as long as the service clients it vends are read.
    private let client: CFTypeRef
    private let sensors: [(component: Component, service: CFTypeRef)]
    private let copyEvent: CopyEvent
    private let getFloatValue: GetFloatValue

    init?() {
        func symbol<T>(_ name: String, as type: T.Type) -> T? {
            // RTLD_DEFAULT, which Swift does not import: search every loaded image, including IOKit.
            dlsym(UnsafeMutableRawPointer(bitPattern: -2), name).map { unsafeBitCast($0, to: type) }
        }

        guard let createClient = symbol("IOHIDEventSystemClientCreate", as: CreateClient.self),
              let setMatching = symbol("IOHIDEventSystemClientSetMatching", as: SetMatching.self),
              let copyServices = symbol("IOHIDEventSystemClientCopyServices", as: CopyServices.self),
              let copyProperty = symbol("IOHIDServiceClientCopyProperty", as: CopyProperty.self),
              let copyEvent = symbol("IOHIDServiceClientCopyEvent", as: CopyEvent.self),
              let getFloatValue = symbol("IOHIDEventGetFloatValue", as: GetFloatValue.self),
              let client = createClient(kCFAllocatorDefault)?.takeRetainedValue() else {
            return nil
        }

        // Apple vendor usage page, temperature sensor usage.
        _ = setMatching(client, ["PrimaryUsagePage": 0xff00, "PrimaryUsage": 5] as CFDictionary)
        let services = (copyServices(client)?.takeRetainedValue() as? [CFTypeRef]) ?? []

        self.client = client
        self.copyEvent = copyEvent
        self.getFloatValue = getFloatValue
        sensors = services.compactMap { service in
            guard let name = copyProperty(service, "Product" as CFString)?.takeRetainedValue() as? String,
                  let component = Self.component(forSensorNamed: name) else {
                return nil
            }
            return (component, service)
        }
    }

    // Each component has several sensors; the menu reports the hottest one.
    func sample() -> TemperatureSnapshot {
        var hottest: [Component: Double] = [:]
        for sensor in sensors {
            guard let event = copyEvent(sensor.service, Self.temperatureEventType, 0, 0)?.takeRetainedValue() else {
                continue
            }
            let celsius = getFloatValue(event, Self.temperatureField)
            hottest[sensor.component] = max(celsius, hottest[sensor.component] ?? -.infinity)
        }
        return TemperatureSnapshot(socCelsius: hottest[.soc], batteryCelsius: hottest[.battery], ssdCelsius: hottest[.ssd])
    }

    private static func component(forSensorNamed name: String) -> Component? {
        if name.contains("tdie") { return .soc }
        if name.hasPrefix("gas gauge battery") { return .battery }
        if name.hasPrefix("NAND") { return .ssd }
        return nil
    }
}
