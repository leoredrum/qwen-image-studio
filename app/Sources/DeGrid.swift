import AppKit

/// 去除 Qwen-Image VAE 解码后残留的 2px 网格。
///
/// 网格是周期为 2 的固定图案，只落在三个奈奎斯特分量上：(-1)^x、(-1)^y、(-1)^(x+y)。
/// 按 32px 分块估计每个分量的幅度（自然画面在大块内对这些交替符号求平均≈0，网格则稳定不变），
/// 双线性插值成平滑的幅度图后逐像素减掉。透明通道原样保留。
enum DeGrid {
    static let tile = 32

    @discardableResult
    static func process(url: URL) -> Bool {
        guard let src = NSImage(contentsOf: url)?.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return false }
        let w = src.width, h = src.height
        guard w >= tile * 2, h >= tile * 2 else { return false }

        // 读成 RGBA8（非预乘，避免透明区域的颜色被改动）
        var px = [UInt8](repeating: 0, count: w * h * 4)
        let cs = CGColorSpace(name: CGColorSpace.sRGB)!
        guard let ctx = CGContext(data: &px, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4, space: cs,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return false }
        ctx.draw(src, in: CGRect(x: 0, y: 0, width: w, height: h))
        let hasAlpha = src.alphaInfo != .none && src.alphaInfo != .noneSkipLast && src.alphaInfo != .noneSkipFirst
        // 反预乘
        if hasAlpha {
            for i in stride(from: 0, to: px.count, by: 4) {
                let a = Int(px[i + 3])
                if a > 0 && a < 255 { for c in 0..<3 { px[i + c] = UInt8(min(255, Int(px[i + c]) * 255 / a)) } }
            }
        }

        let tx = w / tile, ty = h / tile
        // amp[分量][通道][块]
        var amp = [[[Float]]](repeating: [[Float]](repeating: [Float](repeating: 0, count: tx * ty), count: 3), count: 3)
        for by in 0..<ty {
            for bx in 0..<tx {
                var s = [[Float]](repeating: [0, 0, 0], count: 3)
                var n: Float = 0
                for y in by * tile..<(by + 1) * tile {
                    let sy: Float = (y & 1) == 0 ? 1 : -1
                    for x in bx * tile..<(bx + 1) * tile {
                        let i = (y * w + x) * 4
                        if hasAlpha && px[i + 3] < 250 { continue }  // 透明边缘不参与估计
                        let sx: Float = (x & 1) == 0 ? 1 : -1
                        for c in 0..<3 {
                            let v = Float(px[i + c])
                            s[0][c] += v * sx
                            s[1][c] += v * sy
                            s[2][c] += v * sx * sy
                        }
                        n += 1
                    }
                }
                guard n > Float(tile * tile) * 0.5 else { continue }
                for k in 0..<3 { for c in 0..<3 { amp[k][c][by * tx + bx] = s[k][c] / n } }
            }
        }

        // 双线性插值幅度图，逐像素减掉网格
        func sample(_ a: [Float], _ fx: Float, _ fy: Float) -> Float {
            let gx = max(0, min(Float(tx - 1), fx)), gy = max(0, min(Float(ty - 1), fy))
            let x0 = Int(gx), y0 = Int(gy)
            let x1 = min(tx - 1, x0 + 1), y1 = min(ty - 1, y0 + 1)
            let dx = gx - Float(x0), dy = gy - Float(y0)
            let top = a[y0 * tx + x0] * (1 - dx) + a[y0 * tx + x1] * dx
            let bot = a[y1 * tx + x0] * (1 - dx) + a[y1 * tx + x1] * dx
            return top * (1 - dy) + bot * dy
        }
        for y in 0..<h {
            let sy: Float = (y & 1) == 0 ? 1 : -1
            let fy = (Float(y) + 0.5) / Float(tile) - 0.5
            for x in 0..<w {
                let i = (y * w + x) * 4
                if hasAlpha && px[i + 3] == 0 { continue }
                let sx: Float = (x & 1) == 0 ? 1 : -1
                let fx = (Float(x) + 0.5) / Float(tile) - 0.5
                for c in 0..<3 {
                    let g = sample(amp[0][c], fx, fy) * sx + sample(amp[1][c], fx, fy) * sy + sample(amp[2][c], fx, fy) * sx * sy
                    px[i + c] = UInt8(max(0, min(255, (Float(px[i + c]) - g).rounded())))
                }
            }
        }

        // 写回 PNG（有透明通道时保持非预乘 RGBA）
        guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: w, pixelsHigh: h, bitsPerSample: 8,
                                         samplesPerPixel: hasAlpha ? 4 : 3, hasAlpha: hasAlpha, isPlanar: false,
                                         colorSpaceName: .deviceRGB, bitmapFormat: hasAlpha ? [.alphaNonpremultiplied] : [],
                                         bytesPerRow: 0, bitsPerPixel: 0),
              let out = rep.bitmapData else { return false }
        let spp = hasAlpha ? 4 : 3
        for y in 0..<h {
            let row = out.advanced(by: y * rep.bytesPerRow)
            for x in 0..<w {
                let i = (y * w + x) * 4
                for c in 0..<spp { row[x * spp + c] = px[i + c] }
            }
        }
        guard let png = rep.representation(using: .png, properties: [:]) else { return false }
        return (try? png.write(to: url, options: .atomic)) != nil
    }
}
