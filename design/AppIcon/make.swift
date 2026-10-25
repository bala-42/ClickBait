// Draws ClickBait's app icon (design/AppIcon, 2026-10-25): the Hubble Ultra Deep Field
// (NASA, ESA, S. Beckwith/STScI) in a macOS rounded square, with HeyClicky's mark layout,
// its small top-right caret swapped for the companion's triangle, in 88% soft white.
// Run: swift design/AppIcon/make.swift <out folder> <deep field image>, then size the
// 1024 px PNG into ClickBait/Assets.xcassets/AppIcon.appiconset with sips.
import AppKit

let src = NSImage(contentsOfFile: CommandLine.arguments[2])!
let cg = src.cgImage(forProposedRect: nil, context: nil, hints: nil)!
let out = CommandLine.arguments[1]

func triangle(_ c: CGPoint, side: CGFloat, angle: CGFloat) -> CGPath {
    let h = side * sqrt(3) / 2
    let pts = [CGPoint(x: 0, y: h / 1.5), CGPoint(x: side / 2, y: -h / 3), CGPoint(x: -side / 2, y: -h / 3)]
    let r = 1.5 * side / 16, a = angle * .pi / 180
    let rot = pts.map { CGPoint(x: c.x + $0.x * cos(a) - $0.y * sin(a), y: c.y + $0.x * sin(a) + $0.y * cos(a)) }
    let p = CGMutablePath()
    p.move(to: CGPoint(x: (rot[2].x + rot[0].x) / 2, y: (rot[2].y + rot[0].y) / 2))
    p.addArc(tangent1End: rot[0], tangent2End: rot[1], radius: r)
    p.addArc(tangent1End: rot[1], tangent2End: rot[2], radius: r)
    p.addArc(tangent1End: rot[2], tangent2End: rot[0], radius: r)
    p.closeSubpath()
    return p
}

let blue = CGColor(red: 0, green: 127 / 255, blue: 1, alpha: 1)
// Soft white, like HeyClicky's glyph: a touch off-white with a gentle white glow.
let soft = CGColor(red: 0.96, green: 0.97, blue: 0.99, alpha: 0.88)
let variants: [(String, CGColor, CGFloat)] = [("AppIcon-1024", soft, 15)]
for (name, fill, tilt) in variants {
    let size = 1024
    let ctx = CGContext(data: nil, width: size, height: size, bitsPerComponent: 8, bytesPerRow: 0,
                        space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    // macOS icon grid: 824 pt rounded square, centred, soft drop shadow.
    let tile = CGRect(x: 100, y: 100, width: 824, height: 824)
    let shape = CGPath(roundedRect: tile, cornerWidth: 185, cornerHeight: 185, transform: nil)
    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: -12), blur: 28, color: CGColor(gray: 0, alpha: 0.45))
    ctx.addPath(shape); ctx.setFillColor(.black); ctx.fillPath()
    ctx.restoreGState()
    ctx.saveGState()
    ctx.addPath(shape); ctx.clip()
    // The deep field, a square from the middle of the photo.
    let side = min(cg.width, cg.height)
    let crop = cg.cropping(to: CGRect(x: (cg.width - side) / 2, y: (cg.height - side) / 2, width: side, height: side))!
    ctx.interpolationQuality = .high
    ctx.draw(crop, in: tile)
    // A dark glow in the middle so the eyes read against the stars.
    let shade = CGGradient(colorsSpace: nil, colors: [CGColor(gray: 0, alpha: 0.55), CGColor(gray: 0, alpha: 0)] as CFArray, locations: [0, 1])!
    ctx.drawRadialGradient(shade, startCenter: CGPoint(x: 512, y: 540), startRadius: 0, endCenter: CGPoint(x: 512, y: 540), endRadius: 440, options: [])
    // Two companion triangles as eyes, with the companion's glow.
    // HeyClicky's layout (traced from its icon, scaled to this tile): a caret whose right leg
    // runs down into a bar (the ⌥ shape), and, where its small top-right caret was, the
    // companion's triangle, gently tilted.
    let glyph = CGMutablePath()
    glyph.move(to: CGPoint(x: 274, y: 568)); glyph.addLine(to: CGPoint(x: 369, y: 672))
    glyph.addLine(to: CGPoint(x: 525, y: 362)); glyph.addLine(to: CGPoint(x: 672, y: 362))
    let stroke = glyph.copy(strokingWithWidth: 54, lineCap: .round, lineJoin: .round, miterLimit: 10, transform: CGAffineTransform(translationX: 512, y: 517).scaledBy(x: 1, y: 1).translatedBy(x: -512, y: -517))
    let eye0 = triangle(CGPoint(x: 652, y: 610), side: 175, angle: tilt)
    // Balance like HeyClicky's: the whole mark 85% the size, a touch above the middle.
    var fit = CGAffineTransform(translationX: 512, y: 517).scaledBy(x: 1, y: 1).translatedBy(x: -512, y: -517)
    let eye = eye0.copy(using: &fit)!
    for shape in [eye, stroke] {
        ctx.saveGState()
        ctx.setShadow(offset: .zero, blur: 36, color: CGColor(gray: 1, alpha: 0.35))
        ctx.addPath(shape); ctx.setFillColor(fill); ctx.fillPath()
        ctx.restoreGState()
    }
    // A thin light edge, like Apple's icons.
    ctx.addPath(CGPath(roundedRect: tile.insetBy(dx: 1.5, dy: 1.5), cornerWidth: 184, cornerHeight: 184, transform: nil))
    ctx.setStrokeColor(CGColor(gray: 1, alpha: 0.18)); ctx.setLineWidth(3); ctx.strokePath()
    ctx.restoreGState()
    let rep = NSBitmapImageRep(cgImage: ctx.makeImage()!)
    try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: "\(out)/\(name).png"))
}
