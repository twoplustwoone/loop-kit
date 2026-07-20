import Foundation
import LoopKitIPC

struct SourceID: RawRepresentable, Codable, Hashable, Comparable {
  static let microphone = SourceID(rawValue: "mic")
  static let applicationPrefix = "app:"

  let rawValue: String

  init(rawValue: String) {
    self.rawValue = rawValue
  }

  init(applicationBundleID: String) {
    rawValue = "\(Self.applicationPrefix)\(applicationBundleID)"
  }

  var applicationBundleID: String? {
    guard rawValue.hasPrefix(Self.applicationPrefix) else { return nil }
    return String(rawValue.dropFirst(Self.applicationPrefix.count))
  }

  static func < (lhs: SourceID, rhs: SourceID) -> Bool {
    lhs.rawValue < rhs.rawValue
  }
}

enum RouteDestination: String, Codable, CaseIterable, Comparable {
  case monitor
  case broadcast

  static func < (lhs: RouteDestination, rhs: RouteDestination) -> Bool {
    lhs.rawValue < rhs.rawValue
  }
}

struct Route: Codable, Hashable, Comparable {
  let source: SourceID
  let destination: RouteDestination

  static func < (lhs: Route, rhs: Route) -> Bool {
    lhs.source != rhs.source ? lhs.source < rhs.source : lhs.destination < rhs.destination
  }
}

enum RouteTableError: LocalizedError {
  case unknownSource(String)
  case unknownDestination(String)

  var errorDescription: String? {
    switch self {
    case .unknownSource(let sourceID):
      return "Unknown route source \(sourceID)"
    case .unknownDestination(let destinationID):
      return "Unknown route destination \(destinationID)"
    }
  }
}

struct RouteTable {
  private(set) var routes: Set<Route> = []
  private(set) var sourceIDs: Set<SourceID> = []

  mutating func reconcile(
    sourceIDs nextSourceIDs: Set<SourceID>,
    defaults: (SourceID) -> Set<RouteDestination> = { _ in Set(RouteDestination.allCases) }
  ) {
    let addedSourceIDs = nextSourceIDs.subtracting(sourceIDs)
    routes = routes.filter { nextSourceIDs.contains($0.source) }
    for sourceID in addedSourceIDs {
      for destination in defaults(sourceID) {
        routes.insert(Route(source: sourceID, destination: destination))
      }
    }
    sourceIDs = nextSourceIDs
  }

  mutating func replace(with routeDTOs: [LKXPCRoute]) throws {
    var replacement: Set<Route> = []
    for routeDTO in routeDTOs {
      let source = SourceID(rawValue: routeDTO.sourceID)
      guard sourceIDs.contains(source) else {
        throw RouteTableError.unknownSource(routeDTO.sourceID)
      }
      guard let destination = RouteDestination(rawValue: routeDTO.destinationID) else {
        throw RouteTableError.unknownDestination(routeDTO.destinationID)
      }
      replacement.insert(Route(source: source, destination: destination))
    }
    routes = replacement
  }

  mutating func restore(_ routeDTOs: [LKXPCRoute]?, sourceIDs: Set<SourceID>) {
    self.sourceIDs = sourceIDs
    if let routeDTOs {
      routes = Set(routeDTOs.compactMap { routeDTO in
        let source = SourceID(rawValue: routeDTO.sourceID)
        guard sourceIDs.contains(source),
              let destination = RouteDestination(rawValue: routeDTO.destinationID)
        else { return nil }
        return Route(source: source, destination: destination)
      })
    } else {
      routes = Set(sourceIDs.flatMap { sourceID in
        RouteDestination.allCases.map { Route(source: sourceID, destination: $0) }
      })
    }
  }

  func contains(source: SourceID, destination: RouteDestination) -> Bool {
    routes.contains(Route(source: source, destination: destination))
  }

  func xpcRoutes() -> [LKXPCRoute] {
    routes.sorted().map {
      LKXPCRoute(sourceID: $0.source.rawValue, destinationID: $0.destination.rawValue)
    }
  }
}
