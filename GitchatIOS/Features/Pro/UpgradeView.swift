import SwiftUI
import StoreKit

struct UpgradeView: View {
    @StateObject private var store = StoreManager.shared
    @Environment(\.dismiss) private var dismiss
    @State private var purchasing: String?
    @State private var error: String?
    @State private var legalURL: URL?

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
            .sheet(item: Binding<URLIdentifiableIAP?>(
                get: { legalURL.map(URLIdentifiableIAP.init) },
                set: { legalURL = $0?.url }
            )) { wrapped in
                SafariSheet(url: wrapped.url).ignoresSafeArea()
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
                            Text(subscriptionLengthLabel(for: product))
                                .font(.geist(12, weight: .regular))
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        if purchasing == product.id {
                            ProgressView()
                        } else {
                            VStack(alignment: .trailing, spacing: 1) {
                                Text(product.displayPrice)
                                    .font(.geist(16, weight: .bold))
                                    .foregroundStyle(Color.accentColor)
                                Text(perPeriodLabel(for: product))
                                    .font(.geist(10, weight: .regular))
                                    .foregroundStyle(.secondary)
                            }
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

    private func subscriptionLengthLabel(for product: Product) -> String {
        guard let sub = product.subscription else { return product.description }
        switch sub.subscriptionPeriod.unit {
        case .day:   return "\(sub.subscriptionPeriod.value) day subscription"
        case .week:  return "\(sub.subscriptionPeriod.value) week subscription"
        case .month: return sub.subscriptionPeriod.value == 1 ? "Monthly subscription" : "\(sub.subscriptionPeriod.value) month subscription"
        case .year:  return sub.subscriptionPeriod.value == 1 ? "Yearly subscription" : "\(sub.subscriptionPeriod.value) year subscription"
        @unknown default: return product.description
        }
    }

    private func perPeriodLabel(for product: Product) -> String {
        guard let sub = product.subscription else { return "" }
        switch sub.subscriptionPeriod.unit {
        case .month: return "per month"
        case .year:  return "per year"
        case .week:  return "per week"
        case .day:   return "per day"
        @unknown default: return ""
        }
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
        VStack(spacing: 10) {
            Text("Subscriptions auto-renew at the end of each period unless cancelled at least 24 hours before the end of the current period. You can manage or cancel your subscription in your Apple ID account settings at any time. Payment will be charged to your Apple ID account at purchase confirmation.")
                .font(.geist(10, weight: .regular))
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)

            HStack(spacing: 16) {
                Button("Terms of Use") { legalURL = Config.termsURL }
                Text("·").foregroundStyle(.tertiary)
                Button("Privacy Policy") { legalURL = Config.privacyURL }
                Text("·").foregroundStyle(.tertiary)
                Button("EULA") { legalURL = Config.eulaURL }
            }
            .font(.geist(11, weight: .semibold))
            .foregroundStyle(Color.accentColor)
        }
        .padding(.top, 8)
        .padding(.horizontal, 8)
    }
}

private struct URLIdentifiableIAP: Identifiable {
    let url: URL
    var id: String { url.absoluteString }
}
