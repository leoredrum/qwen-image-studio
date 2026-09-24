import Foundation

// MARK: - 分辨率

enum Aspect: String, CaseIterable, Codable, Identifiable {
    case square = "1:1", l43 = "4:3", p34 = "3:4", l32 = "3:2", p23 = "2:3", l169 = "16:9", p916 = "9:16"
    var id: String { rawValue }

    var symbol: String {
        switch self {
        case .square: "square"
        case .l43, .l32: "rectangle"
        case .p34, .p23: "rectangle.portrait"
        case .l169: "rectangle.ratio.16.to.9"
        case .p916: "rectangle.ratio.9.to.16"
        }
    }
}

enum SizeTier: String, CaseIterable, Codable, Identifiable {
    case draft = "草稿", standard = "标准", hd = "2K 高清"
    var id: String { rawValue }

    var detail: String {
        switch self {
        case .draft: "约 0.6MP · 最快，适合试提示词"
        case .standard: "约 1MP · 官方推荐起步分辨率"
        case .hd: "约 4MP · Qwen 原生 2K，耗时约 5 倍"
        }
    }

    /// 目标像素数，用于「跟随参考图」时按比例换算
    var megapixels: Double {
        switch self {
        case .draft: 0.59
        case .standard: 1.05
        case .hd: 4.2
        }
    }
}

/// Qwen 官方推荐的预设尺寸（均可被 32 整除）
func presetSize(_ a: Aspect, _ t: SizeTier) -> (Int, Int) {
    switch (t, a) {
    case (.draft, .square): (768, 768)
    case (.draft, .l43): (896, 672)
    case (.draft, .p34): (672, 896)
    case (.draft, .l32): (960, 640)
    case (.draft, .p23): (640, 960)
    case (.draft, .l169): (1024, 576)
    case (.draft, .p916): (576, 1024)
    case (.standard, .square): (1024, 1024)
    case (.standard, .l43): (1152, 864)
    case (.standard, .p34): (864, 1152)
    case (.standard, .l32): (1248, 832)
    case (.standard, .p23): (832, 1248)
    case (.standard, .l169): (1536, 864)
    case (.standard, .p916): (864, 1536)
    case (.hd, .square): (2048, 2048)
    case (.hd, .l43): (2400, 1792)
    case (.hd, .p34): (1792, 2400)
    case (.hd, .l32): (2528, 1696)
    case (.hd, .p23): (1696, 2528)
    case (.hd, .l169): (2752, 1536)
    case (.hd, .p916): (1536, 2752)
    }
}

/// 按目标像素数和宽高比算出可被 32 整除的尺寸
func fitSize(aspect: Double, megapixels: Double) -> (Int, Int) {
    let px = megapixels * 1_000_000
    let h = (px / aspect).squareRoot()
    let w = h * aspect
    func r32(_ v: Double) -> Int { max(256, Int((v / 32).rounded()) * 32) }
    return (r32(w), r32(h))
}

// MARK: - 画质（步数）

struct QualityPreset: Identifiable {
    let name: String
    let steps: Int
    let detail: String
    var id: Int { steps }

    static let all: [QualityPreset] = [
        .init(name: "草稿", steps: 12, detail: "12 步 · 快速出构图"),
        .init(name: "标准", steps: 20, detail: "20 步 · sd.cpp 官方默认"),
        .init(name: "精细", steps: 30, detail: "30 步 · 细节更好"),
        .init(name: "极致", steps: 40, detail: "40 步 · Qwen 官方基线"),
    ]

    static func label(for steps: Int) -> String {
        all.first { $0.steps == steps }?.name ?? "\(steps) 步"
    }
}

let samplers = ["euler", "euler_a", "heun", "dpm2", "dpm++2m", "dpm++2mv2", "dpm++2s_a", "ipndm", "res_multistep", "er_sde", "lcm"]
let schedulers = ["", "simple", "discrete", "karras", "exponential", "sgm_uniform", "beta", "smoothstep", "kl_optimal"]

let safetyNegative = "nsfw, nude, naked, nudity, nipples, genitals, explicit, sexual, porn, erotic, lingerie, gore, blood"

// MARK: - 设置

