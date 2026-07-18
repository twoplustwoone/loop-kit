import Foundation
import LoopKitIPC

private struct StoredSource: Codable {
  let id: String
  let displayName: String
  let gain: Double
  let mute: Bool
  let solo: Bool
  let enabled: Bool
}

private struct StoredRoute: Codable {
  let sourceID: String
  let destinationID: String
}

private struct StoredScene: Codable {
  let name: String
  let masterGain: Double
  let monitorDeviceUID: String
  let sources: [StoredSource]
  let capturedAppBundleIDs: [String]?
  let captureModePreference: String?
  let playbackPolicy: String?
  let routes: [StoredRoute]?
}

struct LoadedScene {
  let scene: LKXPCScene
  let capturedAppBundleIDs: [String]
  let captureModePreference: String?
  let playbackPolicy: String?
}

struct SceneStore {
  static var defaultFolder: URL {
    FileManager.default.homeDirectoryForCurrentUser
      .appendingPathComponent("Library")
      .appendingPathComponent("Application Support")
      .appendingPathComponent("LoopKit")
      .appendingPathComponent("scenes")
  }

  let folder: URL

  func write(
    _ scene: LKXPCScene,
    capturedAppBundleIDs: [String],
    captureModePreference: String,
    playbackPolicy: String
  ) throws {
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    let stored = StoredScene(
      name: scene.name,
      masterGain: scene.masterGain,
      monitorDeviceUID: scene.monitorDeviceUID,
      sources: scene.sources.map {
        StoredSource(
          id: $0.id,
          displayName: $0.displayName,
          gain: $0.gain,
          mute: $0.mute,
          solo: $0.solo,
          enabled: $0.enabled
        )
      },
      capturedAppBundleIDs: capturedAppBundleIDs,
      captureModePreference: captureModePreference,
      playbackPolicy: playbackPolicy,
      routes: scene.routes?.map {
        StoredRoute(sourceID: $0.sourceID, destinationID: $0.destinationID)
      }
    )
    let data = try JSONEncoder().encode(stored)
    try data.write(to: path(for: scene.name), options: .atomic)
  }

  func read(named name: String) throws -> LoadedScene {
    let data = try Data(contentsOf: path(for: name))
    let stored = try JSONDecoder().decode(StoredScene.self, from: data)
    let sources = stored.sources.map {
      LKXPCSourceState(
        id: $0.id,
        displayName: $0.displayName,
        gain: $0.gain,
        mute: $0.mute,
        solo: $0.solo,
        enabled: $0.enabled
      )
    }
    return LoadedScene(
      scene: LKXPCScene(
        name: stored.name,
        masterGain: stored.masterGain,
        monitorDeviceUID: stored.monitorDeviceUID,
        sources: sources,
        routes: stored.routes?.map {
          LKXPCRoute(sourceID: $0.sourceID, destinationID: $0.destinationID)
        }
      ),
      capturedAppBundleIDs: stored.capturedAppBundleIDs ?? [],
      captureModePreference: stored.captureModePreference,
      playbackPolicy: stored.playbackPolicy
    )
  }

  func listNames() -> [String] {
    guard let files = try? FileManager.default.contentsOfDirectory(atPath: folder.path) else {
      return []
    }
    return files
      .filter { $0.hasSuffix(".json") }
      .map { String($0.dropLast(5)) }
      .sorted()
  }

  private func path(for name: String) -> URL {
    let safeName = name.replacingOccurrences(of: "/", with: "_")
    return folder.appendingPathComponent("\(safeName).json")
  }
}
