#if canImport(AppKit) && !canImport(UIKit)
    import AppKit

    extension AppTerminalView {
        /// 隐藏后多久才压缩交换链；短时间内切回（来回切项目 / 标签）完全不付压缩与恢复的代价。
        static let rendererCompactionDelay: Duration = .seconds(5)
        /// 多个终端同时隐藏时逐个错开压缩，避免延迟到点后集中同步绘制造成一次卡顿。
        static let rendererCompactionSpacing: Duration = .milliseconds(150)
        private static var pendingRendererCompactions = 0

        /// 压缩需要同步绘制数帧才能释放全尺寸目标；放在隐藏的当下会阻塞切换。
        func scheduleRendererTargetCompaction() {
            rendererCompactionGeneration &+= 1
            let generation = rendererCompactionGeneration
            let delay = Self.rendererCompactionDelay
                + Self.rendererCompactionSpacing * Self.pendingRendererCompactions
            Self.pendingRendererCompactions += 1
            Task { @MainActor [weak self] in
                try? await Task.sleep(for: delay)
                Self.pendingRendererCompactions -= 1
                guard let self, generation == self.rendererCompactionGeneration else { return }
                self.compactRendererTargets()
            }
        }

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
        /// 未被压缩过（隐藏时间短于压缩延迟）时交换链仍是全尺寸，交给随后的 tick 正常绘制，
        /// 不再在主线程同步绘制三帧。
        func restoreRendererTargets() {
            rendererCompactionGeneration &+= 1
            guard rendererTargetsCompacted else { return }
            rendererTargetsCompacted = false
            updateMetalLayerMetrics()
            guard let surface else { return }
            for _ in 0..<3 {
                surface.draw()
            }
        }
    }
#endif
