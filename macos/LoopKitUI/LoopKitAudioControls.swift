import SwiftUI

public struct LoopKitStereoMeter: View {
  private let left: Double
  private let right: Double
  private let isVertical: Bool

  public init(left: Double, right: Double, isVertical: Bool = false) {
    self.left = left
    self.right = right
    self.isVertical = isVertical
  }

  public var body: some View {
    GeometryReader { proxy in
      if isVertical {
        HStack(alignment: .bottom, spacing: 3) {
          verticalLane(level: left, size: proxy.size)
          verticalLane(level: right, size: proxy.size)
        }
      } else {
        VStack(spacing: 3) {
          horizontalLane(level: left, size: proxy.size)
          horizontalLane(level: right, size: proxy.size)
        }
      }
    }
    .accessibilityElement(children: .ignore)
    .accessibilityLabel("Stereo level")
    .accessibilityValue("Left \(Int(clamped(left) * 100)) percent, right \(Int(clamped(right) * 100)) percent")
  }

  private func horizontalLane(level: Double, size: CGSize) -> some View {
    ZStack(alignment: .leading) {
      RoundedRectangle(cornerRadius: 2).fill(LoopKitTheme.track)
      RoundedRectangle(cornerRadius: 2)
        .fill(meterColor(level))
        .frame(width: max(2, size.width * clamped(level)))
    }
  }

  private func verticalLane(level: Double, size: CGSize) -> some View {
    ZStack(alignment: .bottom) {
      RoundedRectangle(cornerRadius: 2).fill(LoopKitTheme.track)
      RoundedRectangle(cornerRadius: 2)
        .fill(
          LinearGradient(
            colors: [LoopKitTheme.signal, LoopKitTheme.teal, LoopKitTheme.warning, LoopKitTheme.error],
            startPoint: .bottom,
            endPoint: .top
          )
        )
        .frame(height: max(2, size.height * clamped(level)))
    }
  }

  private func clamped(_ value: Double) -> Double {
    max(0, min(1, value))
  }

  private func meterColor(_ value: Double) -> Color {
    if value >= 0.95 { return LoopKitTheme.error }
    if value >= 0.75 { return LoopKitTheme.warning }
    return LoopKitTheme.teal
  }
}

public struct LoopKitVerticalFader: View {
  @Binding private var value: Double
  private let range: ClosedRange<Double>
  private let onEditingChanged: (Bool) -> Void

  public init(
    value: Binding<Double>,
    in range: ClosedRange<Double> = 0...2,
    onEditingChanged: @escaping (Bool) -> Void = { _ in }
  ) {
    _value = value
    self.range = range
    self.onEditingChanged = onEditingChanged
  }

  public var body: some View {
    GeometryReader { proxy in
      let travel = max(1, proxy.size.height - 24)
      let progress = (value - range.lowerBound) / (range.upperBound - range.lowerBound)
      let y = travel * (1 - max(0, min(1, progress)))

      ZStack(alignment: .top) {
        Capsule()
          .fill(LoopKitTheme.track)
          .frame(width: 34)
          .overlay { Capsule().stroke(LoopKitTheme.rim, lineWidth: 1) }

        Capsule()
          .fill(LoopKitTheme.teal.opacity(0.18))
          .frame(width: 30, height: travel * max(0, min(1, progress)))
          .frame(maxHeight: .infinity, alignment: .bottom)
          .padding(.bottom, 12)

        RoundedRectangle(cornerRadius: 5, style: .continuous)
          .fill(
            LinearGradient(
              colors: [Color(white: 0.36), Color(white: 0.18)],
              startPoint: .top,
              endPoint: .bottom
            )
          )
          .frame(width: 48, height: 24)
          .overlay(alignment: .center) {
            VStack(spacing: 3) {
              Rectangle().fill(Color.white.opacity(0.16)).frame(height: 1)
              Rectangle().fill(Color.black.opacity(0.30)).frame(height: 1)
            }
            .padding(.horizontal, 8)
          }
          .shadow(color: LoopKitTheme.teal.opacity(0.18), radius: 8)
          .offset(y: y)
      }
      .frame(maxWidth: .infinity)
      .contentShape(Rectangle())
      .gesture(
        DragGesture(minimumDistance: 0)
          .onChanged { gesture in
            onEditingChanged(true)
            let normalized = 1 - max(0, min(1, gesture.location.y / proxy.size.height))
            value = range.lowerBound + normalized * (range.upperBound - range.lowerBound)
          }
          .onEnded { _ in onEditingChanged(false) }
      )
    }
    .accessibilityElement()
    .accessibilityLabel("Gain")
    .accessibilityValue(String(format: "%.2f times", value))
    .accessibilityAdjustableAction { direction in
      let step = (range.upperBound - range.lowerBound) / 100
      switch direction {
      case .increment: value = min(range.upperBound, value + step)
      case .decrement: value = max(range.lowerBound, value - step)
      @unknown default: break
      }
    }
  }
}

public struct LoopKitHorizontalFader: View {
  @Binding private var value: Double
  private let range: ClosedRange<Double>
  private let onEditingChanged: (Bool) -> Void

