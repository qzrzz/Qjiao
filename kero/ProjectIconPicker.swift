//
//  ProjectIconPicker.swift
//  kero
//
//  项目自定义图标：列表展示 + 预置 / SF Symbol / Emoji / 文件选择面板。
//

import AppKit
import Combine
import SwiftUI
import UniformTypeIdentifiers

// MARK: - List icon

/// 项目行的图标：没有自定义图标时沿用文件夹样式。
struct ProjectIconView: View {
    let icon: ProjectIcon?
    let isSelected: Bool

    var size: CGFloat = 24

    /// 根据 size 按比例计算 SF Symbol 字号（基准为 size=24 时 listIconSize=16pt）。
    private var iconFont: Font {
        let fontSize = max(8.0, SidebarTypography.listIconSize * (size / 24.0))
        return .system(size: fontSize)
    }

    /// 根据 size 按比例计算 Emoji 字号（基准为 size=24 时 listEmojiSize=18pt）。
    private var emojiFont: Font {
        let fontSize = max(9.0, SidebarTypography.listEmojiSize * (size / 24.0))
        return .system(size: fontSize)
    }

    var body: some View {
        switch icon {
        case .sfSymbol(let name):
            Image(systemName: name)
                .font(iconFont)
                .foregroundStyle(iconColor)
                .frame(width: size, height: size)
        case .emoji(let emoji):
            Text(emoji)
                .font(emojiFont)
                .lineLimit(1)
                .fixedSize()
                .frame(width: size, height: size)
        case .preset(let preset):
            ProjectPresetIconImage(preset: preset, size: size * 0.9, isSelected: isSelected)
                .frame(width: size, height: size)
        case .file(let path):
            ProjectFileIconImage(path: path, size: size * 0.9)
                .frame(width: size, height: size)
        case nil:
            Image(systemName: "folder")
                .font(iconFont)
                .foregroundStyle(iconColor)
                .frame(width: size, height: size)
        }
    }

    private var iconColor: Color {
        isSelected ? Color(nsColor: Theme.cursor) : .secondary
    }
}

/// 用户选择的图片文件图标（路径指向磁盘文件或托管副本）。
struct ProjectFileIconImage: View {
    let path: String
    var size: CGFloat = 22

    @State private var image: NSImage?
    @State private var didFail = false

    var body: some View {
        Group {
            if let image = displayImage {
                Image(nsImage: image)
                    .resizable()
                    .interpolation(.high)
                    .aspectRatio(contentMode: .fit)
            } else if didFail {
                Image(systemName: "photo")
                    .font(SidebarTypography.listIcon())
                    .foregroundStyle(.tertiary)
            } else {
                RoundedRectangle(cornerRadius: 4, style: .continuous)
                    .fill(Color.primary.opacity(0.05))
            }
        }
        .frame(width: size, height: size)
        .accessibilityHidden(true)
        .task(id: "f:\(path)@\(String(format: "%.1f", size))#\(ProjectIconThumbnailCache.cacheVersion)") {
            image = nil
            didFail = false
            await load()
        }
    }

    private var displayImage: NSImage? {
        let cacheKey = "f:\(path)@\(String(format: "%.1f", size))"
        if let hit = ProjectIconThumbnailCache.cachedFile(for: cacheKey) {
            return hit
        }
        return image
    }

    private func load() async {
        let filePath = path
        let pointSize = size
        let cacheKey = "f:\(filePath)@\(String(format: "%.1f", pointSize))"
        if let hit = ProjectIconThumbnailCache.cachedFile(for: cacheKey) {
            image = hit
            return
        }
        let loaded = await Task.detached(priority: .utility) {
            MaterialFileIconCatalog.loadSizedImage(
                at: URL(fileURLWithPath: filePath),
                pointSize: pointSize
            )
        }.value
        if Task.isCancelled { return }
        if let loaded {
            ProjectIconThumbnailCache.storeFile(loaded, for: cacheKey)
            image = loaded
        } else {
            didFail = true
        }
    }
}

/// 预置图标缩略图缓存：跨选择器复用，避免滚动时反复读盘/解码 SVG。
enum ProjectIconThumbnailCache {
    private static let images = NSCache<NSString, NSImage>()
    private static let templates = NSCache<NSString, NSNumber>()
    private(set) static var cacheVersion: UInt64 = 0

    /// 清理所有图片与模板缓存，确保图标更新后及时重新渲染。
    static func clearCache() {
        cacheVersion &+= 1
        images.removeAllObjects()
        templates.removeAllObjects()
    }

    static func key(for preset: ProjectPresetIcon, pointSize: CGFloat, isDarkMode: Bool = false) -> String {
        let sizeKey = String(format: "%.1f", pointSize)
        let darkSuffix = isDarkMode ? "@dark" : ""
        switch preset {
        case .material(let name):
            return "m:\(name)@\(sizeKey)\(darkSuffix)"
        case .bundled(let fileName):
            return "b:\(fileName)@\(sizeKey)\(darkSuffix)"
        }
    }

    static func cached(for key: String) -> (image: NSImage, isTemplate: Bool)? {
        guard let image = images.object(forKey: key as NSString) else { return nil }
        let isTemplate = templates.object(forKey: key as NSString)?.boolValue ?? image.isTemplate
        return (image, isTemplate)
    }

    static func store(_ image: NSImage, isTemplate: Bool, for key: String) {
        image.isTemplate = isTemplate
        images.setObject(image, forKey: key as NSString)
        templates.setObject(NSNumber(value: isTemplate), forKey: key as NSString)
    }

    /// 用户文件图标缓存（无 template 标记）。
    static func cachedFile(for key: String) -> NSImage? {
        images.object(forKey: key as NSString)
    }

    static func storeFile(_ image: NSImage, for key: String) {
        images.setObject(image, forKey: key as NSString)
    }

    /// 主线程解析 URL + template 标记；磁盘解码放到后台。
    @MainActor
    static func load(preset: ProjectPresetIcon, pointSize: CGFloat, isDarkMode: Bool = false) async -> (NSImage?, Bool) {
        let cacheKey = key(for: preset, pointSize: pointSize, isDarkMode: isDarkMode)
        if let hit = cached(for: cacheKey) {
            return (hit.image, hit.isTemplate)
        }

        let resolved: (url: URL, isTemplate: Bool)?
        switch preset {
        case .material(let name):
            if let url = MaterialFileIconCatalog.shared.fileURL(forIconName: name) {
                resolved = (url, false)
            } else {
                resolved = nil
            }
        case .bundled(let fileName):
            if let source = TerminalAppIconCatalog.shared.bundledIconSource(named: fileName) {
                let effectiveSource: TerminalAppIconSource
                switch source {
                case .imageFile(let path, let darkPath):
                    if isDarkMode, let darkPath {
                        effectiveSource = .imageFile(path: darkPath, darkPath: nil)
                    } else {
                        effectiveSource = .imageFile(path: path, darkPath: nil)
                    }
                case .material:
                    effectiveSource = source
                }
                if case .imageFile(let finalPath, _) = effectiveSource {
                    let url = URL(fileURLWithPath: finalPath)
                    let isTemplate = TerminalAppIconCatalog.shared.isBundledFileTemplate(fileName)
                    resolved = (url, isTemplate)
                } else {
                    resolved = nil
                }
            } else {
                resolved = nil
            }
        }

        guard let resolved else { return (nil, false) }
        let url = resolved.url
        let isTemplate = resolved.isTemplate
        let size = pointSize

        let image = await Task.detached(priority: .utility) {
            MaterialFileIconCatalog.loadSizedImage(at: url, pointSize: size)
        }.value

        if let image {
            image.isTemplate = isTemplate
            store(image, isTemplate: isTemplate, for: cacheKey)
        }
        return (image, isTemplate)
    }
}

