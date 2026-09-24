// 把 art.png 合成为 macOS 风格图标（圆角方形 + 阴影 + 高光描边），输出 icon_1024.png
import AppKit

let dir = URL(fileURLWithPath: CommandLine.arguments[1])
guard let art = NSImage(contentsOf: dir.appending(path: "art.png")),
      let artCG = art.cgImage(forProposedRect: nil, context: nil, hints: nil) else { fatalError("no art.png") }

let size = 1024
let cs = CGColorSpace(name: CGColorSpace.sRGB)!
let ctx = CGContext(data: nil, width: size, height: size, bitsPerComponent: 8, bytesPerRow: 0,
                    space: cs, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!

// Apple 图标模板：824×824 主体，四周留 100px
let rect = CGRect(x: 100, y: 100, width: 824, height: 824)
let path = CGPath(roundedRect: rect, cornerWidth: 185, cornerHeight: 185, transform: nil)

ctx.saveGState()
ctx.setShadow(offset: CGSize(width: 0, height: -12), blur: 28, color: CGColor(gray: 0, alpha: 0.35))
ctx.addPath(path)
ctx.setFillColor(CGColor(gray: 0.1, alpha: 1))
ctx.fillPath()
ctx.restoreGState()

ctx.saveGState()
ctx.addPath(path)
ctx.clip()
// 稍微放大裁掉边缘
let inset: CGFloat = -6
ctx.draw(artCG, in: rect.insetBy(dx: inset, dy: inset))
// 顶部高光
let grad = CGGradient(colorsSpace: cs, colors: [CGColor(gray: 1, alpha: 0.18), CGColor(gray: 1, alpha: 0)] as CFArray, locations: [0, 1])!
ctx.drawLinearGradient(grad, start: CGPoint(x: 512, y: 924), end: CGPoint(x: 512, y: 600), options: [])
ctx.restoreGState()

ctx.addPath(path)
ctx.setStrokeColor(CGColor(gray: 1, alpha: 0.18))
ctx.setLineWidth(3)
ctx.strokePath()

let out = NSBitmapImageRep(cgImage: ctx.makeImage()!)
try! out.representation(using: .png, properties: [:])!.write(to: dir.appending(path: "icon_1024.png"))
print("ok")
