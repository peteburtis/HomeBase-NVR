import XCTest
import Foundation
import Darwin

final class ONVIFTests: XCTestCase {
    let credentials = CameraCredentials(username: "viewer<&", password: "fixture-secret")
    func endpoint() throws -> HomebaseImport.Endpoint {
        try JSONDecoder().decode(HomebaseImport.Endpoint.self, from: Data(#"{"Provider":"ONVIF","IPAddress":"192.0.2.1","ONVIFPort":2020,"RTSPPort":554,"CredentialsPath":"arbitrary.json"}"#.utf8))
    }
    func response(_ operation: String, _ body: String) -> Data {
        Data("<s:Envelope xmlns:s=\"http://www.w3.org/2003/05/soap-envelope\"><s:Body><\(operation)Response>\(body)</\(operation)Response></s:Body></s:Envelope>".utf8)
    }
    func profile(_ token: String, _ width: Int, _ height: Int, encoding: String = "H264") -> String {
        "<trt:Profiles xmlns:trt=\"http://www.onvif.org/ver10/media/wsdl\" token=\"\(token)\"><VideoEncoderConfiguration><Encoding>\(encoding)</Encoding><Resolution><Width>\(width)</Width><Height>\(height)</Height></Resolution><RateControl><FrameRateLimit>15</FrameRateLimit><BitrateLimit>512</BitrateLimit></RateControl></VideoEncoderConfiguration></trt:Profiles>"
    }
    func testHardwareIDMatchesHomebaseEscapingAndCase() throws {
        XCTAssertEqual(try ONVIFClient.hardwareID(manufacturer: " TP-Link ", serial: "7461CA79"), "camera-tp-link-7461ca79")
        XCTAssertEqual(try ONVIFClient.hardwareID(manufacturer: "Acme Inc", serial: "A-2.X"), "camera-acme%20inc-a%2d2%2ex")
        XCTAssertThrowsError(try ONVIFClient.hardwareID(manufacturer: "", serial: "x"))
        XCTAssertThrowsError(try ONVIFClient.hardwareID(manufacturer: "a", serial: ""))
    }
    func testSOAPSecurityDoesNotSendPlaintextPasswordAndEscapesUsername() {
        let request = ONVIFClient.request(url: URL(string: "http://192.0.2.1/onvif/service")!, operation: "GetDeviceInformation", media: false, body: "<tds:GetDeviceInformation/>", credentials: credentials, timeout: 2, date: Date(timeIntervalSince1970: 0), nonce: Data([1, 2, 3]))
        let body = String(decoding: request.httpBody!, as: UTF8.self)
        XCTAssertEqual(request.httpMethod, "POST")
        XCTAssertTrue(body.contains("viewer&lt;&amp;"))
        XCTAssertTrue(body.contains("PasswordDigest"))
        XCTAssertTrue(body.contains("AQID"))
        XCTAssertFalse(body.contains("fixture-secret"))
        XCTAssertNil(request.value(forHTTPHeaderField: "Authorization"))
        XCTAssertEqual(request.timeoutInterval, 2)
    }
    func testProfilesReadNamespacesAndSelectRealNearest720p() throws {
        let xml = response("GetProfiles", profile("high", 2304, 1296) + profile("mid", 1280, 720) + profile("low", 640, 360) + profile("jpeg", 800, 600, encoding: "JPEG"))
        let profiles = try ONVIFClient.profiles(ONVIFXML.response(xml, operation: "GetProfiles"))
        XCTAssertEqual(profiles.map(\.token), ["high", "mid", "low"])
        XCTAssertEqual(VideoProfile.preferredIndex(profiles), 1)
        XCTAssertEqual(profiles[1].frameRate, 15)
        XCTAssertEqual(profiles[1].bitrateKbps, 512)
        let h265 = try ONVIFClient.profiles(ONVIFXML.response(response("GetProfiles", profile("hevc", 1920, 1080, encoding: "H265")), operation: "GetProfiles"))
        XCTAssertEqual(h265[0].encoding, "H265")
        XCTAssertThrowsError(try ONVIFClient.profiles(ONVIFXML.response(response("GetProfiles", profile("bad", Int.max, 99)), operation: "GetProfiles")))
    }
    func testMalformedFaultAndEntityResponsesAreRejectedWithoutBodyLeak() {
        for text in ["not XML", "<!DOCTYPE x [<!ENTITY x SYSTEM 'file:///etc/passwd'>]><x>&x;</x>", "<Envelope>" + String(repeating: "<x>", count: 40)] {
            XCTAssertThrowsError(try ONVIFXML.response(Data(text.utf8), operation: "GetProfiles"))
        }
        let fault = Data("<Envelope><Body><Fault><Reason>NotAuthorized fixture-secret</Reason></Fault></Body></Envelope>".utf8)
        XCTAssertThrowsError(try ONVIFXML.response(fault, operation: "GetProfiles")) { error in
            XCTAssertEqual((error as! ServiceError).code, .permission)
            XCTAssertFalse((error as! ServiceError).message.contains("fixture-secret"))
        }
        XCTAssertThrowsError(try ONVIFXML.response(response("WrongOperation", ""), operation: "GetProfiles"))
    }
    func testDiscoveryUsesOnlyReadOperationsAndPinsAdvertisedURLs() throws {
        var operations: [String] = []
        let client = try ONVIFClient(endpoint: endpoint(), credentials: credentials) { request, timeout in
            XCTAssertLessThanOrEqual(timeout, 5)
            XCTAssertEqual(request.url?.host, "192.0.2.1")
            let action = request.value(forHTTPHeaderField: "Content-Type")!
            let operation = String(action.split(separator: "/").last!.dropLast())
            operations.append(operation)
            let body: String
            switch operation {
            case "GetDeviceInformation": body = "<Manufacturer>Fixture</Manufacturer><SerialNumber>123</SerialNumber>"
            case "GetCapabilities": body = "<Capabilities><Media><XAddr>http://untrusted.invalid:2020/onvif/media</XAddr></Media></Capabilities>"
            case "GetProfiles": body = self.profile("high", 1920, 1080) + self.profile("low", 1280, 720)
            case "GetStreamUri": body = "<MediaUri><Uri>rtsp://wrong:secret@untrusted.invalid:9999/stream1?channel=1</Uri></MediaUri>"
            default: XCTFail("Unexpected camera operation"); body = ""
            }
            return ONVIFResponse(status: 200, data: self.response(operation, body))
        }
        let media = try client.media(expectedID: "camera-fixture-123", deadline: ProcessInfo.processInfo.systemUptime + 10)
        let url = try client.stream(profile: media.profiles[1], media: media, deadline: ProcessInfo.processInfo.systemUptime + 5)
        XCTAssertEqual(url, "rtsp://192.0.2.1:554/stream1?channel=1")
        XCTAssertEqual(operations, ["GetDeviceInformation", "GetCapabilities", "GetProfiles", "GetDeviceInformation", "GetStreamUri"])
    }
    func testDeviceServiceFallbackAndIdentityChange() throws {
        var calls = 0
        let client = try ONVIFClient(endpoint: endpoint(), credentials: credentials) { request, _ in
            calls += 1
            if request.url?.path == "/onvif/service" { return ONVIFResponse(status: 404, data: Data()) }
            XCTAssertEqual(request.url?.path, "/onvif/device_service")
            return ONVIFResponse(status: 200, data: self.response("GetDeviceInformation", "<Manufacturer>Acme</Manufacturer><SerialNumber>New</SerialNumber>"))
        }
        XCTAssertEqual(try client.identify(deadline: ProcessInfo.processInfo.systemUptime + 3), "camera-acme-new")
        XCTAssertEqual(calls, 2)
        XCTAssertThrowsError(try client.media(expectedID: "camera-acme-old", deadline: ProcessInfo.processInfo.systemUptime + 3))
        XCTAssertEqual(calls, 3)
        XCTAssertThrowsError(try client.identify(deadline: ProcessInfo.processInfo.systemUptime - 1)) { error in
            XCTAssertEqual((error as! ServiceError).code, .timeout)
        }
        XCTAssertEqual(calls, 3)
    }
    func testFileOnlyNamesAndDeviceDocumentPrecedence() throws {
        let directory = "/tmp/hn-naming-" + UUID().uuidString
        defer { try? FileManager.default.removeItem(atPath: directory) }
        try SecureFiles.ensureDirectory(directory + "/devices", owner: geteuid(), mode: 0o700)
        try SecureFiles.atomicWrite(Data(#"{"LivingRoomCamera":"camera-acme-123"}"#.utf8), to: directory + "/aliases.json", mode: 0o600)
        let names = try HomebaseCameraDiscovery.names(identifier: "camera-acme-123", directory: directory)
        XCTAssertEqual(names.alias, "LivingRoomCamera")
        XCTAssertEqual(names.display, "Living Room Camera")
        try SecureFiles.atomicWrite(Data(#"{"DisplayName":"Alias file name"}"#.utf8), to: directory + "/devices/LivingRoomCamera.json", mode: 0o600)
        XCTAssertEqual(try HomebaseCameraDiscovery.names(identifier: "camera-acme-123", directory: directory).display, "Alias file name")
        try SecureFiles.atomicWrite(Data(#"{"DisplayName":"Hardware file name"}"#.utf8), to: directory + "/devices/camera-acme-123.json", mode: 0o600)
        XCTAssertEqual(try HomebaseCameraDiscovery.names(identifier: "camera-acme-123", directory: directory).display, "Hardware file name")
        try SecureFiles.atomicWrite(Data("{}".utf8), to: directory + "/devices/camera-acme-123.json", mode: 0o600)
        XCTAssertEqual(try HomebaseCameraDiscovery.names(identifier: "camera-acme-123", directory: directory).display, "Living Room Camera")
        XCTAssertEqual(HomebaseCameraDiscovery.humanize("PTZCamera2"), "PTZ Camera 2")
    }
    func testPersistedProfileRequiresURLAndRoundTrips() throws {
        let profile = VideoProfile(token: "sub", encoding: "H264", width: 1280, height: 720, frameRate: 15, bitrateKbps: 512)
        var camera = CameraConfiguration(name: "Camera", ipAddress: "192.0.2.1", videoProfile: profile, credentials: credentials)
        XCTAssertThrowsError(try camera.validate())
        camera.rtspURL = "rtsp://192.0.2.1:554/stream2"
        try camera.validate()
        XCTAssertEqual(try JSONDecoder().decode(CameraConfiguration.self, from: CameraJSON.encode(camera)), camera)
    }
}
