import SwiftUI

/// Soft-prompt banner. Non-blocking, slides in from the top.
/// Mirrors `ToastView`'s capsule + material styling so the visual
/// language stays consistent, but lives on its own — toasts auto-
/// dismiss, this one sticks until the user taps Update or Later.
struct UpdateBanner: View {
    let info: AppUpdateChecker.VersionInfo
    let onUpdate: () -> Void
    let onSnooze: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "arrow.down.circle.fill")
                .font(.system(size: 20, weight: .semibold))
                .foregroundStyle(Color.accentColor)
            VStack(alignment: .leading, spacing: 1) {
                Text("New version \(info.latestVersion)")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(Color(.label))
                if let notes = info.releaseNotes, !notes.isEmpty {
                    Text(notes)
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
            Spacer(minLength: 4)
            Button("Update", action: onUpdate)
                .font(.system(size: 13, weight: .semibold))
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
            Button {
                onSnooze()
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .padding(6)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background {
            if #available(iOS 26.0, *) {
                Capsule().fill(.clear).glassEffect(.regular, in: Capsule())
            } else {
                Capsule().fill(.ultraThinMaterial)
            }
        }
        .overlay(Capsule().stroke(Color.primary.opacity(0.08), lineWidth: 0.5))
        .shadow(color: .black.opacity(0.15), radius: 18, y: 8)
        .padding(.horizontal, 12)
        .padding(.top, 8)
    }
}

/// Force-update blocker. Shown as a full-screen cover so the user
/// can't dismiss past it — the BE has told us this client is too old
/// to talk to the API.
struct ForceUpdateView: View {
    let info: AppUpdateChecker.VersionInfo
    let onUpdate: () -> Void

    var body: some View {
        VStack(spacing: 20) {
            Spacer()
            Image(systemName: "arrow.up.circle.fill")
                .font(.system(size: 64, weight: .semibold))
                .foregroundStyle(Color.accentColor)
            Text("An update is required")
                .font(.title2.weight(.semibold))
                .multilineTextAlignment(.center)
            Text("Gitchat \(info.latestVersion) is available. Please update to keep using the app.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 24)
            if let notes = info.releaseNotes, !notes.isEmpty {
                ScrollView {
                    Text(notes)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.leading)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(14)
                }
                .frame(maxHeight: 180)
                .background(
                    RoundedRectangle(cornerRadius: 12).fill(Color(.secondarySystemBackground))
                )
                .padding(.horizontal, 24)
            }
            Spacer()
            Button(action: onUpdate) {
                Text("Update now")
                    .font(.system(size: 16, weight: .semibold))
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 14)
            }
            .buttonStyle(.borderedProminent)
            .padding(.horizontal, 24)
            .padding(.bottom, 24)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(.systemBackground).ignoresSafeArea())
        .interactiveDismissDisabled()
    }
}
