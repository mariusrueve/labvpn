// Draws the labvpn app icon. Same pixels on every run: no randomness, no dates.
// Usage: swift scripts/make-icon.swift <output-dir>
//   writes <output-dir>/labvpn.iconset, AppIcon.icns and icon-512.png.
// Or:    swift scripts/make-icon.swift --check docs/images/icon.png
//   exits 1 if the committed picture no longer matches the code.
//
// All coordinates are on Apple's 1024-point icon grid, y pointing down.
// The shield is drawn here, not taken from SF Symbols, which aren't licensed
// for app icons.
import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

func color(_ hex: UInt32, _ alpha: CGFloat = 1) -> CGColor {
  let r = CGFloat((hex >> 16) & 0xFF) / 255
  let g = CGFloat((hex >> 8) & 0xFF) / 255
  let b = CGFloat(hex & 0xFF) / 255
  return CGColor(srgbRed: r, green: g, blue: b, alpha: alpha)
}

func gradient(_ stops: [(CGColor, CGFloat)]) -> CGGradient {
  CGGradient(
    colorsSpace: CGColorSpace(name: CGColorSpace.sRGB),
    colors: stops.map(\.0) as CFArray, locations: stops.map(\.1))!
}

/// The rounded square every macOS icon sits in: 824 points wide, centred.
func bodyPath() -> CGPath {
  CGPath(
    roundedRect: CGRect(x: 100, y: 100, width: 824, height: 824),
    cornerWidth: 185, cornerHeight: 185, transform: nil)
}

func shieldPath() -> CGPath {
  let path = CGMutablePath()
  path.move(to: CGPoint(x: 512, y: 236))
  path.addCurve(
    to: CGPoint(x: 724, y: 306), control1: CGPoint(x: 590, y: 292), control2: CGPoint(x: 668, y: 306))
  path.addLine(to: CGPoint(x: 724, y: 486))
  path.addCurve(
    to: CGPoint(x: 512, y: 806), control1: CGPoint(x: 724, y: 650), control2: CGPoint(x: 630, y: 752))
  path.addCurve(
    to: CGPoint(x: 300, y: 486), control1: CGPoint(x: 394, y: 752), control2: CGPoint(x: 300, y: 650))
  path.addLine(to: CGPoint(x: 300, y: 306))
  path.addCurve(
    to: CGPoint(x: 512, y: 236), control1: CGPoint(x: 356, y: 306), control2: CGPoint(x: 434, y: 292))
  path.closeSubpath()
  return path
}

/// Shadows ignore the context's transform, so they are given in device pixels:
/// scaled here, and negative y because device space points up.
func setShadow(_ context: CGContext, y: CGFloat, blur: CGFloat, color shadow: CGColor, scale: CGFloat) {
  context.setShadow(offset: CGSize(width: 0, height: -y * scale), blur: blur * scale, color: shadow)
}

func draw(in context: CGContext, scale: CGFloat) {
  // Body, with the soft drop shadow macOS icons have.
  context.saveGState()
  setShadow(context, y: 12, blur: 28, color: color(0x000000, 0.30), scale: scale)
  context.addPath(bodyPath())
  context.setFillColor(color(0x1D6FE0))
  context.fillPath()
  context.restoreGState()

  context.saveGState()
  context.addPath(bodyPath())
  context.clip()
  context.drawLinearGradient(
    gradient([(color(0x2F7BEA), 0), (color(0x1A8FD8), 0.5), (color(0x10B5A4), 1)]),
    start: CGPoint(x: 160, y: 100), end: CGPoint(x: 864, y: 924), options: [])
  // Light from above.
  context.drawLinearGradient(
    gradient([(color(0xFFFFFF, 0.22), 0), (color(0xFFFFFF, 0), 1)]),
    start: CGPoint(x: 512, y: 100), end: CGPoint(x: 512, y: 520), options: [])
  context.restoreGState()

  // A thin bright rim, so the edge reads on dark backgrounds.
  // Stroked at 8 and clipped to the body, so 4 points show inside.
  context.saveGState()
  context.addPath(bodyPath())
  context.clip()
  context.addPath(bodyPath())
  context.setStrokeColor(color(0xFFFFFF, 0.16))
  context.setLineWidth(8)
  context.strokePath()
  context.restoreGState()

  // Shield, white, lifted off the background.
  context.saveGState()
  setShadow(context, y: 14, blur: 30, color: color(0x062A55, 0.35), scale: scale)
  context.addPath(shieldPath())
  context.setFillColor(color(0xFFFFFF))
  context.fillPath()
  context.restoreGState()

  context.saveGState()
  context.addPath(shieldPath())
  context.clip()
  context.drawLinearGradient(
    gradient([(color(0xFFFFFF), 0), (color(0xE3EEFB), 1)]),
    start: CGPoint(x: 512, y: 236), end: CGPoint(x: 512, y: 806), options: [])
  // The right half a shade darker, like a facet catching less light.
  context.clip(to: CGRect(x: 512, y: 0, width: 512, height: 1024))
  context.setFillColor(color(0x0B3D7A, 0.07))
  context.fill(CGRect(x: 0, y: 0, width: 1024, height: 1024))
  context.restoreGState()
}

