// 生成 README banner 与 GitHub social preview（程序化绘制，非生成式图片）
//
// 用法：swift tools/make-banner.swift <banner|social> <输出路径.png>
//
// 两个尺寸共用一套版式：左侧是放大的应用图标（浅色圆角块 + 深色胶囊 +
// 圆点波形），右侧三行文字，整组水平垂直居中。配色与 tools/make-icon.swift 一致。
import AppKit
import CoreGraphics
import CoreText
import Foundation

let kind = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "banner"
let outPath = CommandLine.arguments.count > 2
    ? CommandLine.arguments[2]
    : "/tmp/notch-island-\(kind).png"

let size: CGSize = kind == "social"
    ? CGSize(width: 1280, height: 640)
    : CGSize(width: 1600, height: 500)

let W = size.width
let H = size.height

guard let ctx = CGContext(
    data: nil,
    width: Int(W), height: Int(H),
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

func squircle(_ rect: CGRect, _ radius: CGFloat) -> CGPath {
    CGPath(roundedRect: rect, cornerWidth: radius, cornerHeight: radius, transform: nil)
}

func attributes(_ font: NSFont, _ color: NSColor, _ kern: CGFloat) -> [NSAttributedString.Key: Any] {
    [.font: font, .foregroundColor: color, .kern: kern]
}

/// 先量宽再画，才能把「图标 + 文字」当成一组居中
func measure(_ string: String, _ font: NSFont, _ kern: CGFloat) -> CGFloat {
    let line = CTLineCreateWithAttributedString(
        NSAttributedString(string: string, attributes: attributes(font, .white, kern)))
    return CTLineGetBoundsWithOptions(line, .useOpticalBounds).width
}

func draw(_ string: String, font: NSFont, color: NSColor, kern: CGFloat, at: CGPoint) {
    let line = CTLineCreateWithAttributedString(
        NSAttributedString(string: string, attributes: attributes(font, color, kern)))
    ctx.textPosition = at
    CTLineDraw(line, ctx)
}

// ── 版式参数 ────────────────────────────────────────────────────
let isSocial = kind == "social"
let iconSide: CGFloat = isSocial ? 200 : 240
let gap: CGFloat = isSocial ? 60 : 76
let titleSize: CGFloat = isSocial ? 92 : 116
let subSize: CGFloat = isSocial ? 32 : 38
let footSize: CGFloat = isSocial ? 21 : 24

let titleFont = NSFont.systemFont(ofSize: titleSize, weight: .semibold)
let subFont = NSFont.systemFont(ofSize: subSize, weight: .regular)
let footFont = NSFont.systemFont(ofSize: footSize, weight: .medium)

let title = "Notch Island"
let subtitle = "Liquid Glass notifications for the macOS notch"
let footer = "GPL-3.0   ·   macOS 26+   ·   unofficial fork of Boring Notch"

let titleKern = -titleSize * 0.022
let titleW = measure(title, titleFont, titleKern)
let subW = measure(subtitle, subFont, 0)
let textBlockW = max(titleW, subW)

let totalW = iconSide + gap + textBlockW
let startX = (W - totalW) / 2
let iconX = startX
let textX = startX + iconSide + gap

// 三行整体垂直居中：以标题基线为锚，反推基线位置
let titleBaseline = H / 2 + (1.9 * subSize + 0.25 * footSize) / 2

// ── 底：深色斜向渐变 ─────────────────────────────────────────────
if let bg = CGGradient(
    colorsSpace: CGColorSpaceCreateDeviceRGB(),
    colors: [rgb(22, 24, 31), rgb(7, 8, 11)] as CFArray,
    locations: [0, 1]
) {
    ctx.drawLinearGradient(
        bg, start: CGPoint(x: 0, y: H), end: CGPoint(x: W, y: 0), options: [])
}

// ── 图标块 ──────────────────────────────────────────────────────
let iconRect = CGRect(x: iconX, y: (H - iconSide) / 2, width: iconSide, height: iconSide)

// 图标后方柔光，避免左边一团死黑
if let glow = CGGradient(
    colorsSpace: CGColorSpaceCreateDeviceRGB(),
    colors: [rgb(120, 170, 255, 0.18), rgb(120, 170, 255, 0)] as CFArray,
    locations: [0, 1]
) {
    ctx.drawRadialGradient(
        glow,
        startCenter: CGPoint(x: iconRect.midX, y: iconRect.midY), startRadius: 0,
        endCenter: CGPoint(x: iconRect.midX, y: iconRect.midY), endRadius: iconSide * 1.3,
        options: [])
}

// 浅色底板
ctx.saveGState()
ctx.addPath(squircle(iconRect, iconSide * 0.225))
ctx.clip()
if let plate = CGGradient(
    colorsSpace: CGColorSpaceCreateDeviceRGB(),
    colors: [rgb(250, 251, 253), rgb(210, 214, 224)] as CFArray,
    locations: [0, 1]
) {
    ctx.drawLinearGradient(
        plate,
        start: CGPoint(x: iconRect.minX, y: iconRect.maxY),
        end: CGPoint(x: iconRect.maxX, y: iconRect.minY),
        options: [])
}
ctx.restoreGState()

// 岛（深色胶囊）
let pillW = iconSide * 0.62
let pillH = iconSide * 0.176
let pill = CGRect(
    x: iconRect.midX - pillW / 2,
    y: iconRect.midY - pillH / 2 + iconSide * 0.06,
    width: pillW, height: pillH
)
ctx.saveGState()
ctx.setShadow(offset: CGSize(width: 0, height: -iconSide * 0.018),
              blur: iconSide * 0.06,
              color: rgb(20, 24, 34, 0.30))
ctx.setFillColor(rgb(16, 17, 24))
ctx.addPath(squircle(pill, pillH / 2))
ctx.fillPath()
ctx.restoreGState()

// 岛内：左圆点 + 右波形
let dotR = pillH * 0.185
ctx.setFillColor(rgb(255, 255, 255, 0.96))
ctx.fillEllipse(in: CGRect(
    x: pill.minX + pillH * 0.42 - dotR,
    y: pill.midY - dotR,
    width: dotR * 2, height: dotR * 2))

let bars: [CGFloat] = [0.30, 0.60, 0.44, 0.72, 0.35]
let barW = pillH * 0.105
let barGap = pillH * 0.145
let barsTotal = CGFloat(bars.count) * barW + CGFloat(bars.count - 1) * barGap
var bx = pill.maxX - pillH * 0.42 - barsTotal
ctx.setFillColor(rgb(255, 255, 255, 0.92))
for h in bars {
    let barH = pillH * h
    ctx.addPath(squircle(CGRect(x: bx, y: pill.midY - barH / 2, width: barW, height: barH), barW / 2))
    bx += barW + barGap
}
ctx.fillPath()

// ── 文字 ────────────────────────────────────────────────────────
draw(title, font: titleFont,
     color: NSColor(white: 1.0, alpha: 0.97),
     kern: titleKern,
     at: CGPoint(x: textX, y: titleBaseline))

draw(subtitle, font: subFont,
     color: NSColor(red: 0.60, green: 0.64, blue: 0.71, alpha: 1),
     kern: 0,
     at: CGPoint(x: textX + 2, y: titleBaseline - titleSize * 0.72))

draw(footer, font: footFont,
     color: NSColor(red: 0.36, green: 0.39, blue: 0.45, alpha: 1),
     kern: 0,
     at: CGPoint(x: textX + 2, y: titleBaseline - titleSize * 0.72 - subSize * 1.9))

guard let image = ctx.makeImage() else {
    FileHandle.standardError.write("无法生成位图\n".data(using: .utf8)!)
    exit(1)
}

let rep = NSBitmapImageRep(cgImage: image)
rep.size = NSSize(width: W, height: H)
guard let png = rep.representation(using: .png, properties: [:]) else {
    FileHandle.standardError.write("无法编码 PNG\n".data(using: .utf8)!)
    exit(1)
}
try png.write(to: URL(fileURLWithPath: outPath))
print("已生成 \(kind)：\(outPath)  (\(Int(W))×\(Int(H)))  内容宽 \(Int(totalW))")
