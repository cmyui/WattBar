import Foundation
import IOKit

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
        let externalConnected = bool(properties["ExternalConnected"])
        let currentBatteryNetWatts = batteryNetFromVoltageAndCurrent(properties)
        let telemetryBatteryNetWatts = normalizedBatteryPower(
            signedMilliwatts(telemetry?["BatteryPower"]),
            externalConnected: externalConnected
        )

        return PowerSnapshot(
            batteryPercent: int(properties["CurrentCapacity"]),
            externalConnected: externalConnected,
            isCharging: bool(properties["IsCharging"]),
            adapterAdvertisedWatts: double(adapterDetails?["Watts"]),
            adapterInputWatts: positiveMilliwatts(telemetry?["SystemPowerIn"]),
            systemLoadWatts: positiveMilliwatts(telemetry?["SystemLoad"])
                ?? currentBatteryNetWatts.map(abs),
            batteryNetWatts: currentBatteryNetWatts ?? telemetryBatteryNetWatts,
            telemetryTimestamp: date(properties["UpdateTime"]),
            readTimestamp: Date()
        )
    }

    private func batteryNetFromVoltageAndCurrent(_ properties: NSDictionary) -> Double? {
        guard let voltageMillivolts = double(properties["Voltage"] ?? properties["AppleRawBatteryVoltage"]),
              let amperageMilliamps = signedDouble(properties["Amperage"]) else {
            return nil
        }

        return voltageMillivolts * amperageMilliamps / 1_000_000.0
    }

    private func int(_ value: Any?) -> Int? {
        (value as? NSNumber)?.intValue
    }

    private func bool(_ value: Any?) -> Bool {
        (value as? NSNumber)?.boolValue ?? false
    }

    private func double(_ value: Any?) -> Double? {
        (value as? NSNumber)?.doubleValue
    }

    private func positiveMilliwatts(_ value: Any?) -> Double? {
        guard let value = double(value), value >= 0, value < 1_000_000 else {
            return nil
        }
        return value / 1_000.0
    }

    private func signedMilliwatts(_ value: Any?) -> Double? {
        signedDouble(value).map { $0 / 1_000.0 }
    }

    private func signedDouble(_ value: Any?) -> Double? {
        guard let number = value as? NSNumber else {
            return nil
        }
        return Double(Int64(bitPattern: number.uint64Value))
    }

    private func normalizedBatteryPower(_ value: Double?, externalConnected: Bool) -> Double? {
        value.map { externalConnected ? $0 : -abs($0) }
    }

    private func date(_ value: Any?) -> Date? {
        guard let seconds = double(value), seconds > 0 else {
            return nil
        }
        return Date(timeIntervalSince1970: seconds)
    }
}
