import LoopKitUI
import LoopKitUpdate
import SwiftUI

@MainActor
struct LoopKitUpdateView: View {
  @ObservedObject var model: LoopKitUpdateViewModel

  var body: some View {
    VStack(alignment: .leading, spacing: 0) {
      header
      Divider().overlay(LoopKitTheme.rim)
      content
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .padding(24)
      Divider().overlay(LoopKitTheme.rim)
      actions
        .padding(.horizontal, 24)
        .frame(height: 64)
    }
    .frame(width: 520, height: 430)
    .background(LoopKitTheme.background)
    .foregroundStyle(LoopKitTheme.text)
    .preferredColorScheme(.dark)
    .onChange(of: model.announcement) { _, announcement in
      guard let announcement else { return }
      AccessibilityNotification.Announcement(announcement.message).post()
    }
  }

  private var header: some View {
    HStack(spacing: 12) {
      Image(systemName: headerSymbol)
        .font(.system(size: 21, weight: .semibold))
        .foregroundStyle(headerColor)
        .frame(width: 32, height: 32)
        .background(headerColor.opacity(0.10))
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
      VStack(alignment: .leading, spacing: 2) {
        Text(headerTitle)
          .font(.system(size: 18, weight: .bold))
        Text("SOFTWARE UPDATE")
          .font(LoopKitTheme.mono(9, weight: .semibold))
          .tracking(1.2)
          .foregroundStyle(LoopKitTheme.secondaryText)
      }
      Spacer()
    }
    .padding(.horizontal, 24)
    .frame(height: 72)
    .background(LoopKitTheme.surface.opacity(0.96))
  }

  @ViewBuilder
  private var content: some View {
    switch model.presentation {
    case .checking:
      HStack(spacing: 12) {
        ProgressView()
          .controlSize(.small)
        Text("Checking GitHub for the latest LoopKit release…")
          .font(.callout)
          .foregroundStyle(LoopKitTheme.secondaryText)
      }
      .accessibilityElement(children: .combine)
      .accessibilityLabel("Checking for LoopKit updates")

    case .current(let installedVersion):
      VStack(alignment: .leading, spacing: 14) {
        Text("LoopKit is up to date")
          .font(.title3.weight(.semibold))
        versionRow("Installed version", installedVersion)
        Text("You have the latest eligible Community release.")
          .font(.callout)
          .foregroundStyle(LoopKitTheme.secondaryText)
      }

    case .available(let installedVersion, let release):
      availableContent(installedVersion: installedVersion, release: release)

    case .checkFailed(let message):
      VStack(alignment: .leading, spacing: 14) {
        Text("Couldn’t check for updates")
          .font(.title3.weight(.semibold))
        Text(message)
          .font(.callout)
          .foregroundStyle(LoopKitTheme.secondaryText)
        Text("No audio settings or routing were changed.")
          .font(.caption)
          .foregroundStyle(LoopKitTheme.secondaryText)
      }

    case .releaseOpenFailed(_, let message):
      VStack(alignment: .leading, spacing: 14) {
        Text("Couldn’t open the release page")
          .font(.title3.weight(.semibold))
        Text(message)
          .font(.callout)
          .foregroundStyle(LoopKitTheme.secondaryText)
        Text("The update is still available. No audio settings or routing were changed.")
          .font(.caption)
          .foregroundStyle(LoopKitTheme.secondaryText)
      }

    case nil:
      EmptyView()
    }
  }

  private func availableContent(
    installedVersion: String,
    release: GitHubRelease
  ) -> some View {
    VStack(alignment: .leading, spacing: 14) {
      HStack(spacing: 22) {
        versionRow("Installed", installedVersion)
        Image(systemName: "arrow.right")
          .foregroundStyle(LoopKitTheme.secondaryText)
        versionRow("Available", release.version?.description ?? release.tagName)
      }

      Text(release.name ?? "LoopKit \(release.version?.description ?? release.tagName)")
        .font(.title3.weight(.semibold))
        .lineLimit(2)
        .truncationMode(.tail)

      ScrollView {
        Text(release.notes?.nonEmpty ?? "Open the GitHub release page to review this update.")
          .font(.callout)
          .foregroundStyle(LoopKitTheme.secondaryText)
          .textSelection(.enabled)
          .frame(maxWidth: .infinity, alignment: .topLeading)
      }
      .frame(maxHeight: 190)

      Text("Community updates are downloaded and installed manually from GitHub.")
        .font(.caption)
        .foregroundStyle(LoopKitTheme.secondaryText)
    }
  }

  private func versionRow(_ title: String, _ version: String) -> some View {
    VStack(alignment: .leading, spacing: 3) {
      Text(title.uppercased())
        .font(LoopKitTheme.mono(8, weight: .semibold))
        .tracking(1)
        .foregroundStyle(LoopKitTheme.secondaryText)
      Text(version)
        .font(LoopKitTheme.mono(13, weight: .semibold))
        .foregroundStyle(LoopKitTheme.teal)
        .lineLimit(1)
        .truncationMode(.middle)
    }
  }

  @ViewBuilder
  private var actions: some View {
    HStack(spacing: 10) {
      Spacer()
      switch model.presentation {
      case .checking:
        EmptyView()
      case .current:
        Button("Close") { model.dismissPresentation() }
          .keyboardShortcut(.cancelAction)
      case .available(_, let release):
        Button("Later") { model.dismissPresentation() }
          .keyboardShortcut(.cancelAction)
        Button("View Release") { model.viewRelease(release) }
          .keyboardShortcut(.defaultAction)
      case .checkFailed:
        Button("Close") { model.dismissPresentation() }
          .keyboardShortcut(.cancelAction)
        Button("Try Again") { model.checkManually() }
          .keyboardShortcut(.defaultAction)
      case .releaseOpenFailed(let release, _):
        Button("Close") { model.dismissPresentation() }
          .keyboardShortcut(.cancelAction)
        Button("Try Again") { model.viewRelease(release) }
          .keyboardShortcut(.defaultAction)
      case nil:
        EmptyView()
      }
    }
  }

  private var headerTitle: String {
    switch model.presentation {
    case .checking: return "Checking for Updates"
    case .current: return "You’re Up to Date"
    case .available: return "Update Available"
    case .checkFailed: return "Update Check Failed"
    case .releaseOpenFailed: return "Release Page Failed"
    case nil: return "Software Update"
    }
  }

  private var headerSymbol: String {
    switch model.presentation {
    case .checking: return "arrow.triangle.2.circlepath"
    case .current: return "checkmark.circle.fill"
    case .available: return "arrow.down.circle.fill"
    case .checkFailed: return "wifi.exclamationmark"
    case .releaseOpenFailed: return "safari.fill"
    case nil: return "arrow.down.circle"
    }
  }

  private var headerColor: Color {
    switch model.presentation {
    case .checkFailed, .releaseOpenFailed:
      return LoopKitTheme.warning
    default:
      break
    }
    return LoopKitTheme.teal
  }
}

private extension String {
  var nonEmpty: String? { isEmpty ? nil : self }
}

#if DEBUG
#Preview("Update available") {
  LoopKitUpdateView(model: .previewAvailable())
}

#Preview("Current") {
  LoopKitUpdateView(model: .previewCurrent())
}

#Preview("Checking") {
  LoopKitUpdateView(model: .previewChecking())
}

#Preview("Failure") {
  LoopKitUpdateView(model: .previewFailure())
}
#endif
