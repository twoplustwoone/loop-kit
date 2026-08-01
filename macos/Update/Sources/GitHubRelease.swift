import Foundation

public struct GitHubRelease: Codable, Equatable, Sendable {
  public let tagName: String
  public let releaseURL: URL
  public let name: String?
  public let notes: String?
  public let draft: Bool
  public let prerelease: Bool

  public init(
    tagName: String,
    releaseURL: URL,
    name: String? = nil,
    notes: String? = nil,
    draft: Bool = false,
    prerelease: Bool = false
  ) {
    self.tagName = tagName
    self.releaseURL = releaseURL
    self.name = name
    self.notes = notes
    self.draft = draft
    self.prerelease = prerelease
  }

  public var version: LoopKitVersion? {
    LoopKitVersion(tagName)
  }

  public var isEligible: Bool {
    let expectedPath = "/twoplustwoone/loop-kit/releases/tag/\(tagName)"
    return !draft
      && !prerelease
      && version?.isPrerelease == false
      && releaseURL.scheme?.lowercased() == "https"
      && releaseURL.host?.lowercased() == "github.com"
      && releaseURL.user == nil
      && releaseURL.password == nil
      && releaseURL.port == nil
      && releaseURL.path == expectedPath
      && releaseURL.query == nil
      && releaseURL.fragment == nil
  }

  private enum CodingKeys: String, CodingKey {
    case tagName = "tag_name"
    case releaseURL = "html_url"
    case name
    case notes = "body"
    case draft
    case prerelease
  }
}
