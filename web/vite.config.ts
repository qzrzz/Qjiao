import react from "@vitejs/plugin-react";
import { defineConfig } from "vite";
import { webpAssets } from "./build/webp-assets-vite-plugin";

const isCodexSeatbeltSandbox = process.env.CODEX_SANDBOX === "seatbelt";

/** 构建纯 Vite React SPA，客户端只发布 WebP 图片。 */
export default defineConfig({
  base: "./",
  build: {
    assetsInlineLimit: 0,
    cssMinify: "lightningcss",
  },
  server: isCodexSeatbeltSandbox
    ? { watch: { useFsEvents: false, usePolling: true } }
    : undefined,
  plugins: [react(), webpAssets()],
});
