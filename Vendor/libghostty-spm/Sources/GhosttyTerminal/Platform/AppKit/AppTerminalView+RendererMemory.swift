#if canImport(AppKit) && !canImport(UIKit)
    import AppKit

    extension AppTerminalView {
        /// 将隐藏终端的交换链替换为缩略尺寸目标，不改变终端网格、PTY 或回滚缓冲。
        func compactRendererTargets() {
            guard !rendererTargetsCompacted,
                  let surface,
                  let layer
            else { return }

            let maximumDimension = max(layer.bounds.width, layer.bounds.height)
            guard maximumDimension > 0 else { return }

            let compactScale = max(
                1 / maximumDimension,
                min(layer.contentsScale, 64 / maximumDimension)
            )
            guard compactScale < layer.contentsScale else { return }

            rendererTargetsCompacted = true
            updateActiveRendererLayer(scale: compactScale)
            for _ in 0..<3 {
                surface.draw()
            }
        }

        /// 在 surface 恢复可见前重建完整交换链，避免切换标签时短暂显示缩略帧。
        func restoreRendererTargets() {
            let needsMetricRestore = rendererTargetsCompacted
            rendererTargetsCompacted = false
            if needsMetricRestore {
                updateMetalLayerMetrics()
            }
            guard let surface else { return }
            for _ in 0..<3 {
                surface.draw()
            }
        }
    }
#endif
