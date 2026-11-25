import SwiftUI

/// 标志：盾牌里站着一个陶土色的像素小家伙。图标脚本 scripts/make-icon.swift 用的是同一套形状。
enum MarkShape {
    /// # 身体，E 眼睛。
    static let buddy = [
        "..##########..",
        "..##########..",
        "..##E####E##..",
        "..##E####E##..",
        "##############",
        "##############",
        "..##########..",
        "..##########..",
        "..#.#....#.#..",
        "..#.#....#.#..",
    ]

    /// 100×100 里的盾牌。
    static func shield(in rect: CGRect) -> Path {
        func point(_ x: CGFloat, _ y: CGFloat) -> CGPoint { CGPoint(x: rect.minX + x / 100 * rect.width, y: rect.minY + y / 100 * rect.height) }
        var path = Path()
        path.move(to: point(50, 2))
        path.addCurve(to: point(92, 17), control1: point(62, 11), control2: point(77, 16))
        path.addLine(to: point(92, 48))
        path.addCurve(to: point(50, 98), control1: point(92, 73), control2: point(74, 89))
        path.addCurve(to: point(8, 48), control1: point(26, 89), control2: point(8, 73))
        path.addLine(to: point(8, 17))
        path.addCurve(to: point(50, 2), control1: point(23, 16), control2: point(38, 11))
        path.closeSubpath()
        return path
    }
}

struct GuardMark: View {
    var body: some View {
        Canvas { context, size in
            let side = min(size.width, size.height)
            let rect = CGRect(x: (size.width - side) / 2, y: (size.height - side) / 2, width: side, height: side).insetBy(dx: side * 0.04, dy: side * 0.04)
            let shield = MarkShape.shield(in: rect)
            context.fill(shield, with: .color(.white))
            context.stroke(shield, with: .color(Color.guardButton), style: StrokeStyle(lineWidth: side * 0.075, lineJoin: .round))
            let cell = rect.width * 0.60 / 14
            let origin = CGPoint(x: rect.midX - cell * 7, y: rect.minY + rect.height * 0.455 - cell * 5)
            // 同色的格子合成一条路径再填，避免格子之间露出细缝。
            var body = Path(), eyes = Path()
            for (y, row) in MarkShape.buddy.enumerated() {
                for (x, mark) in row.enumerated() where mark != "." {
                    let box = CGRect(x: origin.x + CGFloat(x) * cell, y: origin.y + CGFloat(y) * cell, width: cell, height: cell)
                    body.addRect(box.insetBy(dx: -0.05, dy: -0.05))
                    if mark == "E" { eyes.addRect(box) }
                }
            }
            context.fill(body, with: .color(Color(red: 0.85, green: 0.47, blue: 0.34)))
            context.fill(eyes, with: .color(Color(red: 0.13, green: 0.11, blue: 0.11)))
        }
        .accessibilityHidden(true)
    }
}