/// 渲染内置预置图标（Material / TerminalAppIcons）。
/// - `lazyLoad == true`：选择器网格用，先占位再异步解码，滚动不卡主线程。
/// - `lazyLoad == false`：列表单行同步读缓存（至多一次磁盘）。
struct ProjectPresetIconImage: View {
    let preset: ProjectPresetIcon
    var size: CGFloat = 22
    var isSelected: Bool = false
    /// 网格等大批量展示时开启惰性加载。
    var lazyLoad: Bool = false

    @Environment(\.colorScheme) private var colorScheme
    @ObservedObject private var themeChanges = Theme.changes
    @ObservedObject private var settings = AppSettings.shared
    @State private var loadedImage: NSImage?
    @State private var isTemplate = false
    @State private var didFail = false

    private var isDarkMode: Bool {
        colorScheme == .dark
    }

    /// 将强制外观和实际亮暗状态同时纳入任务标识，避免惰性列表复用旧图标。
    private var appearanceID: String {
        "\(settings.theme.rawValue):\(isDarkMode ? "dark" : "light")"
    }

    var body: some View {
        let _ = themeChanges
        Group {
            if let image = displayImage {
                let template = displayIsTemplate
                Image(nsImage: image)
                    .resizable()
                    .interpolation(.high)
                    .renderingMode(template ? .template : .original)
                    .aspectRatio(contentMode: .fit)
                    .foregroundStyle(
                        template
                            ? AnyShapeStyle(isSelected ? Color(nsColor: Theme.cursor) : Theme.secondaryColor)
                            : AnyShapeStyle(Color.primary)
                    )
            } else if didFail {
                Image(systemName: "photo")
                    .font(SidebarTypography.listIcon())
                    .foregroundStyle(.tertiary)
            } else {
                // 惰性加载占位：固定尺寸，避免网格跳动。
                RoundedRectangle(cornerRadius: 4, style: .continuous)
                    .fill(Color.primary.opacity(0.05))
            }
        }
        .frame(width: size, height: size)
        .accessibilityHidden(true)
        .task(id: "\(ProjectIconThumbnailCache.key(for: preset, pointSize: size, isDarkMode: isDarkMode))#\(appearanceID)#\(ProjectIconThumbnailCache.cacheVersion)") {
            loadedImage = nil
            didFail = false
            if lazyLoad {
                await loadAsync()
            } else {
                loadSyncIfNeeded()
            }
        }
        .onAppear {
            if !lazyLoad {
                loadSyncIfNeeded()
            }
        }
    }

    private var currentCacheHit: (image: NSImage, isTemplate: Bool)? {
        let key = ProjectIconThumbnailCache.key(for: preset, pointSize: size, isDarkMode: isDarkMode)
        return ProjectIconThumbnailCache.cached(for: key)
    }

    private var displayImage: NSImage? {
        if let hit = currentCacheHit { return hit.image }
        if !lazyLoad {
            return Self.nsImage(for: preset, pointSize: size, isDarkMode: isDarkMode)
        }
        return loadedImage
    }

    private var displayIsTemplate: Bool {
        if let hit = currentCacheHit {
            return hit.isTemplate || hit.image.isTemplate
        }
        if displayImage?.isTemplate == true {
            return true
        }
        if !lazyLoad {
            return Self.isTemplate(preset)
        }
        return isTemplate
    }

    private func loadSyncIfNeeded() {
        let key = ProjectIconThumbnailCache.key(for: preset, pointSize: size, isDarkMode: isDarkMode)
        if let hit = ProjectIconThumbnailCache.cached(for: key) {
            loadedImage = hit.image
            isTemplate = hit.isTemplate
            return
        }
        if let image = Self.nsImage(for: preset, pointSize: size, isDarkMode: isDarkMode) {
            let template = Self.isTemplate(preset)
            ProjectIconThumbnailCache.store(image, isTemplate: template, for: key)
            loadedImage = image
            isTemplate = template
        } else {
            didFail = true
        }
    }

    private func loadAsync() async {
        let key = ProjectIconThumbnailCache.key(for: preset, pointSize: size, isDarkMode: isDarkMode)
        if let hit = ProjectIconThumbnailCache.cached(for: key) {
            loadedImage = hit.image
            isTemplate = hit.isTemplate
            return
        }
        let result = await ProjectIconThumbnailCache.load(preset: preset, pointSize: size, isDarkMode: isDarkMode)
        if Task.isCancelled { return }
        if let image = result.0 {
            loadedImage = image
            isTemplate = result.1
        } else {
            didFail = true
        }
    }

    @MainActor
    static func nsImage(for preset: ProjectPresetIcon, pointSize: CGFloat, isDarkMode: Bool = false) -> NSImage? {
        switch preset {
        case .material(let name):
            return MaterialFileIconCatalog.shared.image(named: name, pointSize: pointSize)
        case .bundled(let fileName):
            return TerminalAppIconCatalog.shared.imageForBundledFile(
                named: fileName,
                pointSize: pointSize,
                isDarkMode: isDarkMode
            )
        }
    }

    @MainActor
    static func isTemplate(_ preset: ProjectPresetIcon) -> Bool {
        switch preset {
        case .material:
            return false
        case .bundled(let fileName):
            return TerminalAppIconCatalog.shared.isBundledFileTemplate(fileName)
        }
    }
}

// MARK: - Preset groups & item catalog

/// 预置图标分组：品牌资源与 Material Icon Theme。
enum PresetIconGroup: String, CaseIterable, Identifiable {
    case brands
    case material

    var id: String { rawValue }

    var title: String {
        switch self {
        case .brands: return "Brands"
        case .material: return "Material"
        }
    }

    var systemImage: String {
        switch self {
        case .brands: return "app.badge"
        case .material: return "doc.richtext"
        }
    }
}

/// 预置网格条目；列表在首次访问时构建一次。
struct ProjectPresetGridItem: Identifiable, Hashable {
    let id: String
    let preset: ProjectPresetIcon
    let label: String
}

/// 预置 Brands / Material 条目缓存，避免选择器 body 反复 map 上千项。
@MainActor
enum ProjectPresetItemCatalog {
    static let brands: [ProjectPresetGridItem] = {
        let catalog = TerminalAppIconCatalog.shared
        let labels = catalog.bundledFileLabels
        return catalog.bundledIconFileNames().map { fileName in
            let bare = (fileName as NSString).deletingPathExtension
            let label = labels[fileName]
                ?? labels[(fileName as NSString).lastPathComponent]
                ?? bare.replacingOccurrences(of: "bxl-", with: "")
            return ProjectPresetGridItem(
                id: "bundled:\(fileName)",
                preset: .bundled(fileName),
                label: label
            )
        }
    }()

    static let material: [ProjectPresetGridItem] = {
        MaterialFileIconCatalog.shared.allIconNames.map { name in
            ProjectPresetGridItem(
                id: "material:\(name)",
                preset: .material(name),
                label: name
            )
        }
    }()

    static func items(in group: PresetIconGroup) -> [ProjectPresetGridItem] {
        switch group {
        case .brands: return brands
        case .material: return material
        }
    }

    static func filter(_ query: String, in group: PresetIconGroup) -> [ProjectPresetGridItem] {
        let base = items(in: group)
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return base }
        let tokens = trimmed
            .split(whereSeparator: \.isWhitespace)
            .map { String($0).lowercased() }
        return base.filter { item in
            let haystack = "\(item.label) \(item.id)".lowercased()
            return tokens.allSatisfy { haystack.contains($0) }
        }
    }
}

// MARK: - Categories

/// SF Symbol 浏览分类。`suggested` / `all` 为虚拟筛选，其余为名称规则归类。
enum SFSymbolCategory: String, CaseIterable, Identifiable {
    case suggested
    case all
    case coding
    case arrows
    case communication
    case weather
    case devices
    case transportation
    case people
    case health
    case nature
    case commerce
    case media
    case gaming
    case maps
    case time
    case security
    case connectivity
    case objects
    case editing
    case text
    case math
    case indices
    case system
    case shapes
    case other

    var id: String { rawValue }

