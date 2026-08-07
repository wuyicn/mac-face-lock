import AppKit
import CoreGraphics
import Foundation

guard CommandLine.arguments.count == 2 else {
    fputs("usage: generate-app-icon.swift OUTPUT.png\n", stderr)
    exit(64)
}

let outputURL = URL(fileURLWithPath: CommandLine.arguments[1])
let pixels = 1024
let colorSpace = CGColorSpace(name: CGColorSpace.sRGB)!
let bitmapInfo = CGBitmapInfo.byteOrder32Big.rawValue
    | CGImageAlphaInfo.premultipliedLast.rawValue
guard let bitmapContext = CGContext(
    data: nil,
    width: pixels,
    height: pixels,
    bitsPerComponent: 8,
    bytesPerRow: 0,
    space: colorSpace,
    bitmapInfo: bitmapInfo
) else {
    fputs("unable to create bitmap context\n", stderr)
    exit(1)
}
bitmapContext.clear(CGRect(x: 0, y: 0, width: pixels, height: pixels))
let previousContext = NSGraphicsContext.current
NSGraphicsContext.current = NSGraphicsContext(cgContext: bitmapContext, flipped: false)

NSGraphicsContext.current?.imageInterpolation = .high
NSColor.clear.setFill()
NSRect(x: 0, y: 0, width: pixels, height: pixels).fill()

let tile = NSBezierPath(
    roundedRect: NSRect(x: 72, y: 72, width: 880, height: 880),
    xRadius: 210,
    yRadius: 210
)
NSGradient(
    starting: NSColor(calibratedRed: 0.96, green: 0.99, blue: 1.00, alpha: 1),
    ending: NSColor(calibratedRed: 0.78, green: 0.90, blue: 1.00, alpha: 1)
)!.draw(in: tile, angle: -55)

func stroke(_ path: NSBezierPath, color: NSColor, width: CGFloat) {
    color.setStroke()
    path.lineWidth = width
    path.lineCapStyle = .round
    path.lineJoinStyle = .round
    path.stroke()
}

let blue = NSColor(calibratedRed: 0.20, green: 0.48, blue: 0.96, alpha: 1)
let navy = NSColor(calibratedRed: 0.10, green: 0.28, blue: 0.62, alpha: 1)

for (start, corner, end) in [
    (NSPoint(x: 250, y: 650), NSPoint(x: 250, y: 770), NSPoint(x: 370, y: 770)),
    (NSPoint(x: 654, y: 770), NSPoint(x: 774, y: 770), NSPoint(x: 774, y: 650)),
    (NSPoint(x: 250, y: 374), NSPoint(x: 250, y: 254), NSPoint(x: 370, y: 254)),
    (NSPoint(x: 654, y: 254), NSPoint(x: 774, y: 254), NSPoint(x: 774, y: 374)),
] {
    let path = NSBezierPath()
    path.move(to: start)
    path.line(to: corner)
    path.line(to: end)
    stroke(path, color: blue, width: 52)
}

blue.setFill()
NSBezierPath(ovalIn: NSRect(x: 386, y: 542, width: 54, height: 70)).fill()
NSBezierPath(ovalIn: NSRect(x: 584, y: 542, width: 54, height: 70)).fill()

let smile = NSBezierPath()
smile.move(to: NSPoint(x: 402, y: 472))
smile.curve(
    to: NSPoint(x: 622, y: 472),
    controlPoint1: NSPoint(x: 450, y: 394),
    controlPoint2: NSPoint(x: 574, y: 394)
)
stroke(smile, color: blue, width: 40)

let shield = NSBezierPath()
shield.move(to: NSPoint(x: 640, y: 410))
shield.line(to: NSPoint(x: 790, y: 458))
shield.line(to: NSPoint(x: 790, y: 330))
shield.curve(
    to: NSPoint(x: 640, y: 206),
    controlPoint1: NSPoint(x: 790, y: 258),
    controlPoint2: NSPoint(x: 720, y: 222)
)
shield.curve(
    to: NSPoint(x: 490, y: 330),
    controlPoint1: NSPoint(x: 560, y: 222),
    controlPoint2: NSPoint(x: 490, y: 258)
)
shield.line(to: NSPoint(x: 490, y: 458))
shield.close()
navy.setFill()
shield.fill()

let check = NSBezierPath()
check.move(to: NSPoint(x: 562, y: 334))
check.line(to: NSPoint(x: 620, y: 278))
check.line(to: NSPoint(x: 724, y: 382))
stroke(check, color: .white, width: 34)

NSGraphicsContext.current = previousContext
guard let rendered = bitmapContext.makeImage(),
      let png = NSBitmapImageRep(cgImage: rendered).representation(
          using: .png,
          properties: [:]
      ) else {
    fputs("unable to render PNG\n", stderr)
    exit(1)
}
try png.write(to: outputURL, options: .atomic)
