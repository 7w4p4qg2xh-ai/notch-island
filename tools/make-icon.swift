// 生成 Notch Island 的应用图标（程序化绘制，非生成式图片）
// 用法：swift tools/make-icon.swift <输出路径.png>
//
// 设计：macOS 图标规范画布 1024，内容区 824×824 居中、圆角 185。
// 浅色底 + 近黑胶囊（真正的「岛」形状），岛内左侧圆点、右侧波形，
// 直白地表达「通知与正在播放都落在这个岛上」。
import AppKit
import CoreGraphics
import Foundation

let outPath = CommandLine.arguments.count > 1
    ? CommandLine.arguments[1]
    : "/tmp/NotchIsland-1024.png"

let canvas: CGFloat = 1024
let content = CGRect(x: 100, y: 100, width: 824, height: 824)
let corner: CGFloat = 185

guard let ctx = CGContext(
    data: nil,
    width: Int(canvas), height: Int(canvas),
    bitsPerComponent: 8, bytesPerRow: 0,
    space: CGColorSpaceCreateDeviceRGB(),
    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
) else {
    FileHandle.standardError.write("无法创建绘图上下文\n".data(using: .utf8)!)
    exit(1)
}

func rgb(_ r: CGFloat, _ g: CGFloat, _ b: CGFloat, _ a: CGFloat = 1) -> CGColor {
    CGColor(red: r / 255, green: g / 255, blue: b / 255, alpha: a)
}

/// 连续曲率圆角（squircle），与 macOS 图标一致；纯圆弧圆角在大尺寸下会显方
func squirclePath(_ rect: CGRect, _ radius: CGFloat) -> CGPath {
    let p = CGMutablePath()
    let r = radius
    let right = rect.maxX, left = rect.minX
    let top = rect.maxY, bottom = rect.minY
    let k: CGFloat = 0.5523   // 三次贝塞尔圆的控制点比例

    p.move(to: CGPoint(x: left + r, y: top))
    p.addLine(to: CGPoint(x: right - r, y: top))
    p.addCurve(to: CGPoint(x: right, y: top - r),
               control1: CGPoint(x: right - r + r * k, y: top),
               control2: CGPoint(x: right, y: top - r + r * k))
    p.addLine(to: CGPoint(x: right, y: bottom + r))
    p.addCurve(to: CGPoint(x: right - r, y: bottom),
               control1: CGPoint(x: right, y: bottom + r - r * k),
               control2: CGPoint(x: right - r + r * k, y: bottom))
    p.addLine(to: CGPoint(x: left + r, y: bottom))
    p.addCurve(to: CGPoint(x: left, y: bottom + r),
               control1: CGPoint(x: left + r - r * k, y: bottom),
               control2: CGPoint(x: left, y: bottom + r - r * k))
    p.addLine(to: CGPoint(x: left, y: top - r))
    p.addCurve(to: CGPoint(x: left + r, y: top),
               control1: CGPoint(x: left, y: top - r + r * k),
               control2: CGPoint(x: left + r - r * k, y: top))
    p.closeSubpath()
    return p
}

ctx.setShouldAntialias(true)
ctx.interpolationQuality = .high

// ── 底板：浅灰白渐变，右下略暗，给一点体积感 ──────────────
let plate = squirclePath(content, corner)
ctx.saveGState()
ctx.addPath(plate)
ctx.clip()
if let bg = CGGradient(
    colorsSpace: CGColorSpaceCreateDeviceRGB(),
    colors: [rgb(250, 251, 253), rgb(214, 218, 228)] as CFArray,
    locations: [0, 1]
) {
    ctx.drawLinearGradient(
        bg,
        start: CGPoint(x: content.minX, y: content.maxY),
        end: CGPoint(x: content.maxX, y: content.minY),
        options: []
    )
}
ctx.restoreGState()

// ── 浮岛：近黑胶囊，居中偏上 ──────────────────────────────
let islandW: CGFloat = 536
let islandH: CGFloat = 152
let island = CGRect(
    x: (canvas - islandW) / 2,
    y: canvas / 2 - islandH / 2 + 54,
    width: islandW, height: islandH
)
let pill = CGPath(roundedRect: island, cornerWidth: islandH / 2, cornerHeight: islandH / 2, transform: nil)

// 岛下方的柔和投影：让它「浮」起来，而不是贴片
ctx.saveGState()
ctx.setShadow(offset: CGSize(width: 0, height: -14), blur: 44, color: rgb(30, 34, 48, 0.28))
ctx.setFillColor(rgb(16, 17, 24))
ctx.addPath(pill)
ctx.fillPath()
ctx.restoreGState()

// 胶囊上沿一道极细高光：玻璃透镜感
ctx.saveGState()
ctx.addPath(pill)
ctx.setLineWidth(2.5)
ctx.setStrokeColor(rgb(255, 255, 255, 0.16))
ctx.strokePath()
ctx.restoreGState()

// ── 岛内内容：左侧应用圆点，右侧播放波形 ──────────────────
let dotR: CGFloat = 21
let dotCx = island.minX + 62
let dotCy = island.midY
ctx.setFillColor(rgb(255, 255, 255, 0.96))
ctx.fillEllipse(in: CGRect(x: dotCx - dotR, y: dotCy - dotR, width: dotR * 2, height: dotR * 2))

// 波形：五根竖条，高度起伏，右对齐
let heights: [CGFloat] = [26, 52, 38, 62, 30]
let barW: CGFloat = 11
let barGap: CGFloat = 15
let totalW = CGFloat(heights.count) * barW + CGFloat(heights.count - 1) * barGap
var bx = island.maxX - 62 - totalW
ctx.setFillColor(rgb(255, 255, 255, 0.92))
for h in heights {
    let rect = CGRect(x: bx, y: dotCy - h / 2, width: barW, height: h)
    ctx.addPath(CGPath(roundedRect: rect, cornerWidth: barW / 2, cornerHeight: barW / 2, transform: nil))
    bx += barW + barGap
}
ctx.fillPath()

guard let image = ctx.makeImage() else {
    FileHandle.standardError.write("无法生成位图\n".data(using: .utf8)!)
    exit(1)
}

let rep = NSBitmapImageRep(cgImage: image)
rep.size = NSSize(width: canvas, height: canvas)
guard let png = rep.representation(using: .png, properties: [:]) else {
    FileHandle.standardError.write("无法编码 PNG\n".data(using: .utf8)!)
    exit(1)
}
try png.write(to: URL(fileURLWithPath: outPath))
print("已生成：\(outPath)")