struct Settings: Codable, Equatable {
    var diffusionModel = "qwen-image-2.1-Q8_0.gguf"
    var textEncoder = "Qwen3-VL-8B-Instruct-UD-Q4_K_XL.gguf"
    var aspect: Aspect = .square
    var tier: SizeTier = .standard
    var customSize = false
    var width = 1024
    var height = 1024
    var followRefSize = true
    var steps = 20
    var cfg = 6.0
    var sampler = "euler"
    var scheduler = ""
    var randomSeed = true
    var seed = 42
    var batch = 1
    var negative = ""
    var nsfw = false
    var fastMode = false
    var livePreview = true
    var vaeTiling = false
    var chainEdits = true
    var assistant = true
    var assistantModel = "qwen3.5:9b"

    static let key = "studio.settings"

    init() {}

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = Settings()
        func v<T: Decodable>(_ k: CodingKeys, _ def: T) -> T { (try? c.decodeIfPresent(T.self, forKey: k)) ?? def }
        diffusionModel = v(.diffusionModel, d.diffusionModel)
        textEncoder = v(.textEncoder, d.textEncoder)
        aspect = v(.aspect, d.aspect)
        tier = v(.tier, d.tier)
        customSize = v(.customSize, d.customSize)
        width = v(.width, d.width)
        height = v(.height, d.height)
        followRefSize = v(.followRefSize, d.followRefSize)
        steps = v(.steps, d.steps)
        cfg = v(.cfg, d.cfg)
        sampler = v(.sampler, d.sampler)
        scheduler = v(.scheduler, d.scheduler)
        randomSeed = v(.randomSeed, d.randomSeed)
        seed = v(.seed, d.seed)
        batch = v(.batch, d.batch)
        negative = v(.negative, d.negative)
        nsfw = v(.nsfw, d.nsfw)
        fastMode = v(.fastMode, d.fastMode)
        livePreview = v(.livePreview, d.livePreview)
        vaeTiling = v(.vaeTiling, d.vaeTiling)
        chainEdits = v(.chainEdits, d.chainEdits)
        assistant = v(.assistant, d.assistant)
        assistantModel = v(.assistantModel, d.assistantModel)
    }

    static func load() -> Settings {
        guard let d = UserDefaults.standard.data(forKey: key),
              let s = try? JSONDecoder().decode(Settings.self, from: d) else { return Settings() }
        return s
    }

    func save() {
        if let d = try? JSONEncoder().encode(self) { UserDefaults.standard.set(d, forKey: Self.key) }
    }
}

// MARK: - 历史记录

struct GenParams: Codable, Hashable {
    var prompt: String
    var negative: String
    var width: Int
    var height: Int
    var steps: Int
    var cfg: Double
    var seed: Int
    var sampler: String
    var scheduler: String
    var batch: Int
    var diffusionModel: String
    var textEncoder: String
    var nsfw: Bool
    var fastMode: Bool
    var refImages: [String]  // 相对 outputs/ 的路径
    var userText: String?        // 用户原话（经过助手改写时才有）
    var assistantMode: String?   // generate | edit
    var assistantNote: String?   // 助手的判断理由或错误信息

    var modelShortName: String {
        diffusionModel.replacingOccurrences(of: "qwen-image-2.1-", with: "").replacingOccurrences(of: ".gguf", with: "")
    }

    var summary: String {
        "\(modelShortName) · \(width)×\(height) · \(steps)步 · CFG \(cfg.formatted(.number.precision(.fractionLength(0...1)))) · seed \(seed)"
    }
}

enum ItemStatus: String, Codable {
    case thinking, queued, running, done, failed, cancelled
}

struct ChatItem: Codable, Identifiable, Equatable {
    var id = UUID()
    var date = Date()
    var params: GenParams
    var outputs: [String] = []  // 相对 outputs/ 的文件名
    var status: ItemStatus = .queued
    var error: String?
    var duration: Double?

    var isEdit: Bool { !params.refImages.isEmpty }
}

struct RunProgress: Equatable {
    var stage = "准备中"
    var step = 0
    var total = 0
    var secPerStep: Double = 0
    var imageIndex = 1
    var imageCount = 1
    var started = Date()

    var fraction: Double {
        guard total > 0 else { return 0 }
        return (Double(imageIndex - 1) + Double(step) / Double(total)) / Double(max(imageCount, 1))
    }

    var eta: Double? {
        guard secPerStep > 0, total > 0 else { return nil }
        let remaining = (total - step) + (imageCount - imageIndex) * total
        return Double(remaining) * secPerStep + 8
    }
}

func formatDuration(_ s: Double) -> String {
    if s < 60 { return "\(Int(s)) 秒" }
    let m = Int(s) / 60, r = Int(s) % 60
    return r == 0 ? "\(m) 分钟" : "\(m) 分 \(r) 秒"
}
