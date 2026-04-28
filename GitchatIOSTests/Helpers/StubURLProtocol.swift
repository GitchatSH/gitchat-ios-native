import Foundation

/// URLProtocol that captures outgoing request bodies and returns a canned response.
/// Register by building a URLSession with a configuration that includes StubURLProtocol,
/// then inject that session into APIClient(session:) for testing.
final class StubURLProtocol: URLProtocol {
    static var lastRequestBodyData: Data?
    static var responseStatus: Int = 200
    static var responseBody: Data = Data("{\"data\":{}}".utf8)

    static var lastRequestBody: Any? {
        guard let data = lastRequestBodyData else { return nil }
        return try? JSONSerialization.jsonObject(with: data)
    }

    static func reset() {
        lastRequestBodyData = nil
        responseStatus = 200
        responseBody = Data("{\"data\":{}}".utf8)
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        if let stream = request.httpBodyStream {
            StubURLProtocol.lastRequestBodyData = StubURLProtocol.read(stream)
        } else {
            StubURLProtocol.lastRequestBodyData = request.httpBody
        }
        let response = HTTPURLResponse(
            url: request.url!,
            statusCode: StubURLProtocol.responseStatus,
            httpVersion: nil,
            headerFields: ["Content-Type": "application/json"]
        )!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: StubURLProtocol.responseBody)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}

    private static func read(_ stream: InputStream) -> Data {
        var data = Data()
        stream.open(); defer { stream.close() }
        let buffer = UnsafeMutablePointer<UInt8>.allocate(capacity: 4096)
        defer { buffer.deallocate() }
        while stream.hasBytesAvailable {
            let n = stream.read(buffer, maxLength: 4096)
            if n <= 0 { break }
            data.append(buffer, count: n)
        }
        return data
    }
}
