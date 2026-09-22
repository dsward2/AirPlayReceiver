import XCTest
@testable import AirPlayReceiver

final class ShairportSyncArgumentsTests: XCTestCase {
    func testBasicArgumentsIncludeDeviceName() {
        let args = ShairportSyncArguments.make(deviceName: "Test Speaker", password: nil,
                                               sessionMarkerPath: "/tmp/marker", metadataPipePath: "/tmp/metadata")
        XCTAssertEqual(args, ["-a", "Test Speaker", "-o", "stdout",
                              "-B", "/usr/bin/touch '/tmp/marker'",
                              "-E", "/bin/rm -f '/tmp/marker'",
                              "--metadata-enable", "--metadata-pipename", "/tmp/metadata"])
    }

    func testPasswordIsAppendedWhenNonEmpty() {
        let args = ShairportSyncArguments.make(deviceName: "Test Speaker", password: "secret",
                                               sessionMarkerPath: "/tmp/marker", metadataPipePath: "/tmp/metadata")
        XCTAssertEqual(args, ["-a", "Test Speaker", "-o", "stdout",
                              "-B", "/usr/bin/touch '/tmp/marker'",
                              "-E", "/bin/rm -f '/tmp/marker'",
                              "--metadata-enable", "--metadata-pipename", "/tmp/metadata",
                              "--password", "secret"])
    }

    func testEmptyPasswordIsOmitted() {
        let args = ShairportSyncArguments.make(deviceName: "Test Speaker", password: "",
                                               sessionMarkerPath: "/tmp/marker", metadataPipePath: "/tmp/metadata")
        XCTAssertEqual(args, ["-a", "Test Speaker", "-o", "stdout",
                              "-B", "/usr/bin/touch '/tmp/marker'",
                              "-E", "/bin/rm -f '/tmp/marker'",
                              "--metadata-enable", "--metadata-pipename", "/tmp/metadata"])
    }
}
