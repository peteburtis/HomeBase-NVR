import XCTest
import Foundation

final class CameraOptionsTests: XCTestCase {
    let low = VideoProfile(token: "sub", encoding: "H264", width: 1280, height: 720, frameRate: 15, bitrateKbps: 512)
    let high = VideoProfile(token: "main", encoding: "H264", width: 2304, height: 1296, frameRate: 15, bitrateKbps: 1228)
    func camera(saved: VideoProfile? = nil) -> CameraConfiguration {
        CameraConfiguration(name: "Homebase Name", provider: "ONVIF", ipAddress: "192.0.2.10",
                            onvifPort: 2020, rtspURL: saved == nil ? nil : "rtsp://192.0.2.10:554/old",
                            homebaseDeviceID: "camera-vendor-serial", videoProfile: saved,
                            credentials: CameraCredentials(username: "viewer", password: "fixture-secret"))
    }
    func testAddUsesDiscoveredDefaultsAndPreservesConnectionDetails() throws {
        let initial = camera()
        let edited = try CameraOptionsEditor.edit(initial, profiles: [high, low], askName: {
            XCTAssertEqual($0, "Homebase Name"); return "New Name"
        }, chooseProfile: { profiles, selected in
            XCTAssertEqual(profiles, [self.high, self.low]); XCTAssertEqual(selected, 1); return 1
        }, resolveStream: {
            XCTAssertEqual($0, self.low); return "rtsp://192.0.2.10:554/sub"
        })
        XCTAssertEqual(edited.name, "New Name")
        XCTAssertEqual(edited.videoProfile, low)
        XCTAssertEqual(edited.credentials, initial.credentials)
        XCTAssertEqual(edited.homebaseDeviceID, initial.homebaseDeviceID)
        XCTAssertEqual(edited.onvifPort, initial.onvifPort)
        XCTAssertEqual(initial.name, "Homebase Name")
        XCTAssertNil(initial.rtspURL)
    }
    func testChangeDefaultsToSavedProfileRegardlessOfOrderOr720pPreference() throws {
        let edited = try CameraOptionsEditor.edit(camera(saved: high), profiles: [low, high], askName: { $0 },
                                                 chooseProfile: { _, selected in
            XCTAssertEqual(selected, 1); return selected!
        }, resolveStream: { _ in "rtsp://192.0.2.10:554/main" })
        XCTAssertEqual(edited.videoProfile, high)
    }
    func testMissingSavedProfileRequiresExplicitSelection() throws {
        _ = try CameraOptionsEditor.edit(camera(saved: high), profiles: [low], askName: { $0 },
                                         chooseProfile: { _, selected in
            XCTAssertNil(selected); return 0
        }, resolveStream: { _ in "rtsp://192.0.2.10:554/sub" })
    }
    func testCancelledOrFailedEditLeavesInputUnchanged() {
        let initial = camera(saved: high)
        XCTAssertThrowsError(try CameraOptionsEditor.edit(initial, profiles: [high, low], askName: { _ in "Unsaved" },
                                                         chooseProfile: { _, _ in throw ServiceError("Cancelled") },
                                                         resolveStream: { _ in XCTFail("Must not resolve after cancellation"); return "" }))
        XCTAssertThrowsError(try CameraOptionsEditor.edit(initial, profiles: [high, low], askName: { _ in "Unsaved" },
                                                         chooseProfile: { _, _ in 1 },
                                                         resolveStream: { _ in throw ServiceError("Unavailable") }))
        XCTAssertEqual(initial, camera(saved: high))
    }
    func testManualStreamIsRetainedWhenEditingNameWithoutProfiles() throws {
        var initial = camera()
        initial.rtspURL = "rtsp://192.0.2.10:554/manual"
        let edited = try CameraOptionsEditor.edit(initial, profiles: nil, askName: { _ in "Renamed" },
                                                 chooseProfile: { _, _ in XCTFail("No profile menu expected"); return 0 },
                                                 resolveStream: { _ in XCTFail("No discovery expected"); return "" })
        XCTAssertEqual(edited.name, "Renamed")
        XCTAssertEqual(edited.rtspURL, initial.rtspURL)
    }
}