    /// 侧栏标题。
    var title: String {
        switch self {
        case .suggested: return "Suggested"
        case .all: return "All"
        case .coding: return "Coding"
        case .arrows: return "Arrows"
        case .communication: return "Communication"
        case .weather: return "Weather"
        case .devices: return "Devices"
        case .transportation: return "Transport"
        case .people: return "People"
        case .health: return "Health"
        case .nature: return "Nature"
        case .commerce: return "Commerce"
        case .media: return "Media"
        case .gaming: return "Gaming"
        case .maps: return "Maps"
        case .time: return "Time"
        case .security: return "Security"
        case .connectivity: return "Network"
        case .objects: return "Objects"
        case .editing: return "Editing"
        case .text: return "Text"
        case .math: return "Math"
        case .indices: return "Indices"
        case .system: return "System"
        case .shapes: return "Shapes"
        case .other: return "Other"
        }
    }

    /// 分类行左侧示意图标。
    var systemImage: String {
        switch self {
        case .suggested: return "star"
        case .all: return "square.grid.2x2"
        case .coding: return "chevron.left.forwardslash.chevron.right"
        case .arrows: return "arrow.left.arrow.right"
        case .communication: return "bubble.left.and.bubble.right"
        case .weather: return "cloud.sun"
        case .devices: return "desktopcomputer"
        case .transportation: return "car"
        case .people: return "person.2"
        case .health: return "heart"
        case .nature: return "leaf"
        case .commerce: return "cart"
        case .media: return "play.circle"
        case .gaming: return "gamecontroller"
        case .maps: return "map"
        case .time: return "clock"
        case .security: return "lock"
        case .connectivity: return "wifi"
        case .objects: return "shippingbox"
        case .editing: return "paintbrush"
        case .text: return "textformat"
        case .math: return "function"
        case .indices: return "number"
        case .system: return "gearshape"
        case .shapes: return "circle.grid.cross"
        case .other: return "ellipsis.circle"
        }
    }

    /// 是否不参与规则归类（仅作筛选入口）。
    var isVirtual: Bool {
        self == .suggested || self == .all
    }

    /// 规则归类用的分类顺序（先匹配优先；Shapes 等宽泛类靠后）。
    nonisolated static let assignmentOrder: [SFSymbolCategory] = [
        .coding,
        .arrows,
        .communication,
        .weather,
        .devices,
        .transportation,
        .people,
        .health,
        .nature,
        .commerce,
        .media,
        .gaming,
        .maps,
        .time,
        .security,
        .connectivity,
        .objects,
        .editing,
        .text,
        .math,
        .indices,
        .system,
        .shapes,
    ]

    /// 名称中命中任一词缀则归入此类（按 `assignmentOrder` 首次命中生效）。
    var matchTokens: [String] {
        switch self {
        case .suggested, .all, .other:
            return []
        case .coding:
            return [
                "terminal", "swift", "hammer", "cpu", "memorychip", "server",
                "externaldrive", "internaldrive", "command", "curlybraces",
                "function", "chevron.left.forwardslash", "applescript",
                "laptopcomputer", "desktopcomputer", "keyboard",
            ]
        case .arrows:
            return [
                "arrow", "chevron", "arrowshape", "arrowtriangle",
                "return", "forward", "backward", "increase", "decrease",
            ]
        case .communication:
            return [
                "phone", "message", "mail", "envelope", "bubble", "mic",
                "video", "ellipsis.bubble", "recordingtape", "megaphone",
                "bell", "antenna",
            ]
        case .weather:
            return [
                "sun", "moon", "cloud", "rain", "snow", "wind", "bolt",
                "thermometer", "hurricane", "tornado", "humidity", "rainbow",
                "aqi", "carbon", "smoke", "fog", "haze", "snowflake",
            ]
        case .devices:
            return [
                "iphone", "ipad", "macbook", "macpro", "macmini", "macstudio",
                "imac", "applewatch", "airpods", "homepod", "appletv", "tv",
                "display", "desktopcomputer", "laptopcomputer", "pc",
                "headphones", "hifispeaker", "printer", "faxmachine", "scanner",
                "flipphone", "candybarphone", "vision", "headset", "beats",
            ]
        case .transportation:
            return [
                "car", "bus", "tram", "train", "airplane", "bicycle", "scooter",
                "fuel", "ferry", "sailboat", "truck", "suv", "box.truck",
                "cablecar", "figure.walk", "figure.run", "parkingsign",
                "steeringwheel", "engine", "ev.", "road", "traffic",
                "convertible", "carseat", "pedestrian", "motorcycle",
            ]
        case .people:
            return [
                "person", "figure", "hand", "eye", "ear", "brain", "face",
                "mustache", "nose", "mouth", "teeth", "beard", "eyebrow",
                "tshirt", "shoe", "comb", "head.profile",
            ]
        case .health:
            return [
                "heart", "cross.case", "pills", "stethoscope", "syringe",
                "allergens", "medical", "ivfluid", "staroflife", "waveform.path.ecg",
                "bed.double", "cross", "bandage", "facemask", "lungs",
                "blood", "microbe",
            ]
        case .nature:
            return [
                "leaf", "tree", "flame", "drop", "water", "mountain", "fish",
                "bird", "pawprint", "carrot", "camera.macro", "fossil",
                "laurel", "humidity", "tortoise", "lizard", "ant", "ladybug",
                "atom", "globe.americas", "globe.europe", "globe.asia",
            ]
        case .commerce:
            return [
                "cart", "bag", "creditcard", "banknote", "dollarsign", "yensign",
                "sterlingsign", "eurosign", "cent", "bitcoinsign", "dongsign",
                "francsign", "guaranisign", "kipsign", "livresign", "manatsign",
                "millsign", "nairasign", "pesetasign", "pesosign", "rublesign",
                "rupeesign", "shekelsign", "tengesign", "tugriksign", "won",
                "baht", "lari", "hryvnia", "colon", "cruzeiro", "tugrik",
                "swedishkrona", "danishkrone", "norwegiankrone", "polishzloty",
                "brazilianreal", "chineseyuan", "indianrupee", "australiandollar",
                "storefront", "giftcard", "barcode", "qrcode",
            ]
        case .media:
            return [
                "play", "pause", "stop", "record", "backward.end", "forward.end",
                "music", "photo", "camera", "film", "speaker", "waveform",
                "guitars", "pianokeys", "tuningfork", "opticaldisc", "tv.music",
                "movie", "livephoto", "panorama", "rectangle.stack", "shuffle",
                "repeat", "caption", "subtitle", "airplay",
            ]
        case .gaming:
            return [
                "gamecontroller", "dice", "flag.checkered", "arcade",
                "l.joystick", "r.joystick", "l.button", "r.button",
                "button.horizontal", "button.rounded", "circle.circle",
                "dpad", "ps.button", "xbox",
            ]
        case .maps:
            return [
                "map", "location", "mappin", "signpost", "globe", "compass",
                "binoculars", "point.topleft", "road.lanes", "fence",
            ]
        case .time:
            return [
                "clock", "timer", "alarm", "stopwatch", "hourglass", "calendar",
                "deskclock",
            ]
        case .security:
            return [
                "lock", "key", "shield", "touchid", "faceid", "opticid",
                "key.horizontal", "key.radiowaves", "lock.rectangle",
                "lock.square", "lock.triangle", "lock.doc", "lock.icloud",
                "checkmark.shield", "xmark.shield", "firewall",
            ]
        case .connectivity:
            return [
                "wifi", "bluetooth", "personalhotspot", "link", "cable",
                "network", "antenna.radiowaves", "dot.radiowaves", "bonjour",
                "wave.3", "externaldrive.connected", "cable.connector",
            ]
        case .objects:
            return [
                "folder", "doc", "book", "tray", "archivebox", "shippingbox",
                "cube", "gift", "tag", "paperclip", "tray.full", "tray.2",
                "newspaper", "note", "scroll", "backpack", "briefcase",
                "suitcase", "basket", "washer", "dryer", "dishwasher",
                "oven", "stove", "microwave", "refrigerator", "toilet",
                "sink", "shower", "bathtub", "lamp", "lightbulb", "fan",
                "air.conditioner", "humidifier", "dehumidifier", "spigot",
                "poweroutlet", "powercord", "lightswitch", "button.programmable",
                "sensor", "cabinet", "chair", "sofa", "table", "fireplace",
                "window", "door", "stairs", "house", "building", "storefront",
                "tent", "cup.and.saucer", "mug", "wineglass", "fork.knife",
                "takeoutbag", "popcorn", "birthday.cake",
            ]
        case .editing:
            return [
                "pencil", "paintbrush", "highlighter", "crop", "slider",
                "wand", "scissors", "lasso", "scribble", "eraser", "ruler",
                "level", "rotate", "perspective", "skew", "loupe",
                "selection", "aspectratio", "rectangle.dashed",
            ]
        case .text:
            return [
                "text", "character", "quote", "bold", "italic", "underline",
                "strikethrough", "list", "paragraph", "textformat", "a.magnify",
                "fleuron", "signature", "bookmark", "spellcheck",
            ]
        case .math:
            return [
                "plus", "minus", "multiply", "divide", "equal", "function",
                "sum", "x.squareroot", "number", "percent", "angle",
                "compass.drawing", "average", "sigma",
            ]
        case .indices:
            // 数字 / 字母索引类符号（0.circle、a.square 等）。
            return []
        case .system:
            return [
                "gear", "switch", "power", "command", "option", "control",
                "eject", "sidebar", "menubar", "dock", "rectangle.split",
                "uiwindow", "macwindow", "filemenu", "lines.measurement",
                "info.circle", "questionmark", "exclamationmark", "plus.circle",
                "minus.circle", "xmark", "checkmark", "asterisk",
            ]
        case .shapes:
            return [
                "circle", "square", "triangle", "hexagon", "diamond", "oval",
                "rectangle", "capsule", "seal", "pentagon", "octagon",
                "rhombus", "seal.fill", "app", "button.roundedtop",
            ]
        }
    }

