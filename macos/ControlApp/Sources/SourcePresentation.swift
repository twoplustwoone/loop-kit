import Foundation

enum SourcePresentation {
  static func symbol(for displayName: String) -> String {
    let name = displayName.lowercased()
    if containsAny(name, ["spotify", "music", "itunes", "vlc"]) {
      return "music.note"
    }
    if containsAny(name, ["safari", "chrome", "firefox", "browser", "arc", "edge"]) {
      return "globe"
    }
    if containsAny(name, ["discord", "slack", "teams", "whatsapp", "facetime"]) {
      return "bubble.left.and.bubble.right"
    }
    if containsAny(name, ["zoom", "meet", "webex"]) {
      return "video"
    }
    return "waveform"
  }

  private static func containsAny(_ value: String, _ candidates: [String]) -> Bool {
    candidates.contains(where: value.contains)
  }
}
