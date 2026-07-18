import SwiftUI

public enum LoopKitTheme {
  public static let background = Color(red: 0.043, green: 0.047, blue: 0.063)
  public static let surface = Color(red: 0.071, green: 0.075, blue: 0.090)
  public static let panel = Color(red: 0.105, green: 0.133, blue: 0.169)
  public static let panelHigh = Color(red: 0.161, green: 0.165, blue: 0.180)
  public static let track = Color(red: 0.051, green: 0.055, blue: 0.071)
  public static let teal = Color(red: 0.400, green: 0.988, blue: 0.945)
  public static let signal = Color(red: 0.271, green: 0.635, blue: 0.620)
  public static let warning = Color(red: 0.961, green: 0.816, blue: 0.259)
  public static let error = Color(red: 1.000, green: 0.420, blue: 0.420)
  public static let text = Color(red: 0.890, green: 0.886, blue: 0.910)
  public static let secondaryText = Color(red: 0.729, green: 0.792, blue: 0.780)
  public static let rim = Color.white.opacity(0.08)

  public static let panelRadius: CGFloat = 12

  public static func mono(_ size: CGFloat, weight: Font.Weight = .regular) -> Font {
    .system(size: size, weight: weight, design: .monospaced)
  }
}

public struct LoopKitPanel<Content: View>: View {
  private let content: Content

  public init(@ViewBuilder content: () -> Content) {
    self.content = content()
  }

  public var body: some View {
    content
      .background(.ultraThinMaterial.opacity(0.35))
      .background(LoopKitTheme.panel.opacity(0.82))
      .clipShape(RoundedRectangle(cornerRadius: LoopKitTheme.panelRadius, style: .continuous))
      .overlay {
        RoundedRectangle(cornerRadius: LoopKitTheme.panelRadius, style: .continuous)
          .stroke(LoopKitTheme.rim, lineWidth: 1)
      }
  }
}

public struct LoopKitSectionLabel: View {
  private let title: String
  private let subtitle: String?

  public init(_ title: String, subtitle: String? = nil) {
    self.title = title
    self.subtitle = subtitle
  }

  public var body: some View {
    VStack(alignment: .leading, spacing: 2) {
      Text(title)
        .font(.system(size: 16, weight: .semibold))
        .foregroundStyle(LoopKitTheme.text)
      if let subtitle {
        Text(subtitle.uppercased())
          .font(LoopKitTheme.mono(10, weight: .medium))
          .tracking(1.4)
          .foregroundStyle(LoopKitTheme.secondaryText)
      }
    }
  }
}

public struct LoopKitStatusPill: View {
  private let text: String
  private let color: Color

  public init(_ text: String, color: Color = LoopKitTheme.teal) {
    self.text = text
    self.color = color
  }

  public var body: some View {
    Text(text)
      .font(LoopKitTheme.mono(11, weight: .medium))
      .foregroundStyle(color)
      .padding(.horizontal, 9)
      .padding(.vertical, 5)
      .background(color.opacity(0.10))
      .clipShape(RoundedRectangle(cornerRadius: 5, style: .continuous))
      .overlay {
        RoundedRectangle(cornerRadius: 5, style: .continuous)
          .stroke(color.opacity(0.22), lineWidth: 1)
      }
  }
}
