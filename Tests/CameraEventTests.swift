import XCTest
import Foundation

final class CameraEventTests: XCTestCase {
    func testProjectionHasOnlyStableIdentityAndIntentAndIgnoresCosmeticChanges() throws {
        let events = NVRCameraEvents()
        var camera = CameraConfiguration(name: "Secret name", ipAddress: "192.0.2.1",
            credentials: CameraCredentials(username: "secret-user", password: "secret-password"))
        camera.homebaseDeviceID = "camera-vendor-serial"
        let id = UUID().uuidString
        try events.replace([(id, camera)])
        let initial = events.snapshot
        XCTAssertEqual(initial.revision, 1)
        XCTAssertEqual(initial.cameras[0].homebaseDeviceID, camera.homebaseDeviceID)
        camera.name = "Renamed"
        try events.replace([(id, camera)])
        XCTAssertEqual(events.snapshot, initial)
        camera.recordingStarted = false
        try events.replace([(id, camera)])
        XCTAssertEqual(events.snapshot.revision, 2)
        XCTAssertFalse(events.snapshot.cameras[0].recordingStarted)
        let fields = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(events.snapshot)) as? [String: Any])
        let cameras = try XCTUnwrap(fields["cameras"] as? [[String: Any]])
        XCTAssertEqual(Set(cameras[0].keys), ["id", "homebaseDeviceID", "enabled", "recordingStarted"])
        try events.replace([])
        XCTAssertEqual(events.snapshot.revision, 3)
        XCTAssertTrue(events.snapshot.cameras.isEmpty)
        XCTAssertNotEqual(NVRCameraEvents().instanceID, initial.instanceID)
    }
    func testSnapshotOrderIsStableAndOversizeProjectionDoesNotAdvanceRevision() throws {
        var camera = CameraConfiguration(name: "Fixture", ipAddress: "192.0.2.1", credentials: nil)
        camera.homebaseDeviceID = "camera-vendor-serial"
        let events = NVRCameraEvents(), a = UUID().uuidString, b = UUID().uuidString
        try events.replace([(a, camera), (b, camera)])
        let snapshot = events.snapshot
        try events.replace([(b, camera), (a, camera)])
        XCTAssertEqual(events.snapshot, snapshot)
        camera.homebaseDeviceID = String(repeating: "x", count: 70_000)
        XCTAssertThrowsError(try events.replace([(a, camera)]))
        XCTAssertEqual(events.snapshot, snapshot)
    }
}
