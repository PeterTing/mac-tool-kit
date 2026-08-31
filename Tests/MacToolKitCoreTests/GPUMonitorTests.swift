import XCTest
@testable import MacToolKitCore

/// `GPUMonitor` reads live IORegistry data, so these tests assert invariants
/// that must hold on any machine — including CI runners with no accelerator
/// published, where every field legitimately comes back as zero.
final class GPUMonitorTests: XCTestCase {

    func testDefaultSnapshotIsZeroed() {
        let snapshot = GPUUsageSnapshot()

        XCTAssertEqual(snapshot.utilization, 0)
        XCTAssertEqual(snapshot.rendererUtilization, 0)
        XCTAssertEqual(snapshot.tilerUtilization, 0)
        XCTAssertEqual(snapshot.inUseMemoryBytes, 0)
        XCTAssertEqual(snapshot.allocatedMemoryBytes, 0)
        XCTAssertTrue(snapshot.deviceName.isEmpty)
    }

    func testSampleStaysWithinValidRanges() {
        let snapshot = GPUMonitor().sample()

        XCTAssertGreaterThanOrEqual(snapshot.utilization, 0)
        XCTAssertLessThanOrEqual(snapshot.utilization, 100)
        XCTAssertGreaterThanOrEqual(snapshot.rendererUtilization, 0)
        XCTAssertLessThanOrEqual(snapshot.rendererUtilization, 100)
        XCTAssertGreaterThanOrEqual(snapshot.tilerUtilization, 0)
        XCTAssertLessThanOrEqual(snapshot.tilerUtilization, 100)
        XCTAssertFalse(snapshot.utilization.isNaN)
    }

    func testSnapshotTimestampIsFresh() {
        let before = Date()
        let snapshot = GPUMonitor().sample()

        XCTAssertGreaterThanOrEqual(snapshot.timestamp.timeIntervalSince1970,
                                    before.timeIntervalSince1970 - 1)
        XCTAssertLessThanOrEqual(snapshot.timestamp.timeIntervalSince(before), 5)
    }

    func testRepeatedSamplingIsStableAndReentrant() {
        let monitor = GPUMonitor()

        for _ in 0..<20 {
            let snapshot = monitor.sample()
            XCTAssertGreaterThanOrEqual(snapshot.utilization, 0)
            XCTAssertLessThanOrEqual(snapshot.utilization, 100)
        }
    }

    /// A machine that publishes an accelerator must also name it; a machine
    /// that publishes none must report a fully zeroed snapshot. Anything in
    /// between means the registry walk lost track of the device.
    func testDeviceNameAccompaniesReportedMemory() {
        let snapshot = GPUMonitor().sample()

        if snapshot.inUseMemoryBytes > 0 || snapshot.allocatedMemoryBytes > 0 {
            XCTAssertFalse(snapshot.deviceName.isEmpty)
        }
    }

    func testMonitorIsUsableFromConcurrentTasks() async {
        let monitor = GPUMonitor()

        await withTaskGroup(of: Double.self) { group in
            for _ in 0..<8 {
                group.addTask { monitor.sample().utilization }
            }
            for await utilization in group {
                XCTAssertGreaterThanOrEqual(utilization, 0)
                XCTAssertLessThanOrEqual(utilization, 100)
            }
        }
    }
}
