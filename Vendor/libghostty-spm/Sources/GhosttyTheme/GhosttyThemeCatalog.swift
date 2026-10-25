//
//  GhosttyThemeCatalog.swift
//  libghostty-spm
//

public enum GhosttyThemeCatalog {
    /// 按名称索引：主题菜单 / 动态颜色会高频按名查找，线性扫描 ~485 项代价不低。
    private static let themesByName: [String: GhosttyThemeDefinition] = Dictionary(
        allThemes.map { ($0.name, $0) },
        uniquingKeysWith: { first, _ in first }
    )

    public static func theme(named name: String) -> GhosttyThemeDefinition? {
        themesByName[name]
    }

    public static func search(_ query: String) -> [GhosttyThemeDefinition] {
        let lowered = query.lowercased()
        return allThemes.filter { $0.name.lowercased().contains(lowered) }
    }
}
