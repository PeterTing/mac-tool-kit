import Foundation
import IOKit

// MARK: - GPU Models

public struct GPUUsageSnapshot: Sendable {
    /// Overall GPU busy percentage (0-100), from IOAccelerator "Device Utilization %".
    public let utilization: Double
    public let rendererUtilization: Double
    public let tilerUtilization: Double
    /// System (unified) memory currently mapped by the GPU driver.
    public let inUseMemoryBytes: UInt64
    public let allocatedMemoryBytes: UInt64
    public let deviceName: String
    public let timestamp: Date

    public init(
        utilization: Double = 0,
        rendererUtilization: Double = 0,
        tilerUtilization: Double = 0,
        inUseMemoryBytes: UInt64 = 0,
        allocatedMemoryBytes: UInt64 = 0,
        deviceName: String = "",
        timestamp: Date = Date()
    ) {
        self.utilization = utilization
        self.rendererUtilization = rendererUtilization
        self.tilerUtilization = tilerUtilization
        self.inUseMemoryBytes = inUseMemoryBytes
        self.allocatedMemoryBytes = allocatedMemoryBytes
        self.deviceName = deviceName
        self.timestamp = timestamp
    }
}

// MARK: - GPU Monitor

/// Reads Apple Silicon / discrete GPU utilization straight from the IORegistry.
///
/// Every `IOAccelerator` service publishes a `PerformanceStatistics` dictionary
/// containing `Device Utilization %`, which is what Activity Monitor's GPU
/// History window is driven by. No private frameworks, no elevated privileges,
/// and a full sample costs well under a millisecond.
public final class GPUMonitor: @unchecked Sendable {

    public init() {}

    public func sample() -> GPUUsageSnapshot {
        var iterator: io_iterator_t = 0
        guard let matching = IOServiceMatching("IOAccelerator"),
              IOServiceGetMatchingServices(kIOMainPortDefault, matching, &iterator) == KERN_SUCCESS
        else {
            return GPUUsageSnapshot()
        }
        defer { IOObjectRelease(iterator) }

        var best = GPUUsageSnapshot()
        var found = false

        while case let service = IOIteratorNext(iterator), service != 0 {
            defer { IOObjectRelease(service) }

            var unmanagedProps: Unmanaged<CFMutableDictionary>?
            guard IORegistryEntryCreateCFProperties(service, &unmanagedProps, kCFAllocatorDefault, 0) == KERN_SUCCESS,
                  let props = unmanagedProps?.takeRetainedValue() as? [String: Any],
                  let stats = props["PerformanceStatistics"] as? [String: Any]
            else { continue }

            let utilization = Self.number(stats["Device Utilization %"])
            let renderer = Self.number(stats["Renderer Utilization %"])
            let tiler = Self.number(stats["Tiler Utilization %"])
            let inUse = UInt64(max(0, Self.number(stats["In use system memory"])))
            let allocated = UInt64(max(0, Self.number(stats["Alloc system memory"])))

            var nameBuffer = [CChar](repeating: 0, count: 128)
            let name = IORegistryEntryGetName(service, &nameBuffer) == KERN_SUCCESS
                ? String(cString: nameBuffer)
                : "GPU"

            // A Mac can expose several accelerators (integrated + discrete +
            // virtual). The busiest one is the one worth reporting.
            if !found || utilization > best.utilization {
                best = GPUUsageSnapshot(
                    utilization: min(100, max(0, utilization)),
                    rendererUtilization: min(100, max(0, renderer)),
                    tilerUtilization: min(100, max(0, tiler)),
                    inUseMemoryBytes: inUse,
                    allocatedMemoryBytes: allocated,
                    deviceName: name
                )
                found = true
            }
        }

        return best
    }

    private static func number(_ value: Any?) -> Double {
        if let n = value as? NSNumber { return n.doubleValue }
        if let d = value as? Double { return d }
        if let i = value as? Int { return Double(i) }
        return 0
    }
}