  public init(
    value: Binding<Double>,
    in range: ClosedRange<Double> = 0...2,
    onEditingChanged: @escaping (Bool) -> Void = { _ in }
  ) {
    _value = value
    self.range = range
    self.onEditingChanged = onEditingChanged
  }

  public var body: some View {
    GeometryReader { proxy in
      let normalized = (value - range.lowerBound) / (range.upperBound - range.lowerBound)
      let progress = max(0, min(1, normalized))
      let travel = max(1, proxy.size.width - 16)

      ZStack(alignment: .leading) {
        Capsule().fill(LoopKitTheme.track).frame(height: 7)
        Capsule().fill(LoopKitTheme.signal).frame(width: max(4, travel * progress), height: 7)
        RoundedRectangle(cornerRadius: 3, style: .continuous)
          .fill(LoopKitTheme.text)
          .frame(width: 16, height: 24)
          .overlay { RoundedRectangle(cornerRadius: 3).stroke(Color.black.opacity(0.35), lineWidth: 1) }
          .offset(x: travel * progress)
      }
      .frame(maxHeight: .infinity)
      .contentShape(Rectangle())
      .gesture(
        DragGesture(minimumDistance: 0)
          .onChanged { gesture in
            onEditingChanged(true)
            let progress = max(0, min(1, gesture.location.x / proxy.size.width))
            value = range.lowerBound + progress * (range.upperBound - range.lowerBound)
          }
          .onEnded { _ in onEditingChanged(false) }
      )
    }
    .frame(height: 28)
    .accessibilityElement()
    .accessibilityLabel("Gain")
    .accessibilityValue(String(format: "%.2f times", value))
  }
}

public struct LoopKitSourceStrip: View {
  private let name: String
  private let icon: String
  @Binding private var gain: Double
  @Binding private var isMuted: Bool
  @Binding private var isSolo: Bool
  @Binding private var isEnabled: Bool
  private let peakLeft: Double
  private let peakRight: Double
  private let onEditingChanged: (Bool) -> Void

  public init(
    name: String,
    icon: String,
    gain: Binding<Double>,
    isMuted: Binding<Bool>,
    isSolo: Binding<Bool>,
    isEnabled: Binding<Bool>,
    peakLeft: Double,
    peakRight: Double,
    onEditingChanged: @escaping (Bool) -> Void = { _ in }
  ) {
    self.name = name
    self.icon = icon
    _gain = gain
    _isMuted = isMuted
    _isSolo = isSolo
    _isEnabled = isEnabled
    self.peakLeft = peakLeft
    self.peakRight = peakRight
    self.onEditingChanged = onEditingChanged
  }

  public var body: some View {
    LoopKitPanel {
      VStack(spacing: 8) {
        HStack(spacing: 6) {
          Image(systemName: icon)
            .foregroundStyle(isEnabled ? LoopKitTheme.teal : LoopKitTheme.secondaryText)
          Text(name.uppercased())
            .font(LoopKitTheme.mono(10, weight: .semibold))
            .lineLimit(1)
          Spacer(minLength: 0)
          Button { isEnabled.toggle() } label: {
            Image(systemName: isEnabled ? "power.circle.fill" : "power.circle")
          }
          .buttonStyle(.plain)
          .foregroundStyle(isEnabled ? LoopKitTheme.teal : LoopKitTheme.secondaryText)
        }

        HStack(spacing: 6) {
          stateButton("S", active: isSolo, activeColor: Color(red: 0.80, green: 1.0, blue: 0)) {
            isSolo.toggle()
          }
          stateButton("M", active: isMuted, activeColor: LoopKitTheme.error) {
            isMuted.toggle()
          }
        }

        ZStack {
          LoopKitStereoMeter(left: peakLeft, right: peakRight, isVertical: true)
            .frame(width: 30)
            .opacity(isEnabled ? 0.82 : 0.20)
          LoopKitVerticalFader(value: $gain, onEditingChanged: onEditingChanged)
            .frame(width: 56)
        }
        .frame(height: 130)

        VStack(spacing: 1) {
          Text(String(format: "%.2fx", gain))
            .font(LoopKitTheme.mono(11, weight: .medium))
            .foregroundStyle(LoopKitTheme.teal)
          Text("GAIN")
            .font(LoopKitTheme.mono(8, weight: .medium))
            .tracking(1.2)
            .foregroundStyle(LoopKitTheme.secondaryText)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 6)
        .background(LoopKitTheme.track.opacity(0.75))
        .clipShape(RoundedRectangle(cornerRadius: 5, style: .continuous))
      }
      .padding(10)
    }
    .frame(width: 120)
  }

  private func stateButton(_ title: String, active: Bool, activeColor: Color, action: @escaping () -> Void) -> some View {
    Button(action: action) {
      Text(title)
        .font(LoopKitTheme.mono(11, weight: .bold))
        .frame(maxWidth: .infinity)
        .frame(height: 26)
        .background(active ? activeColor : LoopKitTheme.panelHigh)
        .foregroundStyle(active ? Color.black : LoopKitTheme.secondaryText)
        .clipShape(RoundedRectangle(cornerRadius: 4, style: .continuous))
        .overlay {
          RoundedRectangle(cornerRadius: 4, style: .continuous)
            .stroke(LoopKitTheme.rim, lineWidth: 1)
        }
    }
    .buttonStyle(.plain)
  }
}
