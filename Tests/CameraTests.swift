import XCTest
import Foundation
import Darwin

final class CameraTests: XCTestCase {
    func testImportOfferDetectsInstallationWithoutRequiringCameras() {
        let markers = ["/installed/homebase", "/installed/agent.plist"]
        for detected in markers + ["/config"] {
            XCTAssertTrue(HomebaseImport.shouldOfferImport(directory: "/config", markers: markers, exists: { $0 == detected }))
        }
        XCTAssertFalse(HomebaseImport.shouldOfferImport(directory: "/config", markers: markers, exists: { _ in false }))
    }
    func temporary() throws -> String {
        let path = "/tmp/hc-" + UUID().uuidString
        try SecureFiles.ensureDirectory(path, owner: geteuid(), mode: 0o700)
        addTeardownBlock { try? FileManager.default.removeItem(atPath: path) }
        return path
    }
    func camera(_ host: String = "192.0.2.1") -> CameraConfiguration {
        CameraConfiguration(name: "Hall", ipAddress: host, rtspURL: "rtsp://\(host):554/stream1",
                            credentials: CameraCredentials(username: "viewer", password: "fixture-secret"))
    }
    func testRTSPOnlyAndAnonymousConfiguration() throws {
        let value = camera()
        try value.validate()
        XCTAssertNil(value.onvifPort)
        XCTAssertEqual(value.provider, "RTSP")
        var anonymous = CameraConfiguration(name: "Guest", ipAddress: "camera.local", credentials: nil)
        anonymous.rtspURL = try CameraConfiguration.streamURL("/live", host: "camera.local", port: 554)
        try anonymous.validate()
        XCTAssertEqual(try JSONDecoder().decode(CameraConfiguration.self, from: CameraJSON.encode(value)), value)
    }
    func testURLValidationAndOptionalMetadata() throws {
        XCTAssertEqual(try CameraConfiguration.streamURL("/live?channel=1", host: "::1", port: 8554), "rtsp://[::1]:8554/live?channel=1")
        XCTAssertNotNil(try CameraConfiguration.streamURL("rtsps://camera.local:8554/live", host: "camera.local", port: 8554))
        for url in ["http://camera.local/live", "rtsp://user:secret@camera.local/live", "rtsp://other.local/live", "rtsp://camera.local:999/live", "rtsp://camera.local/live#fragment"] {
            XCTAssertThrowsError(try CameraConfiguration.streamURL(url, host: "camera.local", port: 554))
        }
        var value = camera()
        value.onvifPort = 0
        XCTAssertThrowsError(try value.validate())
        XCTAssertFalse(CameraConfiguration.validHost("rtsp://camera"))
        XCTAssertFalse(CameraConfiguration.validHost("../outside"))
    }
    func testPersistenceDuplicateProtectionAndRemoval() throws {
        let directory = try temporary() + "/cameras"
        let store = CameraStore(directory: directory)
        let saved = try store.add(camera())
        XCTAssertEqual(try SecureFiles.info(directory)!.st_mode & 0o777, 0o700)
        XCTAssertEqual(try SecureFiles.info(directory + "/" + saved.id + ".json")!.st_mode & 0o777, 0o600)
        XCTAssertEqual(try CameraStore(directory: directory).list().map(\.id), [saved.id])
        XCTAssertThrowsError(try store.add(camera()))
        XCTAssertThrowsError(try store.remove(id: "../outside"))
        _ = try store.remove(id: saved.id)
        XCTAssertTrue(try store.list().isEmpty)
        XCTAssertThrowsError(try store.remove(id: saved.id))
    }
    func testMalformedAndUnsafeFilesAreNotOverwritten() throws {
        let directory = try temporary()
        let store = CameraStore(directory: directory)
        let path = directory + "/" + UUID().uuidString + ".json"
        let malformed = Data("{\"Password\":\"fixture-secret\",broken".utf8)
        try SecureFiles.atomicWrite(malformed, to: path, mode: 0o600)
        XCTAssertThrowsError(try store.add(camera())) { error in
            XCTAssertFalse((error as! ServiceError).message.contains("fixture-secret"))
        }
        XCTAssertEqual(try Data(contentsOf: URL(fileURLWithPath: path)), malformed)
        try SecureFiles.removeFile(path)
        let target = try temporary() + "/target.json"
        try SecureFiles.atomicWrite(CameraJSON.encode(camera()), to: target, mode: 0o600)
        try FileManager.default.createSymbolicLink(atPath: path, withDestinationPath: target)
        XCTAssertThrowsError(try store.list())
        XCTAssertTrue(FileManager.default.fileExists(atPath: target))
        XCTAssertEqual(chmod(target, 0o644), 0)
        XCTAssertThrowsError(try CameraJSON.read(target, privateFile: true))
    }
    func testSummaryNeverContainsCredentialsOrStreamTokens() throws {
        let summary = CameraSummary(id: UUID().uuidString, camera: camera())
        let text = String(decoding: try CameraJSON.encode(summary), as: UTF8.self)
        for secret in ["fixture-secret", "viewer", "Credentials", "RTSPURL", "stream1"] { XCTAssertFalse(text.contains(secret)) }
    }
    func testImportDefaultsAndIgnoresManagementCredentials() throws {
        let directory = try temporary()
        try SecureFiles.ensureDirectory(directory + "/modules", owner: geteuid(), mode: 0o700)
        try SecureFiles.atomicWrite(Data(#"{"Cameras":[{"Provider":"ONVIF","IPAddress":"192.0.2.1","CredentialsPath":"login.json"}]}"#.utf8), to: directory + "/modules/cameras.json", mode: 0o600)
        try SecureFiles.atomicWrite(Data(#"{"SchemaVersion":1,"Username":"viewer","Password":"fixture-secret","TapoUsername":"management","TapoPassword":"do-not-copy"}"#.utf8), to: directory + "/login.json", mode: 0o600)
        let endpoints = try HomebaseImport.cameras(directory: directory)
        let value = try HomebaseImport.configuration(endpoints[0], name: "Hall", directory: directory)
        XCTAssertEqual(value.onvifPort, 80); XCTAssertEqual(value.rtspPort, 554)
        XCTAssertNil(value.rtspURL)
        XCTAssertFalse(String(decoding: try CameraJSON.encode(value), as: UTF8.self).contains("do-not-copy"))
        var namedEndpoint = endpoints[0]
        namedEndpoint.deviceID = "camera-vendor-serial"
        let named = try HomebaseImport.configuration(namedEndpoint, name: "Hall", directory: directory)
        XCTAssertEqual(named.homebaseDeviceID, "camera-vendor-serial")
        XCTAssertEqual(try JSONDecoder().decode(CameraConfiguration.self, from: CameraJSON.encode(named)), named)
    }
    func testUnauthorizedCameraMutationIsRejectedBeforeReading() throws {
        var pair = [Int32](repeating: -1, count: 2)
        XCTAssertEqual(socketpair(AF_UNIX, SOCK_STREAM, 0, &pair), 0)
        defer { pair.forEach { close($0) } }
        let directory = try temporary()
        let request = Request(protocolVersion: 1, operation: "cameras.add", camera: camera())
        try SocketIO.write(JSONEncoder().encode(request), fd: pair[1], deadline: ProcessInfo.processInfo.systemUptime + 1)
        AgentServer(directory: directory, authorization: .local(geteuid() + 1), system: false).handle(pair[0], started: ProcessInfo.processInfo.systemUptime)
        let data = try SocketIO.read(fd: pair[1], deadline: ProcessInfo.processInfo.systemUptime + 1)
        XCTAssertEqual(try JSONDecoder().decode(Reply.self, from: data).code, .permission)
        XCTAssertFalse(FileManager.default.fileExists(atPath: directory + "/cameras"))
    }
    func testClientChecksServerIdentityBeforeSendingSecrets() throws {
        let directory = try temporary()
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        defer { close(fd) }
        XCTAssertEqual(try SocketIO.address(SocketIO.path(directory)) { Darwin.bind(fd, $0, $1) }, 0)
        XCTAssertEqual(listen(fd, 1), 0)
        XCTAssertThrowsError(try SocketClient.exchange(Request(protocolVersion: 1, operation: "cameras.add", camera: camera()), directory: directory, expectedUID: geteuid() + 1)) { error in
            XCTAssertEqual((error as! ServiceError).code, .permission)
        }
        let client = accept(fd, nil, nil)
        defer { close(client) }
        var byte: UInt8 = 0
        XCTAssertEqual(recv(client, &byte, 1, 0), 0)
    }
}
