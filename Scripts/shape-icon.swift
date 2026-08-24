// Turns arbitrary square artwork into a macOS app icon.
//
// Two things have to be true and usually are not. The corners must be genuinely transparent: source
// artwork often paints its rounded shape onto an opaque background, and macOS then renders the
// background square rather than the shape. And the artwork must occupy the proportion of the canvas
// Apple uses, roughly 824 of 1024, so that it lines up with every other icon in the Dock.

import AppKit
import CoreGraphics
import Foundation

let arguments = CommandLine.arguments
guard arguments.count >= 3 else {
    FileHandle.standardError.write(Data("usage: shape-icon <input.png> <output.png>\n".utf8))
    exit(2)
}

guard let source = NSImage(contentsOfFile: arguments[1]),
      let sourceRef = source.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
    FileHandle.standardError.write(Data("cannot read \(arguments[1])\n".utf8))
    exit(1)
}

// Apple's proportions, expressed against a 1024 canvas.
let canvas = 1024
let inner = 824
let cornerRadius = 185.4
let offset = (canvas - inner) / 2

guard let context = CGContext(
    data: nil, width: canvas, height: canvas,
    bitsPerComponent: 8, bytesPerRow: 0,
    space: CGColorSpace(name: CGColorSpace.sRGB)!,
    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
) else { exit(1) }

context.interpolationQuality = .high
context.clear(CGRect(x: 0, y: 0, width: canvas, height: canvas))

let shape = CGRect(x: offset, y: offset, width: inner, height: inner)

// A soft drop shadow, as system icons carry.
context.saveGState()
context.setShadow(offset: CGSize(width: 0, height: -10), blur: 20,
                  color: CGColor(red: 0, green: 0, blue: 0, alpha: 0.28))
context.setFillColor(CGColor(red: 0, green: 0, blue: 0, alpha: 1))
context.addPath(CGPath(roundedRect: shape, cornerWidth: cornerRadius, cornerHeight: cornerRadius, transform: nil))
context.fillPath()
context.restoreGState()

// Clip to the rounded shape, so whatever the artwork has in its corners is discarded.
context.saveGState()
context.addPath(CGPath(roundedRect: shape, cornerWidth: cornerRadius, cornerHeight: cornerRadius, transform: nil))
context.clip()
context.draw(sourceRef, in: shape)
context.restoreGState()

guard let output = context.makeImage(),
      let data = NSBitmapImageRep(cgImage: output).representation(using: .png, properties: [:]) else { exit(1) }
try data.write(to: URL(fileURLWithPath: arguments[2]))
print("shaped: \(canvas)px canvas, \(inner)px rounded artwork, transparent corners")
