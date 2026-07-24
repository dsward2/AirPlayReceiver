import XCTest
@testable import AirPlayReceiver

final class ShairportSyncArgumentsTests: XCTestCase {
    func testBasicArgumentsIncludeDeviceName() {
        let args = ShairportSyncArguments.make(deviceName: "Test Speaker", password: nil)
        XCTAssertEqual(args, ["-a", "Test Speaker", "-o", "stdout"])
    }

    func testPasswordIsAppendedWhenNonEmpty() {
        let args = ShairportSyncArguments.make(deviceName: "Test Speaker", password: "secret")
        XCTAssertEqual(args, ["-a", "Test Speaker", "-o", "stdout", "--password", "secret"])
    }

    func testEmptyPasswordIsOmitted() {
        let args = ShairportSyncArguments.make(deviceName: "Test Speaker", password: "")
        XCTAssertEqual(args, ["-a", "Test Speaker", "-o", "stdout"])
    }
}
