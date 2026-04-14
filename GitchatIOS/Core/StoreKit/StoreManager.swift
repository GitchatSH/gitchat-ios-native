import Foundation
import StoreKit

/// StoreKit 2 wrapper. Auto-loads products, tracks entitlements, listens
/// for async transactions. Products must be created in App Store Connect
/// under the same bundle id — see docs/IAP_AND_PUSH.md.
@MainActor
final class StoreManager: ObservableObject {
    static let shared = StoreManager()

    @Published private(set) var products: [Product] = []
    @Published private(set) var entitlements: Set<String> = []
    @Published private(set) var isLoadingProducts = false

    static let productIDs: Set<String> = [
        "chat.git.pro.monthly",
        "chat.git.pro.yearly",
        "chat.git.supporter"
    ]

    var isPro: Bool {
        !entitlements.intersection(Self.productIDs).isEmpty
    }

    /// Subscription products (sorted by price ascending).
    var subscriptions: [Product] {
        products.filter { $0.type == .autoRenewable }
            .sorted { $0.price < $1.price }
    }

    /// One-time supporter upgrade.
    var supporter: Product? {
        products.first { $0.id == "chat.git.supporter" }
    }

    private var updatesTask: Task<Void, Never>?

    private init() {}

    func start() {
        updatesTask?.cancel()
        updatesTask = Task { await listenForTransactions() }
        Task {
            await loadProducts()
            await refreshEntitlements()
        }
    }

    func loadProducts() async {
        isLoadingProducts = true
        defer { isLoadingProducts = false }
        do {
            let loaded = try await Product.products(for: Self.productIDs)
            self.products = loaded
        } catch {
            // Silent — products may not yet exist in ASC
        }
    }

    @discardableResult
    func purchase(_ product: Product) async throws -> Bool {
        let result = try await product.purchase()
        switch result {
        case .success(let verification):
            if case .verified(let tx) = verification {
                entitlements.insert(tx.productID)
                await tx.finish()
                return true
            }
            return false
        case .userCancelled, .pending:
            return false
        @unknown default:
            return false
        }
    }

    func restore() async throws {
        try await AppStore.sync()
        await refreshEntitlements()
    }

    private func refreshEntitlements() async {
        var current: Set<String> = []
        for await result in Transaction.currentEntitlements {
            if case .verified(let tx) = result {
                current.insert(tx.productID)
            }
        }
        self.entitlements = current
    }

    private func listenForTransactions() async {
        for await result in Transaction.updates {
            if case .verified(let tx) = result {
                entitlements.insert(tx.productID)
                await tx.finish()
            }
        }
    }
}
