import XCTest
@testable import Gitchat

final class AppVersionManifestDecodingTests: XCTestCase {

    // Captured live from
    // GET https://api-dev.gitchat.sh/api/v1/app/version?platform=ios
    // on 2026-05-05.
    private let liveResponseJSON = """
    {
      "data": {
        "latestVersion": "1.0.4",
        "releaseNotes": "Minor bugs fixed",
        "releasedAt": "2026-04-23T21:15:52Z",
        "storeUrl": "https://apps.apple.com/us/app/gitchat/id6762181976?uo=4",
        "appStoreId": "6762181976",
        "minimumSupportedVersion": "1.0.0",
        "isForceUpdate": false
      },
      "statusCode": 200,
      "message": "Success"
    }
    """

    func test_decodes_inside_envelope() throws {
        let data = liveResponseJSON.data(using: .utf8)!
        let envelope = try JSONDecoder().decode(APIEnvelope<AppVersionManifest>.self, from: data)
        let manifest = try XCTUnwrap(envelope.data)
        XCTAssertEqual(manifest.latestVersion, "1.0.4")
        XCTAssertEqual(manifest.releaseNotes, "Minor bugs fixed")
        XCTAssertEqual(manifest.appStoreId, "6762181976")
        XCTAssertEqual(manifest.storeUrl.absoluteString, "https://apps.apple.com/us/app/gitchat/id6762181976?uo=4")
        XCTAssertEqual(manifest.minimumSupportedVersion, "1.0.0")
        XCTAssertEqual(manifest.isForceUpdate, false)
    }

    func test_releaseNotes_optional_when_missing() throws {
        let json = """
        {"data":{"latestVersion":"2.0.0","storeUrl":"https://example.com/app","appStoreId":"1","minimumSupportedVersion":"1.0.0","isForceUpdate":false},"statusCode":200,"message":"OK"}
        """.data(using: .utf8)!
        let envelope = try JSONDecoder().decode(APIEnvelope<AppVersionManifest>.self, from: json)
        let manifest = try XCTUnwrap(envelope.data)
        XCTAssertNil(manifest.releaseNotes)
    }
}
