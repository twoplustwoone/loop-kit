import Foundation
import LoopKitIPC

struct RouteKey: Hashable, Comparable {
  let sourceID: String
  let destinationID: String

  static func < (lhs: RouteKey, rhs: RouteKey) -> Bool {
    if lhs.sourceID != rhs.sourceID { return lhs.sourceID < rhs.sourceID }
    return lhs.destinationID < rhs.destinationID
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
  private(set) var routes: Set<RouteKey> = []
  private(set) var sourceIDs: Set<String> = []

  static let destinationIDs: Set<String> = [
    LKRouteDestinationMonitor,
    LKRouteDestinationBroadcast,
  ]

  mutating func reconcile(sourceIDs nextSourceIDs: Set<String>) {
    let addedSourceIDs = nextSourceIDs.subtracting(sourceIDs)
    routes = routes.filter { nextSourceIDs.contains($0.sourceID) }
    for sourceID in addedSourceIDs {
      for destinationID in Self.destinationIDs {
        routes.insert(RouteKey(sourceID: sourceID, destinationID: destinationID))
      }
    }
    sourceIDs = nextSourceIDs
  }

  mutating func replace(with routeDTOs: [LKXPCRoute]) throws {
    var replacement: Set<RouteKey> = []
    for route in routeDTOs {
      guard sourceIDs.contains(route.sourceID) else {
        throw RouteTableError.unknownSource(route.sourceID)
      }
      guard Self.destinationIDs.contains(route.destinationID) else {
        throw RouteTableError.unknownDestination(route.destinationID)
      }
      replacement.insert(RouteKey(sourceID: route.sourceID, destinationID: route.destinationID))
    }
    routes = replacement
  }

  mutating func restore(_ routeDTOs: [LKXPCRoute]?, sourceIDs: Set<String>) {
    self.sourceIDs = sourceIDs
    if let routeDTOs {
      routes = Set(routeDTOs.compactMap { route in
        guard sourceIDs.contains(route.sourceID), Self.destinationIDs.contains(route.destinationID) else {
          return nil
        }
        return RouteKey(sourceID: route.sourceID, destinationID: route.destinationID)
      })
    } else {
      routes = Set(sourceIDs.flatMap { sourceID in
        Self.destinationIDs.map { RouteKey(sourceID: sourceID, destinationID: $0) }
      })
    }
  }

  func contains(sourceID: String, destinationID: String) -> Bool {
    routes.contains(RouteKey(sourceID: sourceID, destinationID: destinationID))
  }

  func xpcRoutes() -> [LKXPCRoute] {
    routes.sorted().map { LKXPCRoute(sourceID: $0.sourceID, destinationID: $0.destinationID) }
  }
}