    /// 是否匹配给定 SF Symbol 名称。
    func matches(_ name: String) -> Bool {
        if self == .indices {
            return Self.isIndexSymbol(name)
        }
        let tokens = matchTokens
        guard !tokens.isEmpty else { return false }
        for token in tokens {
            if Self.name(name, matchesToken: token) {
                return true
            }
        }
        return false
    }

    /// token 作为完整段、前缀或子串命中（小写比较）。
    private static func name(_ name: String, matchesToken token: String) -> Bool {
        let n = name.lowercased()
        let t = token.lowercased()
        if n == t || n.hasPrefix(t + ".") || n.contains("." + t + ".") || n.hasSuffix("." + t) {
            return true
        }
        // 允许 "chevron.left.forwardslash" 这类多段 token。
        if t.contains(".") {
            return n.contains(t)
        }
        // 单词级 contains，避免过短误伤；长度 ≥ 3 才做裸 contains。
        if t.count >= 3, n.contains(t) {
            return true
        }
        return false
    }

    /// 形如 `12.circle` / `a.square.fill` 的索引符号。
    private static func isIndexSymbol(_ name: String) -> Bool {
        let head = name.split(separator: ".", maxSplits: 1).first.map(String.init) ?? name
        if head.allSatisfy(\.isNumber) { return true }
        if head.count == 1, head.first?.isLetter == true { return true }
        // 01.circle.hi 这类本地化变体。
        if head.count == 2, head.allSatisfy(\.isNumber) { return true }
        return false
    }
}

// MARK: - SF Symbol catalog

/// 打包的 SF Symbol 名称目录，供图标选择器离线完整浏览与分类。
@MainActor
final class SFSymbolCatalog {
    static let shared = SFSymbolCatalog()

    /// 适合作为项目图标的常用推荐。
    nonisolated static let suggestedNames: [String] = [
        "folder",
        "folder.fill",
        "terminal",
        "chevron.left.forwardslash.chevron.right",
        "swift",
        "hammer",
        "globe",
        "app",
        "shippingbox",
        "server.rack",
        "cpu",
        "memorychip",
        "doc.text",
        "book",
        "star",
        "heart",
        "bolt",
        "leaf",
        "flame",
        "puzzlepiece",
        "cube",
        "archivebox",
        "tray.full",
        "paintbrush",
        "wand.and.stars",
        "gearshape",
        "command",
        "keyboard",
        "network",
        "antenna.radiowaves.left.and.right",
        "externaldrive",
        "internaldrive",
        "cloud",
        "lock",
        "key",
        "person.2",
        "building.2",
        "map",
        "flag",
        "tag",
        "bell",
        "bubble.left.and.bubble.right",
        "chart.bar",
        "chart.line.uptrend.xyaxis",
        "photo",
        "music.note",
        "gamecontroller",
        "car",
        "airplane",
        "bicycle",
    ]

    private(set) var isLoaded = false
    private var allNamesCache: [String] = []
    private var namesByCategoryCache: [SFSymbolCategory: [String]] = [:]

    private init() {}

    /// 后台异步装载全量 SF Symbol 分类索引。
    func loadCatalogIfNeeded() async {
        guard !isLoaded else { return }
        let (all, buckets) = await Task.detached(priority: .utility) {
            let names: [String]
            if let url = Bundle.main.url(forResource: "SFSymbolCatalog", withExtension: "json"),
               let data = try? Data(contentsOf: url),
               let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                names = object.keys.sorted()
            } else {
                names = []
            }

            var map: [SFSymbolCategory: [String]] = [:]
            for category in SFSymbolCategory.allCases {
                map[category] = []
            }
            map[.suggested] = Self.suggestedNames
            map[.all] = names

            for name in names {
                var assigned: SFSymbolCategory = .other
                for category in SFSymbolCategory.assignmentOrder {
                    if category.matches(name) {
                        assigned = category
                        break
                    }
                }
                map[assigned, default: []].append(name)
            }
            return (names, map)
        }.value

        allNamesCache = all
        namesByCategoryCache = buckets
        isLoaded = true
    }

    /// 指定分类下的符号数量。
    func count(in category: SFSymbolCategory) -> Int {
        if category == .suggested { return Self.suggestedNames.count }
        if !isLoaded {
            if category == .all { return Self.suggestedNames.count }
            return 0
        }
        return namesByCategoryCache[category]?.count ?? 0
    }

    /// 在分类内按查询过滤；空查询返回该分类完整列表。多词空格分隔，要求全部命中。
    func filter(_ query: String, in category: SFSymbolCategory) -> [String] {
        let base: [String]
        if category == .suggested {
            base = Self.suggestedNames
        } else if isLoaded {
            base = namesByCategoryCache[category] ?? []
        } else {
            base = Self.suggestedNames
        }
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return base }
        let tokens = trimmed
            .split(whereSeparator: \.isWhitespace)
            .map { String($0).lowercased() }
        guard !tokens.isEmpty else { return base }
        return base.filter { name in
            let lower = name.lowercased()
            return tokens.allSatisfy { lower.contains($0) }
        }
    }
}

// MARK: - Picker sheet

/// 为项目选择预置 / SF Symbol / Emoji 的面板。
struct ProjectIconPicker: View {
    /// 图标来源分段（与原生 segmented Picker 的四个选项对应）。
    private enum Source: String, CaseIterable, Identifiable {
        case preset = "Preset"
        case sfSymbols = "SF Symbols"
        case emoji = "Emoji"
        case file = "Select File"

        var id: Self { self }

        var title: String {
            L10n.t(rawValue)
        }
    }

    /// 选择器尺寸：内容区固定高度，切换类型时窗口不抖动。
    private enum Metrics {
        /// 四类 tabs（含 Select File）略加宽，避免液态玻璃标签挤在一起。
        static let width: CGFloat = 600
        /// header + tabs + content + footer 中内容区恒定高度。
        static let contentHeight: CGFloat = 420
        static let gridSpacing: CGFloat = 8
        static let cellMinHeight: CGFloat = 40
        static let sidebarWidth: CGFloat = 148
        static let columnCount = 6
    }

