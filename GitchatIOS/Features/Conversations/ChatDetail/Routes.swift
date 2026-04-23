import Foundation

struct ProfileLoginRoute: Hashable, Identifiable {
    let login: String
    var id: String { login }
}

struct ImagePreviewState: Hashable, Identifiable {
    let id = UUID()
    let urls: [String]
    let index: Int
}

struct URLItem: Identifiable {
    let url: URL
    var id: String { url.absoluteString }
}
