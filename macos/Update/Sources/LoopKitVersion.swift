import Foundation

public struct LoopKitVersion: Comparable, Codable, Hashable, Sendable, CustomStringConvertible {
  private enum PrereleaseIdentifier: Codable, Hashable, Sendable {
    case numeric(Int)
    case text(String)
  }

  public let major: Int
  public let minor: Int
  public let patch: Int
  private let prerelease: [PrereleaseIdentifier]

  public init?(_ rawValue: String) {
    var value = rawValue
    if value.hasPrefix("v") {
      value.removeFirst()
    }

    let metadataParts = value.split(separator: "+", omittingEmptySubsequences: false)
    guard metadataParts.count <= 2 else { return nil }
    if metadataParts.count == 2 {
      guard Self.identifiersAreValid(String(metadataParts[1]), allowLeadingZeroes: true) else {
        return nil
      }
    }

    let versionParts = metadataParts[0].split(separator: "-", maxSplits: 1, omittingEmptySubsequences: false)
    let coreParts = versionParts[0].split(separator: ".", omittingEmptySubsequences: false)
    guard coreParts.count == 3,
          let major = Self.parseCoreNumber(coreParts[0]),
          let minor = Self.parseCoreNumber(coreParts[1]),
          let patch = Self.parseCoreNumber(coreParts[2])
    else {
      return nil
    }

    var prerelease: [PrereleaseIdentifier] = []
    if versionParts.count == 2 {
      let rawPrerelease = String(versionParts[1])
      guard Self.identifiersAreValid(rawPrerelease, allowLeadingZeroes: false) else { return nil }
      prerelease = rawPrerelease.split(separator: ".").map { identifier in
        if let number = Int(identifier) {
          return .numeric(number)
        }
        return .text(String(identifier))
      }
    }

    self.major = major
    self.minor = minor
    self.patch = patch
    self.prerelease = prerelease
  }

  public var description: String {
    var value = "\(major).\(minor).\(patch)"
    if !prerelease.isEmpty {
      let suffix = prerelease.map { identifier in
        switch identifier {
        case .numeric(let number): return String(number)
        case .text(let text): return text
        }
      }.joined(separator: ".")
      value += "-\(suffix)"
    }
    return value
  }

  public var isPrerelease: Bool {
    !prerelease.isEmpty
  }

  public static func == (lhs: Self, rhs: Self) -> Bool {
    lhs.major == rhs.major
      && lhs.minor == rhs.minor
      && lhs.patch == rhs.patch
      && lhs.prerelease == rhs.prerelease
  }

  public static func < (lhs: Self, rhs: Self) -> Bool {
    let lhsCore = [lhs.major, lhs.minor, lhs.patch]
    let rhsCore = [rhs.major, rhs.minor, rhs.patch]
    if lhsCore != rhsCore {
      return lhsCore.lexicographicallyPrecedes(rhsCore)
    }

    if lhs.prerelease.isEmpty { return false }
    if rhs.prerelease.isEmpty { return true }

    for (left, right) in zip(lhs.prerelease, rhs.prerelease) {
      if left == right { continue }
      switch (left, right) {
      case (.numeric(let lhsNumber), .numeric(let rhsNumber)):
        return lhsNumber < rhsNumber
      case (.numeric, .text):
        return true
      case (.text, .numeric):
        return false
      case (.text(let lhsText), .text(let rhsText)):
        return lhsText < rhsText
      }
    }
    return lhs.prerelease.count < rhs.prerelease.count
  }

  private static func parseCoreNumber(_ value: Substring) -> Int? {
    guard !value.isEmpty,
          value.allSatisfy({ $0.isASCII && $0.isNumber }),
          value == "0" || !value.hasPrefix("0")
    else {
      return nil
    }
    return Int(value)
  }

  private static func identifiersAreValid(
    _ value: String,
    allowLeadingZeroes: Bool
  ) -> Bool {
    let identifiers = value.split(separator: ".", omittingEmptySubsequences: false)
    guard !identifiers.isEmpty else { return false }
    return identifiers.allSatisfy { identifier in
      guard !identifier.isEmpty,
            identifier.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-") })
      else {
        return false
      }
      if !allowLeadingZeroes,
         identifier.allSatisfy(\.isNumber),
         identifier.count > 1,
         identifier.hasPrefix("0") {
        return false
      }
      return true
    }
  }
}