    @ObservedObject var project: Project
    @Environment(\.dismiss) private var dismiss

    @State private var source: Source
    @State private var symbolName: String
    @State private var symbolSearch: String
    /// 防抖后的检索串，避免 9k+ 目录在每次按键时全量过滤。
    @State private var debouncedSearch: String
    @State private var selectedCategory: SFSymbolCategory = .suggested
    @State private var selectedPresetGroup: PresetIconGroup = .brands
    @State private var presetSearch: String = ""
    @State private var debouncedPresetSearch: String = ""
    /// 防抖后的预置列表，避免每次 body 过滤 1k+ 项。
    @State private var displayedPresetItems: [ProjectPresetGridItem] = []
    /// 防抖后的 SF Symbol 列表。
    @State private var displayedSymbols: [String] = []
    @State private var emoji: String
    /// 当前选中的用户文件路径（未 Apply 前的预览；Apply 后写入 project.icon）。
    @State private var selectedFilePath: String = ""
    @State private var fileImportError: String?
    /// 共享后台任务（与项目列表右键同一套状态）。
    @ObservedObject private var aiIconTasks = LocalAIIconTaskStore.shared
    /// 本面板发起的 AI 任务成功后是否自动关闭（取消不关）。
    @State private var dismissOnAISuccess = false
    @FocusState private var emojiFieldFocused: Bool
    @FocusState private var symbolSearchFocused: Bool

    private let columns = Array(
        repeating: GridItem(.flexible(minimum: 36), spacing: Metrics.gridSpacing),
        count: Metrics.columnCount
    )

    init(project: Project) {
        self.project = project
        // 打开时带入当前图标，方便在原基础上改名或换一类。
        switch project.icon {
        case .preset(let preset):
            _source = State(initialValue: .preset)
            _symbolName = State(initialValue: "folder")
            _emoji = State(initialValue: "")
            switch preset {
            case .bundled:
                _selectedPresetGroup = State(initialValue: .brands)
            case .material:
                _selectedPresetGroup = State(initialValue: .material)
            }
        case .sfSymbol(let name):
            _source = State(initialValue: .sfSymbols)
            _symbolName = State(initialValue: name)
            _emoji = State(initialValue: "")
            // 有已选 SF Symbol 时定位到其所在分类，便于对照替换。
            _selectedCategory = State(initialValue: Self.category(containing: name))
        case .emoji(let value):
            _source = State(initialValue: .emoji)
            _symbolName = State(initialValue: "folder")
            _emoji = State(initialValue: value)
        case .file(let path):
            _source = State(initialValue: .file)
            _symbolName = State(initialValue: "folder")
            _emoji = State(initialValue: "")
            _selectedFilePath = State(initialValue: path)
        case nil:
            // 默认打开预置页，优先展示本应用内置图标。
            _source = State(initialValue: .preset)
            _symbolName = State(initialValue: "folder")
            _emoji = State(initialValue: "")
        }
        _symbolSearch = State(initialValue: "")
        _debouncedSearch = State(initialValue: "")
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            header

            // 使用传统原生分段控件，采用系统中号尺寸与标准交互。
            Picker(L10n.t("Icon type"), selection: $source) {
                ForEach(Source.allCases) { item in
                    Text(item.title)
                        .tag(item)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .controlSize(.regular)
            .frame(width: 372)
            .frame(maxWidth: .infinity)

            // 固定高度内容区：切换类型时窗口尺寸不变。
            Group {
                switch source {
                case .preset:
                    presetPicker
                case .sfSymbols:
                    sfSymbolPicker
                case .emoji:
                    emojiPicker
                case .file:
                    filePicker
                }
            }
            .frame(height: Metrics.contentHeight, alignment: .top)
            .frame(maxWidth: .infinity)
            .clipped()
            // 禁止内容切换带动画改高，避免与液态玻璃 tabs 叠成抖动。
            .transaction { transaction in
                if transaction.animation != nil {
                    transaction.animation = nil
                }
            }

            footer
        }
        .padding(18)
        .frame(width: Metrics.width)
        .onAppear {
            refreshPresetItems()
            refreshSymbolItems()
            Task {
                await SFSymbolCatalog.shared.loadCatalogIfNeeded()
                refreshSymbolItems()
            }
        }
        .onChange(of: symbolSearch) { _, newValue in
            // 短延迟后再写 debouncedSearch，输入过程中少做过滤。
            let snapshot = newValue
            Task { @MainActor in
                try? await Task.sleep(for: .milliseconds(160))
                guard symbolSearch == snapshot else { return }
                debouncedSearch = snapshot
                refreshSymbolItems()
            }
        }
        .onChange(of: selectedCategory) { _, _ in
            refreshSymbolItems()
        }
        .onChange(of: presetSearch) { _, newValue in
            let snapshot = newValue
            Task { @MainActor in
                try? await Task.sleep(for: .milliseconds(160))
                guard presetSearch == snapshot else { return }
                debouncedPresetSearch = snapshot
                refreshPresetItems()
            }
        }
        .onChange(of: selectedPresetGroup) { _, _ in
            refreshPresetItems()
        }
    }

    private func refreshPresetItems() {
        displayedPresetItems = ProjectPresetItemCatalog.filter(
            debouncedPresetSearch,
            in: selectedPresetGroup
        )
    }

    private func refreshSymbolItems() {
        displayedSymbols = SFSymbolCatalog.shared.filter(debouncedSearch, in: selectedCategory)
    }

    // MARK: Header / footer

    private var isAISelectingIcon: Bool {
        aiIconTasks.isRunning(project.id)
    }

    private var aiSelectError: String? {
        aiIconTasks.state(for: project.id).lastError
    }

    private var header: some View {
        HStack(alignment: .center, spacing: 12) {
            currentIconPreview
            VStack(alignment: .leading, spacing: 2) {
                Text(L10n.t("Project Icon"))
                    .font(SidebarTypography.title())
                if isAISelectingIcon {
                    // 进行中：显示 provider + 后台运行说明
                    Text(
                        aiIconTasks.state(for: project.id).providerLabel
                            .map { "Selecting with \($0)…" }
                            ?? "AI selecting icon…"
                    )
                    .font(SidebarTypography.caption())
                    .foregroundStyle(Color(nsColor: Theme.cursor))
                    .lineLimit(1)
                } else {
                    Text(project.name)
                        .font(SidebarTypography.caption())
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                if let aiSelectError, !isAISelectingIcon {
                    Text(aiSelectError)
                        .font(SidebarTypography.caption())
                        .foregroundStyle(.red.opacity(0.9))
                        .lineLimit(2)
                }
            }
            Spacer(minLength: 0)
            if isAISelectingIcon {
                Button(L10n.t("Cancel")) {
                    aiIconTasks.cancel(project.id)
                }
                .keyboardShortcut(.cancelAction)
            } else {
                Button {
                    startAISelectIcon()
                } label: {
                    HStack(spacing: 5) {
                        Image(systemName: "sparkles")
                        Text(L10n.t("AI Select"))
                    }
                }
                .disabled(!LocalAI.isEnabled)
                .help(
                    LocalAI.isEnabled
                        ? L10n.t("Use the configured AI provider to pick an icon (runs in background)")
                        : L10n.t("Configure an AI provider in Settings → AI")
                )
            }
            if project.icon != nil {
                Button(L10n.t("Clear")) {
                    clearIcon()
                }
                .disabled(isAISelectingIcon)
            }
        }
        .onChange(of: aiIconTasks.states[project.id]?.isRunning) { wasRunning, isRunning in
            // 仅本面板发起且成功结束时关闭；取消或失败保持打开
            guard dismissOnAISuccess, wasRunning == true, isRunning == false else { return }
            dismissOnAISuccess = false
            if aiIconTasks.state(for: project.id).lastError == nil {
                dismiss()
            }
        }
    }

    /// 提交后台 AI 选图标（不阻塞选择器；成功后自动 dismiss）。
    private func startAISelectIcon() {
        aiIconTasks.clearError(project.id)
        dismissOnAISuccess = true
        aiIconTasks.start(for: project)
    }

    /// 当前项目图标（或默认 folder）的大预览；AI 进行中叠转圈。
    private var currentIconPreview: some View {
        ZStack {
            Group {
                switch project.icon {
                case .sfSymbol(let name):
                    Image(systemName: name)
                        .font(SidebarTypography.pickerIcon())
                case .emoji(let value):
                    Text(value)
                        .font(SidebarTypography.pickerEmojiPreview())
                        .lineLimit(1)
                        .minimumScaleFactor(0.5)
                case .preset(let preset):
                    ProjectPresetIconImage(preset: preset, size: 28, isSelected: true)
                case .file(let path):
                    ProjectFileIconImage(path: path, size: 28)
                case nil:
                    Image(systemName: "folder")
                        .font(SidebarTypography.pickerIcon())
                        .foregroundStyle(.secondary)
                }
            }
            .opacity(isAISelectingIcon ? 0.25 : 1)

            if isAISelectingIcon {
                ProgressView()
                    .controlSize(.small)
            }
        }
        .frame(width: 40, height: 40)
        .background(
            Color.primary.opacity(0.05),
            in: RoundedRectangle(cornerRadius: 8, style: .continuous)
        )
    }

    // MARK: Preset (bundled)

    private var presetPicker: some View {
        HStack(alignment: .top, spacing: 12) {
            presetGroupSidebar
            presetBrowser
        }
        .frame(maxHeight: .infinity, alignment: .top)
    }

    private var presetGroupSidebar: some View {
        VStack(spacing: 1) {
            ForEach(PresetIconGroup.allCases) { group in
                let isSelected = selectedPresetGroup == group
                let count = ProjectPresetItemCatalog.items(in: group).count
                Button {
                    selectedPresetGroup = group
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: group.systemImage)
                            .font(SidebarTypography.caption())
                            .frame(width: 14, alignment: .center)
                            .foregroundStyle(isSelected ? Color(nsColor: Theme.cursor) : .secondary)
                        Text(group.title)
                            .font(SidebarTypography.caption(.medium))
                            .foregroundStyle(isSelected ? .primary : .secondary)
                            .lineLimit(1)
                        Spacer(minLength: 0)
                        Text("\(count)")
                            .font(SidebarTypography.micro().monospacedDigit())
                            .foregroundStyle(.tertiary)
                    }
                    .padding(.horizontal, 8)
                    .padding(.vertical, 5)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .background(
                    RoundedRectangle(cornerRadius: 5, style: .continuous)
                        .fill(isSelected ? Color.primary.opacity(0.08) : .clear)
                )
                .padding(.horizontal, 4)
            }
            Spacer(minLength: 0)
        }
        .padding(.vertical, 4)
        .frame(width: Metrics.sidebarWidth)
        .frame(maxHeight: .infinity, alignment: .top)
        .background(
            Color.primary.opacity(0.04),
            in: RoundedRectangle(cornerRadius: 8, style: .continuous)
        )
    }

    private var presetBrowser: some View {
        VStack(alignment: .leading, spacing: 8) {
            TextField("Search \(selectedPresetGroup.title)", text: $presetSearch)
                .textFieldStyle(.roundedBorder)

            Text(presetResultCountLabel)
                .font(SidebarTypography.caption())
                .foregroundStyle(.secondary)

            ZStack {
                ScrollView {
                    LazyVGrid(columns: columns, spacing: Metrics.gridSpacing) {
                        ForEach(displayedPresetItems) { item in
                            presetCell(item)
                        }
                    }
                    .padding(.trailing, 2)
                }

                if displayedPresetItems.isEmpty {
                    Text(L10n.t("No icons"))
                        .font(SidebarTypography.secondary())
                        .foregroundStyle(.tertiary)
                        .allowsHitTesting(false)
                }
            }
            .frame(maxHeight: .infinity)
        }
        .frame(maxHeight: .infinity, alignment: .top)
    }

    private var presetResultCountLabel: String {
        let total = ProjectPresetItemCatalog.items(in: selectedPresetGroup).count
        let shown = displayedPresetItems.count
        let query = debouncedPresetSearch.trimmingCharacters(in: .whitespacesAndNewlines)
        if query.isEmpty {
            return "\(shown) in \(selectedPresetGroup.title)"
        }
        return "\(shown) of \(total) in \(selectedPresetGroup.title)"
    }

    private func presetCell(_ item: ProjectPresetGridItem) -> some View {
        let isCurrent: Bool = {
            if case .preset(let preset) = project.icon {
                return preset == item.preset
            }
            return false
        }()
        return Button {
            select(.preset(item.preset))
        } label: {
            // 惰性异步解码 SVG；占位固定高度，滚动时不卡主线程。
            ProjectPresetIconImage(
                preset: item.preset,
                size: 22,
                isSelected: isCurrent,
                lazyLoad: true
            )
            .frame(maxWidth: .infinity)
            .frame(height: Metrics.cellMinHeight)
            .contentShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
        }
        .buttonStyle(.plain)
        .help(item.label)
        .background(
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .fill(
                    isCurrent
                        ? Color(nsColor: Theme.cursor).opacity(0.18)
                        : Color.primary.opacity(0.05)
                )
        )
        .overlay {
            if isCurrent {
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .strokeBorder(Color(nsColor: Theme.cursor).opacity(0.55), lineWidth: 1)
            }
        }
    }

    private var footer: some View {
        HStack {
            Spacer()
            Button(L10n.t("Cancel")) { dismiss() }
                .keyboardShortcut(.cancelAction)
        }
    }

    // MARK: SF Symbols

    private var sfSymbolPicker: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Image(systemName: symbolName.isEmpty ? "questionmark" : symbolName)
                    .font(SidebarTypography.pickerIcon())
                    .frame(width: 28)
                    .foregroundStyle(symbolName.isEmpty ? .tertiary : .primary)
                TextField("SF Symbol name", text: $symbolName)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit { useSymbolName() }
                Button(L10n.t("Use")) { useSymbolName() }
                    .disabled(!canUseSymbolName)
                    .keyboardShortcut(.defaultAction)
            }

