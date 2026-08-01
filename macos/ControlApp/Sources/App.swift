import AppKit
import SwiftUI

@main
@MainActor
struct LoopKitApp: App {
  @StateObject private var model: LoopKitViewModel
  @StateObject private var updateModel: LoopKitUpdateViewModel

  init() {
    _model = StateObject(wrappedValue: LoopKitViewModel())
    _updateModel = StateObject(wrappedValue: LoopKitUpdateViewModel())
  }

  var body: some Scene {
    Window("LoopKit", id: "dashboard") {
#if DEBUG
      if CommandLine.arguments.contains("--render-menu-controller") {
        MenuControllerSnapshotView()
      } else if CommandLine.arguments.contains("--render-dashboard") {
        DashboardSnapshotView()
      } else if CommandLine.arguments.contains("--demo-dashboard") {
        ContentView(
          model: .demoModel(),
          updateModel: .previewAvailable(),
          startsServices: false
        )
      } else {
        ContentView(
          model: model,
          updateModel: updateModel,
          startsServices: true,
          showsFirstRunSetup: true
        )
      }
#else
      ContentView(
        model: model,
        updateModel: updateModel,
        startsServices: true,
        showsFirstRunSetup: true
      )
#endif
    }
    .commands {
      LoopKitUpdateCommands(model: updateModel)
    }

    MenuBarExtra {
      MenuBarControllerView(model: model, updateModel: updateModel)
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
    ContentView(
      model: .demoModel(),
      updateModel: .previewAvailable(),
      startsServices: false
    )
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
    MenuBarControllerView(
      model: .demoModel(),
      updateModel: .previewAvailable(),
      startsServices: false
    )
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

@MainActor
private struct LoopKitUpdateCommands: Commands {
  @ObservedObject var model: LoopKitUpdateViewModel
  @Environment(\.openWindow) private var openWindow

  var body: some Commands {
    CommandGroup(after: .appInfo) {
      Button("Check for Updates…") {
        openWindow(id: "dashboard")
        NSApp.activate(ignoringOtherApps: true)
        model.checkManually()
      }
    }
  }
}