func render(pixels: Int) -> CGImage {
  let context = CGContext(
    data: nil, width: pixels, height: pixels, bitsPerComponent: 8, bytesPerRow: 0,
    space: CGColorSpace(name: CGColorSpace.sRGB)!,
    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
  let scale = CGFloat(pixels) / 1024
  // Flip so the drawing code can use y pointing down.
  context.translateBy(x: 0, y: CGFloat(pixels))
  context.scaleBy(x: scale, y: -scale)
  context.interpolationQuality = .high
  context.setShouldAntialias(true)
  draw(in: context, scale: scale)
  return context.makeImage()!
}

func writePNG(_ image: CGImage, to url: URL) {
  let destination = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil)!
  CGImageDestinationAddImage(destination, image, nil)
  guard CGImageDestinationFinalize(destination) else { fatalError("Cannot write \(url.path)") }
}

/// Compares a PNG with a fresh render. Another macOS version may smooth edges a
/// little differently, so small differences in a few pixels are allowed.
func check(_ path: String) -> Bool {
  guard let source = CGImageSourceCreateWithURL(URL(fileURLWithPath: path) as CFURL, nil),
    let committed = CGImageSourceCreateImageAtIndex(source, 0, nil),
    committed.width == 512, committed.height == 512
  else { return false }
  func bytes(_ image: CGImage) -> [UInt8] {
    var data = [UInt8](repeating: 0, count: 512 * 512 * 4)
    let context = CGContext(
      data: &data, width: 512, height: 512, bitsPerComponent: 8, bytesPerRow: 512 * 4,
      space: CGColorSpace(name: CGColorSpace.sRGB)!,
      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    context.draw(image, in: CGRect(x: 0, y: 0, width: 512, height: 512))
    return data
  }
  let a = bytes(committed), b = bytes(render(pixels: 512))
  var off = 0
  for i in stride(from: 0, to: a.count, by: 4) {
    let diff = (0..<4).map { abs(Int(a[i + $0]) - Int(b[i + $0])) }.max()!
    if diff > 24 { return false }
    if diff > 2 { off += 1 }
  }
  return off <= 512 * 512 / 100
}

let arguments = Array(CommandLine.arguments.dropFirst())
if arguments.count == 2, arguments[0] == "--check" {
  exit(check(arguments[1]) ? 0 : 1)
}
guard arguments.count == 1 else {
  FileHandle.standardError.write(Data("usage: make-icon.swift <output-dir> | --check <png>\n".utf8))
  exit(2)
}
let output = URL(fileURLWithPath: arguments[0])
let iconset = output.appending(path: "labvpn.iconset")
try? FileManager.default.removeItem(at: iconset)
try FileManager.default.createDirectory(at: iconset, withIntermediateDirectories: true)

for points in [16, 32, 128, 256, 512] {
  writePNG(render(pixels: points), to: iconset.appending(path: "icon_\(points)x\(points).png"))
  writePNG(render(pixels: points * 2), to: iconset.appending(path: "icon_\(points)x\(points)@2x.png"))
}
writePNG(render(pixels: 512), to: output.appending(path: "icon-512.png"))

let iconutil = Process()
iconutil.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
iconutil.arguments = ["-c", "icns", iconset.path, "-o", output.appending(path: "AppIcon.icns").path]
try iconutil.run()
iconutil.waitUntilExit()
exit(iconutil.terminationStatus)
