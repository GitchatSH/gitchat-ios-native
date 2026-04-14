import SwiftUI
import StoreKit

struct UpgradeView: View {
    @StateObject private var store = StoreManager.shared
    @Environment(\.dismiss) private var dismiss
    @State private var purchasing: String?
    @State private var error: String?

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 24) {
                    heroHeader
                    benefits
                    if store.isLoadingProducts && store.products.isEmpty {
                        ProgressView().padding()
                    } else if store.products.isEmpty {
                        comingSoon
                    } else {
                        subscriptionTiles
                        if let supporter = store.supporter {
                            oneTimeTile(supporter)
                        }
                    }
                    Button("Restore purchases") {
                        Task { try? await store.restore() }
                    }
                    .font(.geist(13, weight: .semibold))
                    .foregroundStyle(Color.accentColor)
                    if let error {
                        Text(error).font(.footnote).foregroundStyle(.red)
                    }
                    legal
                }
                .padding()
            }
            .navigationTitle("Gitchat Pro")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    Button("Close") { dismiss() }
                }
            }
        }
    }

    private var heroHeader: some View {
        VStack(spacing: 10) {
            Image(systemName: "sparkles")
                .font(.system(size: 44))
                .foregroundStyle(Color.accentColor)
            Text("Upgrade to Pro")
                .font(.geist(28, weight: .black))
            Text("Support the app and unlock the good stuff.")
                .font(.geist(14, weight: .regular))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
    }

    private var benefits: some View {
        VStack(alignment: .leading, spacing: 12) {
            benefit("infinity", "Unlimited message history", "Keep every conversation forever.")
            benefit("photo.stack", "Larger uploads", "Up to 100 MB per file — send the full repo screenshot.")
            benefit("paintbrush", "Custom accent color and extra themes", "Dim, Midnight, Solarized, Dracula.")
            benefit("star.fill", "Pro badge on your profile", "A little star next to your @handle.")
            benefit("number", "Unlimited repo channels", "Subscribe to everything you care about.")
            benefit("magnifyingglass", "Search all message history", "Not just the last 1000 messages.")
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func benefit(_ icon: String, _ title: String, _ sub: String) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: icon)
                .font(.system(size: 18))
                .foregroundStyle(Color.accentColor)
                .frame(width: 24)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.geist(15, weight: .semibold))
                Text(sub).font(.geist(12, weight: .regular)).foregroundStyle(.secondary)
            }
            Spacer()
        }
    }

    private var subscriptionTiles: some View {
        VStack(spacing: 10) {
            ForEach(store.subscriptions) { product in
                Button {
                    Task {
                        do {
                            purchasing = product.id
                            _ = try await store.purchase(product)
                            purchasing = nil
                            if store.isPro { dismiss() }
                        } catch {
                            purchasing = nil
                            self.error = error.localizedDescription
                        }
                    }
                } label: {
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(product.displayName)
                                .font(.geist(16, weight: .semibold))
                                .foregroundStyle(Color(.label))
                            Text(product.description)
                                .font(.geist(12, weight: .regular))
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        if purchasing == product.id {
                            ProgressView()
                        } else {
                            Text(product.displayPrice)
                                .font(.geist(16, weight: .bold))
                                .foregroundStyle(Color.accentColor)
                        }
                    }
                    .padding()
                    .background(Color.accentColor.opacity(0.08))
                    .clipShape(RoundedRectangle(cornerRadius: 14))
                }
                .buttonStyle(.plain)
            }
        }
    }

    private func oneTimeTile(_ product: Product) -> some View {
        Button {
            Task {
                do {
                    purchasing = product.id
                    _ = try await store.purchase(product)
                    purchasing = nil
                    if store.isPro { dismiss() }
                } catch {
                    purchasing = nil
                    self.error = error.localizedDescription
                }
            }
        } label: {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Lifetime supporter")
                        .font(.geist(16, weight: .semibold))
                        .foregroundStyle(Color(.label))
                    Text("One-time purchase, all Pro features forever")
                        .font(.geist(12, weight: .regular))
                        .foregroundStyle(.secondary)
                }
                Spacer()
                if purchasing == product.id {
                    ProgressView()
                } else {
                    Text(product.displayPrice)
                        .font(.geist(16, weight: .bold))
                        .foregroundStyle(Color.accentColor)
                }
            }
            .padding()
            .overlay(
                RoundedRectangle(cornerRadius: 14)
                    .stroke(Color.accentColor.opacity(0.5), lineWidth: 1.5)
            )
        }
        .buttonStyle(.plain)
    }

    private var comingSoon: some View {
        VStack(spacing: 8) {
            Text("Pro is launching soon.")
                .font(.geist(15, weight: .semibold))
            Text("Products will appear here once they're approved by App Review.")
                .font(.geist(12, weight: .regular))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .padding()
        .frame(maxWidth: .infinity)
        .background(Color(.secondarySystemBackground))
        .clipShape(RoundedRectangle(cornerRadius: 12))
    }

    private var legal: some View {
        VStack(spacing: 4) {
            Text("Subscriptions auto-renew unless cancelled at least 24 hours before the end of the period. Manage or cancel in your Apple ID settings.")
                .font(.geist(10, weight: .regular))
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
        }
        .padding(.top, 8)
    }
}
