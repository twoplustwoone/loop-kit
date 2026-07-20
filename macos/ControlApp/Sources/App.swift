import AppKit
import SwiftUI

@main
@MainActor
struct LoopKitApp: App {
  @StateObject private var model: LoopKitViewModel

  init() {
    _model = StateObject(wrappedValue: LoopKitViewModel())
  }

  var body: some Scene {
    WindowGroup("LoopKit", id: "dashboard") {
#if DEBUG
      if CommandLine.arguments.contains("--render-menu-controller") {
        MenuControllerSnapshotView()
      } else if CommandLine.arguments.contains("--render-dashboard") {
        DashboardSnapshotView()
      } else if CommandLine.arguments.contains("--demo-dashboard") {
        ContentView(model: .demoModel(), startsServices: false)
      } else {
        ContentView(model: model, startsServices: true, showsFirstRunSetup: true)
      }
#else
      ContentView(model: model, startsServices: true, showsFirstRunSetup: true)
#endif
    }

    MenuBarExtra {
      MenuBarControllerView(model: model)
    } label: {
      Image("LoopKitMenuTemplate")
        .renderingMode(.template)
        .accessibilityLabel("LoopKit")
    }
    .menuBarExtraStyle(.window)
  }
}

#if DEBUG
@MainActor
private struct DashboardSnapshotView: View {
  var body: some View {
    dashboard
      .task { renderSnapshot() }
  }

  private var dashboard: some View {
    ContentView(model: .demoModel(), startsServices: false)
      .frame(width: 1400, height: 900)
      .environment(\.colorScheme, .dark)
  }

  private func renderSnapshot() {
    writePNG(from: ImageRenderer(content: dashboard), to: "/tmp/loopkit-dashboard-render.png")
  }
}

@MainActor
private struct MenuControllerSnapshotView: View {
  var body: some View {
    controller
      .task { renderSnapshot() }
  }

  private var controller: some View {
    MenuBarControllerView(model: .demoModel(), startsServices: false)
      .environment(\.colorScheme, .dark)
  }

  private func renderSnapshot() {
    writePNG(from: ImageRenderer(content: controller), to: "/tmp/loopkit-menu-render.png")
  }
}

@MainActor
private func writePNG<Content: View>(from renderer: ImageRenderer<Content>, to path: String) {
  renderer.scale = 1
  guard
    let image = renderer.nsImage,
    let tiff = image.tiffRepresentation,
    let bitmap = NSBitmapImageRep(data: tiff),
    let png = bitmap.representation(using: .png, properties: [:])
  else {
    return
  }
  try? png.write(to: URL(fileURLWithPath: path), options: .atomic)
  DispatchQueue.main.async { NSApp.terminate(nil) }
}
#endif
