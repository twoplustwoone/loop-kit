import Foundation

struct SessionSourceState: Codable, Equatable {
  let id: String
  let displayName: String
  let gain: Double
  let mute: Bool
  let solo: Bool
  let enabled: Bool
}

struct SessionRoute: Codable, Equatable {
  let sourceID: String
  let destinationID: String
}

struct LoopKitSessionState: Codable, Equatable {
  static let currentSchemaVersion = 1

  let schemaVersion: Int
  let masterGain: Double
  let sources: [SessionSourceState]
  let selectedApplicationBundleIDs: [String]
  let routes: [SessionRoute]
  let monitorDeviceUID: String
  let inputDeviceUID: String
  let echoRiskAcknowledgements: [String]

  init(
    schemaVersion: Int = currentSchemaVersion,
    masterGain: Double,
    sources: [SessionSourceState],
    selectedApplicationBundleIDs: [String],
    routes: [SessionRoute],
    monitorDeviceUID: String,
    inputDeviceUID: String,
    echoRiskAcknowledgements: [String]
  ) {
    self.schemaVersion = schemaVersion
    self.masterGain = masterGain
    self.sources = sources
    self.selectedApplicationBundleIDs = selectedApplicationBundleIDs
    self.routes = routes
    self.monitorDeviceUID = monitorDeviceUID
    self.inputDeviceUID = inputDeviceUID
    self.echoRiskAcknowledgements = echoRiskAcknowledgements
  }
}

enum SessionStoreError: LocalizedError {
  case unsupportedSchema(Int)

  var errorDescription: String? {
    switch self {
    case .unsupportedSchema(let version):
      return "Unsupported LoopKit session schema version \(version)"
    }
  }
}

struct SessionStore {
  static var defaultFile: URL {
    FileManager.default.homeDirectoryForCurrentUser
      .appendingPathComponent("Library")
      .appendingPathComponent("Application Support")
      .appendingPathComponent("LoopKit")
      .appendingPathComponent("state.json")
  }

  let file: URL

  func write(_ state: LoopKitSessionState) throws {
    try FileManager.default.createDirectory(
      at: file.deletingLastPathComponent(),
      withIntermediateDirectories: true
    )
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    let data = try encoder.encode(state)
    try data.write(to: file, options: [.atomic])
  }

  func read() throws -> LoopKitSessionState? {
    guard FileManager.default.fileExists(atPath: file.path) else { return nil }
    let state = try JSONDecoder().decode(LoopKitSessionState.self, from: Data(contentsOf: file))
    guard state.schemaVersion == LoopKitSessionState.currentSchemaVersion else {
      throw SessionStoreError.unsupportedSchema(state.schemaVersion)
    }
    return state
  }

  @discardableResult
  func quarantineCorruptFile(now: Date = Date()) throws -> URL? {
    guard FileManager.default.fileExists(atPath: file.path) else { return nil }
    let formatter = ISO8601DateFormatter()
    let stamp = formatter.string(from: now)
      .replacingOccurrences(of: ":", with: "-")
    let destination = file.deletingLastPathComponent()
      .appendingPathComponent("state.corrupt-\(stamp).json")
    try FileManager.default.moveItem(at: file, to: destination)
    return destination
  }
}

final class DebouncedSessionWriter {
  private let queue: DispatchQueue
  private let delay: DispatchTimeInterval
  private let write: (LoopKitSessionState) -> Void
  private var pending: DispatchWorkItem?

  init(
    queue: DispatchQueue,
    delay: DispatchTimeInterval = .milliseconds(250),
    write: @escaping (LoopKitSessionState) -> Void
  ) {
    self.queue = queue
    self.delay = delay
    self.write = write
  }

  func schedule(_ state: LoopKitSessionState) {
    pending?.cancel()
    let item = DispatchWorkItem { [write] in write(state) }
    pending = item
    queue.asyncAfter(deadline: .now() + delay, execute: item)
  }

  func cancel() {
    pending?.cancel()
    pending = nil
  }
}
