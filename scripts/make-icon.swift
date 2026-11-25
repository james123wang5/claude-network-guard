// 画 App 图标：swift scripts/make-icon.swift <输出目录>，再用 iconutil 打成 icns。
import AppKit

let folder = URL(fileURLWithPath: CommandLine.arguments[1])
func color(_ r: Double, _ g: Double, _ b: Double) -> NSColor { NSColor(srgbRed: r, green: g, blue: b, alpha: 1) }

func draw(_ size: Int) -> Data {
    let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: size, pixelsHigh: size, bitsPerSample: 8, samplesPerPixel: 4,
                                  hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: bitmap)
    let s = CGFloat(size) / 1024
    let transform = NSAffineTransform()
    transform.scale(by: s)
    transform.concat()
    let tile = NSBezierPath(roundedRect: NSRect(x: 100, y: 100, width: 824, height: 824), xRadius: 186, yRadius: 186)
    NSGradient(starting: color(0.30, 0.39, 0.72), ending: color(0.13, 0.17, 0.37))!.draw(in: tile, angle: -90)
    // 盾牌
    func point(_ x: CGFloat, _ y: CGFloat) -> NSPoint { NSPoint(x: 172 + x / 100 * 680, y: 842 - y / 100 * 660) }
    let shield = NSBezierPath()
    shield.move(to: point(50, 2))
    shield.curve(to: point(92, 17), controlPoint1: point(62, 11), controlPoint2: point(77, 16))
    shield.line(to: point(92, 48))
    shield.curve(to: point(50, 98), controlPoint1: point(92, 73), controlPoint2: point(74, 89))
    shield.curve(to: point(8, 48), controlPoint1: point(26, 89), controlPoint2: point(8, 73))
    shield.line(to: point(8, 17))
    shield.curve(to: point(50, 2), controlPoint1: point(23, 16), controlPoint2: point(38, 11))
    shield.close()
    NSGradient(starting: color(1, 1, 1), ending: color(0.87, 0.91, 0.98))!.draw(in: shield, angle: -90)
    // 盾牌里的像素小家伙，和 GuardMark.swift 一样
    let buddy = ["..##########..", "..##########..", "..##E####E##..", "..##E####E##..", "##############",
                 "##############", "..##########..", "..##########..", "..#.#....#.#..", "..#.#....#.#.."]
    let cell: CGFloat = 32
    // 同色的格子合成一条路径再填，避免格子之间露出细缝。
    let body = NSBezierPath(), eyes = NSBezierPath()
    for (y, row) in buddy.enumerated() {
        for (x, mark) in row.enumerated() where mark != "." {
            let box = NSRect(x: 512 - cell * 7 + CGFloat(x) * cell, y: 694 - CGFloat(y + 1) * cell, width: cell, height: cell)
            body.appendRect(box.insetBy(dx: -1, dy: -1))
            if mark == "E" { eyes.appendRect(box) }
        }
    }
    color(0.85, 0.47, 0.34).setFill()
    body.fill()
    color(0.13, 0.11, 0.11).setFill()
    eyes.fill()
    NSGraphicsContext.restoreGraphicsState()
    return bitmap.representation(using: .png, properties: [:])!
}

for (points, scale) in [(16, 1), (16, 2), (32, 1), (32, 2), (128, 1), (128, 2), (256, 1), (256, 2), (512, 1), (512, 2)] {
    let name = "icon_\(points)x\(points)\(scale == 2 ? "@2x" : "").png"
    try! draw(points * scale).write(to: folder.appendingPathComponent(name))
}