            HStack(alignment: .top, spacing: 12) {
                categorySidebar
                symbolBrowser
            }
            .frame(maxHeight: .infinity)
        }
        .frame(maxHeight: .infinity, alignment: .top)
    }

    /// 左侧分类列表。
    private var categorySidebar: some View {
        ScrollView(showsIndicators: false) {
            LazyVStack(spacing: 1) {
                ForEach(SFSymbolCategory.allCases) { category in
                    categoryRow(category)
                }
            }
            .padding(.vertical, 4)
        }
        .frame(width: Metrics.sidebarWidth)
        .frame(maxHeight: .infinity)
        .background(
            Color.primary.opacity(0.04),
            in: RoundedRectangle(cornerRadius: 8, style: .continuous)
        )
    }

    private func categoryRow(_ category: SFSymbolCategory) -> some View {
        let isSelected = selectedCategory == category
        let count = SFSymbolCatalog.shared.count(in: category)
        return Button {
            selectedCategory = category
        } label: {
            HStack(spacing: 6) {
                Image(systemName: category.systemImage)
                    .font(SidebarTypography.caption())
                    .frame(width: 14, alignment: .center)
                    .foregroundStyle(isSelected ? Color(nsColor: Theme.cursor) : .secondary)
                Text(category.title)
                    .font(SidebarTypography.caption(.medium))
                    .foregroundStyle(isSelected ? .primary : .secondary)
                    .lineLimit(1)
                Spacer(minLength: 0)
                Text("\(count)")
                    .font(SidebarTypography.micro().monospacedDigit())
                    .foregroundStyle(.tertiary)
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 5)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .background(
            RoundedRectangle(cornerRadius: 5, style: .continuous)
                .fill(isSelected ? Color.primary.opacity(0.08) : .clear)
        )
        .padding(.horizontal, 4)
    }

    /// 右侧：检索 + 当前分类网格。
    private var symbolBrowser: some View {
        VStack(alignment: .leading, spacing: 8) {
            TextField(
                "Search \(selectedCategory.title)",
                text: $symbolSearch
            )
            .textFieldStyle(.roundedBorder)
            .focused($symbolSearchFocused)

            Text(resultCountLabel)
                .font(SidebarTypography.caption())
                .foregroundStyle(.secondary)

            ZStack {
                ScrollView {
                    // LazyVGrid：仅物化可见 cell；SF Symbol 由系统字体渲染，无需异步。
                    LazyVGrid(columns: columns, spacing: Metrics.gridSpacing) {
                        ForEach(displayedSymbols, id: \.self) { symbol in
                            symbolCell(symbol)
                        }
                    }
                    .padding(.trailing, 2)
                }

                if displayedSymbols.isEmpty {
                    Text(L10n.t("No symbols"))
                        .font(SidebarTypography.secondary())
                        .foregroundStyle(.tertiary)
                        .allowsHitTesting(false)
                }
            }
            .frame(maxHeight: .infinity)
        }
        .frame(maxHeight: .infinity, alignment: .top)
    }

    private var resultCountLabel: String {
        let total = SFSymbolCatalog.shared.count(in: selectedCategory)
        let shown = displayedSymbols.count
        let query = debouncedSearch.trimmingCharacters(in: .whitespacesAndNewlines)
        if query.isEmpty {
            return "\(shown) in \(selectedCategory.title)"
        }
        return "\(shown) of \(total) in \(selectedCategory.title)"
    }

    private var canUseSymbolName: Bool {
        !symbolName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private func symbolCell(_ symbol: String) -> some View {
        let isCurrent: Bool = {
            if case .sfSymbol(let name) = project.icon {
                return name == symbol
            }
            return false
        }()
        return Button {
            select(.sfSymbol(symbol))
        } label: {
            Image(systemName: symbol)
                .font(SidebarTypography.pickerGridIcon())
                .frame(maxWidth: .infinity)
                .frame(height: Metrics.cellMinHeight)
                .contentShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
        }
        .buttonStyle(.plain)
        .help(symbol)
        .background(
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .fill(
                    isCurrent
                        ? Color(nsColor: Theme.cursor).opacity(0.18)
                        : Color.primary.opacity(0.05)
                )
        )
        .overlay {
            if isCurrent {
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .strokeBorder(Color(nsColor: Theme.cursor).opacity(0.55), lineWidth: 1)
            }
        }
    }

    private func useSymbolName() {
        let name = symbolName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { return }
        select(.sfSymbol(name))
    }

    /// 解析符号所属的实体分类；推荐列表中的项优先落到 Suggested。
    private static func category(containing name: String) -> SFSymbolCategory {
        if SFSymbolCatalog.suggestedNames.contains(name) {
            return .suggested
        }
        for category in SFSymbolCategory.assignmentOrder {
            if category.matches(name) {
                return category
            }
        }
        return .other
    }

    // MARK: Emoji

    private var emojiPicker: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(L10n.t("Use the macOS Character Viewer to browse and search every Emoji and symbol."))
                .font(SidebarTypography.secondary())
                .foregroundStyle(.secondary)

            HStack(spacing: 8) {
                TextField("Emoji", text: $emoji)
                    .textFieldStyle(.roundedBorder)
                    .focused($emojiFieldFocused)
                    .onSubmit { selectEmoji() }
                Button(L10n.t("Use")) { selectEmoji() }
                    .disabled(emoji.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    .keyboardShortcut(.defaultAction)
            }

            HStack(spacing: 12) {
                Text(emoji.isEmpty ? "😀" : emoji)
                    .font(SidebarTypography.pickerEmojiPreview())
                    .lineLimit(1)
                    .minimumScaleFactor(0.5)
                    .frame(width: 46, height: 46)
                    .background(
                        Color.primary.opacity(0.05),
                        in: RoundedRectangle(cornerRadius: 8, style: .continuous)
                    )
                Button(L10n.t("Browse All Emoji & Symbols…")) {
                    emojiFieldFocused = true
                    DispatchQueue.main.async {
                        NSApp.orderFrontCharacterPalette(nil)
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }

    // MARK: Select File

    @State private var isFileDropTargeted = false

    /// 重新设计的自定义图片/文件图标选择面板（Native English UI）。
    private var filePicker: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(L10n.t("Choose an image file (PNG, JPEG, SVG, ICNS, WebP) as the project icon. The file is copied to your Qjiao config folder."))
                .font(SidebarTypography.secondary())
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            if selectedFilePath.isEmpty {
                dropZoneCard
            } else {
                selectedFileCard
            }

            if let fileImportError {
                HStack(spacing: 6) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(SidebarTypography.caption())
                    Text(fileImportError)
                        .font(SidebarTypography.caption())
                }
                .foregroundStyle(.red)
                .padding(.horizontal, 4)
            }

            Spacer(minLength: 0)

            HStack(alignment: .center) {
                if !selectedFilePath.isEmpty {
                    Text(L10n.t("Click “Apply File Icon” to save changes"))
                        .font(SidebarTypography.caption())
                        .foregroundStyle(.tertiary)
                }

                Spacer()

                Button(L10n.t("Apply File Icon")) {
                    applySelectedFile()
                }
                .buttonStyle(.borderedProminent)
                .disabled(selectedFilePath.isEmpty)
                .keyboardShortcut(.defaultAction)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .background {
            // 隐式绑定 ⌘V 全局快捷键实现一键从剪贴板粘贴
            Button("") {
                pasteImageFromClipboard()
            }
            .keyboardShortcut("v", modifiers: .command)
            .opacity(0)
        }
    }

    /// 未选择文件时的拖拽与点击大卡片 Drop Zone。
    private var dropZoneCard: some View {
        VStack(spacing: 12) {
            Button {
                openImageFilePanel()
            } label: {
                VStack(spacing: 12) {
                    ZStack {
                        Circle()
                            .fill(Color(nsColor: Theme.cursor).opacity(isFileDropTargeted ? 0.2 : 0.08))
                            .frame(width: 50, height: 50)

                        Image(systemName: isFileDropTargeted ? "square.and.arrow.down.fill" : "photo.badge.plus")
                            .font(.system(size: 22, weight: .regular))
                            .foregroundStyle(Color(nsColor: Theme.cursor))
                    }

                    VStack(spacing: 4) {
                        Text(isFileDropTargeted ? "Drop image to import" : "Drag & drop image here, or click to browse")
                            .font(SidebarTypography.body(.medium))
                            .foregroundStyle(.primary)

                        Text(L10n.t("Supports PNG, JPEG, SVG, ICNS, WebP & more"))
                            .font(SidebarTypography.caption())
                            .foregroundStyle(.secondary)
                    }
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            Button {
                pasteImageFromClipboard()
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: "doc.on.clipboard.fill")
                    Text(L10n.t("Paste Image from Clipboard"))
                    Text("⌘V")
                        .font(SidebarTypography.micro().monospacedDigit())
                        .opacity(0.75)
                }
                .font(SidebarTypography.body(.medium))
                .foregroundStyle(Color(nsColor: Theme.cursor))
                .padding(.horizontal, 14)
                .padding(.vertical, 6)
                .background(
                    Color(nsColor: Theme.cursor).opacity(hasImageInClipboard ? 0.15 : 0.08),
                    in: Capsule()
                )
            }
            .buttonStyle(.plain)
        }
        .frame(maxWidth: .infinity)
        .frame(height: 230)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(
                    isFileDropTargeted
                        ? Color(nsColor: Theme.cursor).opacity(0.06)
                        : Color.primary.opacity(0.03)
                )
        )
        .overlay {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(
                    isFileDropTargeted
                        ? Color(nsColor: Theme.cursor)
                        : Color.primary.opacity(0.16),
                    style: StrokeStyle(lineWidth: isFileDropTargeted ? 2 : 1.5, dash: [6, 5])
                )
        }
        .onDrop(of: [.fileURL], isTargeted: $isFileDropTargeted) { providers in
            handleFileDrop(providers)
        }
    }

    /// 已选定文件时的预览与管理卡片。
    private var selectedFileCard: some View {
        VStack(spacing: 12) {
            HStack(spacing: 16) {
                // 大预览框
                ProjectFileIconImage(path: selectedFilePath, size: 68)
                    .frame(width: 76, height: 76)
                    .background(
                        Color.primary.opacity(0.05),
                        in: RoundedRectangle(cornerRadius: 12, style: .continuous)
                    )
                    .overlay {
                        RoundedRectangle(cornerRadius: 12, style: .continuous)
                            .strokeBorder(Color.primary.opacity(0.12), lineWidth: 1)
                    }

                VStack(alignment: .leading, spacing: 6) {
                    HStack(spacing: 8) {
                        Text((selectedFilePath as NSString).lastPathComponent)
                            .font(SidebarTypography.body(.medium))
                            .lineLimit(1)

                        let ext = (selectedFilePath as NSString).pathExtension.uppercased()
                        if !ext.isEmpty {
                            Text(ext)
                                .font(SidebarTypography.micro(.bold))
                                .foregroundStyle(Color(nsColor: Theme.cursor))
                                .padding(.horizontal, 6)
                                .padding(.vertical, 2)
                                .background(
                                    Color(nsColor: Theme.cursor).opacity(0.15),
                                    in: RoundedRectangle(cornerRadius: 4, style: .continuous)
                                )
                        }
                    }

                    Text(selectedFilePath)
                        .font(SidebarTypography.caption())
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                        .textSelection(.enabled)
                }

                Spacer(minLength: 0)
            }

            Divider()

            HStack {
                Button(L10n.t("Choose Different…")) {
                    openImageFilePanel()
                }
                .buttonStyle(.borderless)

                Spacer()

                Button(L10n.t("Clear Selection"), role: .destructive) {
                    selectedFilePath = ""
                    fileImportError = nil
                }
                .buttonStyle(.borderless)
            }
        }
        .padding(16)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(Color.primary.opacity(0.04))
        )
        .overlay {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(Color.primary.opacity(0.1), lineWidth: 1)
        }
        .onDrop(of: [.fileURL], isTargeted: $isFileDropTargeted) { providers in
            handleFileDrop(providers)
        }
    }

    private func openImageFilePanel() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.allowedContentTypes = Self.imageContentTypes
        panel.message = "Choose an image for the project icon"
        panel.prompt = L10n.t("Select")

        let completion: (NSApplication.ModalResponse) -> Void = { response in
            guard response == .OK, let url = panel.url else { return }
            importPickedFileURL(url)
        }

        if let window = NSApp.keyWindow ?? NSApp.mainWindow {
            panel.beginSheetModal(for: window, completionHandler: completion)
        } else {
            let response = panel.runModal()
            completion(response)
        }
    }

    private func handleFileDrop(_ providers: [NSItemProvider]) -> Bool {
        guard let provider = providers.first else { return false }
        provider.loadItem(forTypeIdentifier: UTType.fileURL.identifier, options: nil) { item, _ in
            let url: URL?
            if let data = item as? Data {
                url = URL(dataRepresentation: data, relativeTo: nil)
            } else if let value = item as? URL {
                url = value
            } else {
                url = nil
            }
            guard let url else { return }
            Task { @MainActor in
                importPickedFileURL(url)
            }
        }
        return true
    }

    private func importPickedFileURL(_ url: URL) {
        fileImportError = nil
        // 安全作用域：部分来源（如 iCloud/外接盘）需要 startAccessing。
        let accessed = url.startAccessingSecurityScopedResource()
        defer {
            if accessed { url.stopAccessingSecurityScopedResource() }
        }
        guard FileManager.default.fileExists(atPath: url.path) else {
            fileImportError = "File not found."
            return
        }
        guard let managed = ProjectIconFileStore.importImage(
            from: url,
            projectID: project.id
        ) else {
            fileImportError = "Failed to import image into the config folder."
            return
        }
        selectedFilePath = managed.path
    }

    private func applySelectedFile() {
        guard !selectedFilePath.isEmpty else { return }
        select(.file(selectedFilePath))
    }

    // MARK: Pasteboard Helper

    /// 检查系统剪贴板中是否有可用图像或图像文件。
    private var hasImageInClipboard: Bool {
        let pb = NSPasteboard.general
        if NSImage(pasteboard: pb) != nil {
            return true
        }
        if let urls = pb.readObjects(forClasses: [NSURL.self], options: nil) as? [URL],
           let first = urls.first {
            let ext = first.pathExtension.lowercased()
            if ["png", "jpg", "jpeg", "svg", "webp", "icns", "ico", "gif", "bmp", "tiff", "heic"].contains(ext) {
                return true
            }
        }
        return false
    }

    /// 从剪贴板尝试提取图像或图像文件并直接导入为选定图片。
    private func pasteImageFromClipboard() {
        let pb = NSPasteboard.general

        // 1. 如果剪贴板包含复制的文件 URL
        if let urls = pb.readObjects(forClasses: [NSURL.self], options: nil) as? [URL],
           let first = urls.first {
            let ext = first.pathExtension.lowercased()
            if ["png", "jpg", "jpeg", "svg", "webp", "icns", "ico", "gif", "bmp", "tiff", "heic"].contains(ext) {
                importPickedFileURL(first)
                return
            }
        }

        // 2. 如果剪贴板包含位图/截图等像素图像数据
        if let image = NSImage(pasteboard: pb) {
            importNSImageFromClipboard(image)
            return
        }

        fileImportError = "剪贴板中未找到有效图片数据"
    }

    /// 将 NSImage 数据写入临时 PNG 文件并托管导入。
    /// - Parameter image: 从剪贴板提取的图像
    private func importNSImageFromClipboard(_ image: NSImage) {
        guard let tiffData = image.tiffRepresentation,
              let bitmap = NSBitmapImageRep(data: tiffData),
              let pngData = bitmap.representation(using: .png, properties: [:]) else {
            fileImportError = "无法解析剪贴板图像数据"
            return
        }

        let tempURL = FileManager.default.temporaryDirectory.appendingPathComponent("clipboard_\(UUID().uuidString).png")
        do {
            try pngData.write(to: tempURL)
            importPickedFileURL(tempURL)
            try? FileManager.default.removeItem(at: tempURL)
        } catch {
            fileImportError = "导入剪贴板图片失败: \(error.localizedDescription)"
        }
    }

    private static var imageContentTypes: [UTType] {
        var types: [UTType] = [.image, .png, .jpeg, .gif, .webP, .tiff, .heic]
        if let svg = UTType(filenameExtension: "svg") {
            types.append(svg)
        }
        if let icns = UTType(filenameExtension: "icns") {
            types.append(icns)
        }
        if let ico = UTType(filenameExtension: "ico") {
            types.append(ico)
        }
        return types
    }

    // MARK: Apply

    private func select(_ icon: ProjectIcon) {
        // 从文件图标改到非文件类型时，删除配置目录中的托管副本。
        // 文件 → 文件：importImage 已先清理再写入新文件。
        if case .file = project.icon, case .file = icon {
            // no-op for managed cleanup
        } else if case .file = project.icon {
            ProjectIconFileStore.removeManagedIcons(for: project.id)
        }
        // icon.didSet：clearCache + saveConfig + objectWillChange（赋值后发送）。
        project.icon = icon
        dismiss()
    }

    private func clearIcon() {
        if case .file = project.icon {
            ProjectIconFileStore.removeManagedIcons(for: project.id)
        }
        // icon.didSet：clearCache + saveConfig + objectWillChange（赋值后发送）。
        project.icon = nil
        dismiss()
    }

    /// 采用输入框或 macOS 字符检视器写入的 Emoji。
    private func selectEmoji() {
        let value = emoji.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else { return }
        select(.emoji(value))
    }
}
