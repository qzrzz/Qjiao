/**
 * 根据 `kero/TerminalAppIcons/apps.json` 中的 `iconify` 字段，
 * 从 Iconify API 下载 SVG 到 `kero/TerminalAppIcons/icons/`。
 *
 * 用法：
 *   bun run scripts/vendor-terminal-app-icons.ts
 *   bun run scripts/vendor-terminal-app-icons.ts --icons bxl:docker,bxl:github
 *
 * Iconify 文档：https://iconify.design/docs/api/icon-data.html
 * Boxicons Brands（bxl）：https://icon-sets.iconify.design/bxl/
 */
import { mkdirSync, readFileSync, writeFileSync } from "node:fs";
import { join } from "node:path";

const root = join(import.meta.dir, "..");
const appsJsonPath = join(root, "kero/TerminalAppIcons/apps.json");
const outDir = join(root, "kero/TerminalAppIcons/icons");

const extraArg = process.argv.find((a) => a.startsWith("--icons="))?.slice("--icons=".length)
  ?? (process.argv.includes("--icons")
    ? process.argv[process.argv.indexOf("--icons") + 1]
    : undefined);

function iconifyToFileName(iconify: string): string {
  const trimmed = iconify.trim();
  if (trimmed.endsWith(".svg")) return trimmed;
  const parts = trimmed.split(":");
  if (parts.length === 2) return `${parts[0]}-${parts[1]}.svg`;
  return `${trimmed}.svg`;
}

function collectFromAppsJson(): string[] {
  const raw = JSON.parse(readFileSync(appsJsonPath, "utf8")) as {
    apps?: Array<{ iconify?: string }>;
  };
  const set = new Set<string>();
  for (const app of raw.apps ?? []) {
    if (app.iconify?.trim()) set.add(app.iconify.trim());
  }
  return [...set];
}

function collectExtra(arg: string | undefined): string[] {
  if (!arg) return [];
  return arg.split(",").map((s) => s.trim()).filter(Boolean);
}

const iconifyIds = [...new Set([...collectFromAppsJson(), ...collectExtra(extraArg)])];
if (iconifyIds.length === 0) {
  console.log("No iconify entries found in apps.json (and no --icons). Nothing to do.");
  process.exit(0);
}

mkdirSync(outDir, { recursive: true });
console.log(`vendor terminal-app-icons: ${iconifyIds.length} iconify id(s) → ${outDir}`);

let ok = 0;
let fail = 0;
for (const id of iconifyIds) {
  const parts = id.split(":");
  if (parts.length !== 2 || !parts[0] || !parts[1]) {
    console.error(`skip invalid iconify id: ${id}`);
    fail++;
    continue;
  }
  const [prefix, name] = parts;
  const url = `https://api.iconify.design/${encodeURIComponent(prefix)}/${encodeURIComponent(name)}.svg`;
  const outName = iconifyToFileName(id);
  const outPath = join(outDir, outName);
  try {
    const res = await fetch(url);
    if (!res.ok) {
      console.error(`FAIL ${id} → HTTP ${res.status}`);
      fail++;
      continue;
    }
    const svg = await res.text();
    if (!svg.includes("<svg")) {
      console.error(`FAIL ${id} → not an SVG`);
      fail++;
      continue;
    }
    writeFileSync(outPath, svg);
    console.log(`OK ${outName}`);
    ok++;
  } catch (err) {
    console.error(`FAIL ${id}`, err);
    fail++;
  }
}

console.log(`done: ${ok} ok, ${fail} failed`);
if (fail > 0) process.exit(1);
