import AppKit
import Foundation

guard CommandLine.arguments.count == 5,
      let pixels = Int(CommandLine.arguments[3]) else {
  fputs("usage: render_svg.swift input.svg output.png pixels opaque|alpha\n", stderr)
  exit(64)
}

let input = URL(fileURLWithPath: CommandLine.arguments[1])
let output = URL(fileURLWithPath: CommandLine.arguments[2])
let opaque = CommandLine.arguments[4] == "opaque"

guard let image = NSImage(contentsOf: input) else {
  fputs("could not load or allocate image\n", stderr)
  exit(65)
}

let alphaInfo: CGImageAlphaInfo = opaque ? .noneSkipLast : .premultipliedLast
guard let bitmap = CGContext(
  data: nil,
  width: pixels,
  height: pixels,
  bitsPerComponent: 8,
  bytesPerRow: pixels * 4,
  space: CGColorSpaceCreateDeviceRGB(),
  bitmapInfo: alphaInfo.rawValue
) else {
  fputs("could not allocate bitmap context\n", stderr)
  exit(65)
}

NSGraphicsContext.saveGraphicsState()
let context = NSGraphicsContext(cgContext: bitmap, flipped: false)
NSGraphicsContext.current = context
if opaque {
  NSColor(calibratedRed: 5 / 255, green: 7 / 255, blue: 10 / 255, alpha: 1).setFill()
  NSRect(x: 0, y: 0, width: pixels, height: pixels).fill()
} else {
  bitmap.clear(CGRect(x: 0, y: 0, width: pixels, height: pixels))
}
image.draw(
  in: NSRect(x: 0, y: 0, width: pixels, height: pixels),
  from: .zero,
  operation: .sourceOver,
  fraction: 1
)
context.cgContext.flush()
NSGraphicsContext.restoreGraphicsState()

guard let cgImage = bitmap.makeImage(),
      let png = NSBitmapImageRep(cgImage: cgImage).representation(using: .png, properties: [:])
else { exit(65) }
try png.write(to: output, options: .atomic)
