import XCTest
@testable import Gitchat

final class PendingAttachmentTests: XCTestCase {
    func test_init_createsAttachmentWithSourceData_andNilUploaded() {
        let data = Data([0xFF, 0xD8, 0xFF])
        let att = PendingAttachment(
            clientAttachmentID: "att-1",
            sourceData: data,
            mimeType: "image/jpeg",
            width: 100, height: 200, blurhash: nil
        )
        XCTAssertEqual(att.clientAttachmentID, "att-1")
        XCTAssertEqual(att.sourceData, data)
        XCTAssertEqual(att.mimeType, "image/jpeg")
        XCTAssertEqual(att.width, 100)
        XCTAssertEqual(att.height, 200)
        XCTAssertNil(att.uploaded)
    }

    func test_uploadedRef_assignsURL() {
        var att = PendingAttachment(
            clientAttachmentID: "att-1", sourceData: Data(),
            mimeType: "image/png", width: nil, height: nil, blurhash: nil
        )
        att.uploaded = UploadedRef(url: "https://cdn/x.png", storagePath: "p/x.png", sizeBytes: 1024)
        XCTAssertEqual(att.uploaded?.url, "https://cdn/x.png")
        XCTAssertEqual(att.uploaded?.storagePath, "p/x.png")
        XCTAssertEqual(att.uploaded?.sizeBytes, 1024)
    }
}
