# Qjiao Web

Qjiao 的产品官网，使用 Vite、React、TypeScript 6 与 Base UI 构建。

## 开发

```bash
bun install
bun run dev
```

## 检查

```bash
bun run lint
bun run build
```

## 目录

- `src/Feature/`：按功能组拆分的独立组件与对应 Figma 切图。
- `src/styles.css`：响应式视觉样式。
- `build/webp-assets-vite-plugin.ts`：生产构建图片的 WebP 转换插件。
- `public/`：页面图标和 Open Graph 图片。
