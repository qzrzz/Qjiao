/**
 * 从 npm 包 `material-icon-theme` 同步 SVG 图标与关联表到
 * `kero/MaterialIcons/`，供右侧 Files / CWD / Git 文件树使用。
 *
 * 用法：
 *   bun run scripts/vendor-material-icons.ts
 *   bun run scripts/vendor-material-icons.ts --version 5.37.0
 */
import { $ } from "bun";
import { copyFileSync, mkdirSync, readdirSync, rmSync, writeFileSync } from "node:fs";
import { join } from "node:path";

const versionArg = process.argv.find((a) => a.startsWith("--version="))?.slice("--version=".length)
  ?? process.argv[process.argv.indexOf("--version") + 1];
const version = versionArg && !versionArg.startsWith("--") ? versionArg : "5.37.0";

const root = join(import.meta.dir, "..");
const outDir = join(root, "kero/MaterialIcons");
const outIcons = join(outDir, "icons");
const tmpDir = join(root, ".tmp-material-icon-theme");

console.log(`vendor material-icon-theme@${version}`);

rmSync(tmpDir, { recursive: true, force: true });
mkdirSync(tmpDir, { recursive: true });
await $`bun add material-icon-theme@${version}`.cwd(tmpDir);

const pkg = join(tmpDir, "node_modules/material-icon-theme");
const srcJson = join(pkg, "dist/material-icons.json");
const srcIcons = join(pkg, "icons");

const data = await Bun.file(srcJson).json() as {
  file: string;
  folder: string;
  folderExpanded: string;
  rootFolder: string;
  rootFolderExpanded: string;
  fileNames: Record<string, string>;
  fileExtensions: Record<string, string>;
  folderNames: Record<string, string>;
  folderNamesExpanded: Record<string, string>;
  iconDefinitions: Record<string, { iconPath: string }>;
  light?: {
    file?: string;
    folder?: string;
    folderExpanded?: string;
    rootFolder?: string;
    rootFolderExpanded?: string;
    fileNames?: Record<string, string>;
    fileExtensions?: Record<string, string>;
    folderNames?: Record<string, string>;
    folderNamesExpanded?: Record<string, string>;
  };
};

const needed = new Set<string>();
for (const key of [data.file, data.folder, data.folderExpanded, data.rootFolder, data.rootFolderExpanded]) {
  needed.add(key);
}
for (const map of [data.fileNames, data.fileExtensions, data.folderNames, data.folderNamesExpanded]) {
  for (const v of Object.values(map)) needed.add(v);
}
const light = data.light ?? {};
for (const map of [
  light.fileNames, light.fileExtensions, light.folderNames, light.folderNamesExpanded,
]) {
  if (!map) continue;
  for (const v of Object.values(map)) needed.add(v);
}

rmSync(outIcons, { recursive: true, force: true });
mkdirSync(outIcons, { recursive: true });

const iconFiles: Record<string, string> = {};
let copied = 0;
for (const name of [...needed].sort()) {
  const defn = data.iconDefinitions[name];
  if (!defn) {
    console.warn(`missing icon definition: ${name}`);
    continue;
  }
  const fname = defn.iconPath.split("/").pop()!;
  iconFiles[name] = fname;
  copyFileSync(join(srcIcons, fname), join(outIcons, fname));
  copied++;
}

const slim = {
  file: data.file,
  folder: data.folder,
  folderExpanded: data.folderExpanded,
  rootFolder: data.rootFolder,
  rootFolderExpanded: data.rootFolderExpanded,
  fileNames: data.fileNames,
  fileExtensions: data.fileExtensions,
  folderNames: data.folderNames,
  folderNamesExpanded: data.folderNamesExpanded,
  iconFiles,
  light: {
    fileNames: light.fileNames ?? {},
    fileExtensions: light.fileExtensions ?? {},
    folderNames: light.folderNames ?? {},
    folderNamesExpanded: light.folderNamesExpanded ?? {},
  },
};

writeFileSync(join(outDir, "material-icons.json"), JSON.stringify(slim));
// 同步根目录会把资源摊平到 app Resources，文件名加前缀避免与应用自身文件混淆。
copyFileSync(join(pkg, "LICENSE"), join(outDir, "MATERIAL-ICON-THEME-LICENSE.txt"));
writeFileSync(join(outDir, "MATERIAL-ICON-THEME-VERSION.txt"), `material-icon-theme@${version}\n`);
writeFileSync(
  join(outDir, "MATERIAL-ICON-THEME-README.md"),
  [
    "# Material Icons (vendored)",
    "",
    "Icons and associations from [vscode-material-icon-theme](https://github.com/material-extensions/vscode-material-icon-theme) (MIT).",
    "",
    `Current version: material-icon-theme@${version}`,
    "",
    "Refresh with:",
    "",
    "```bash",
    "bun run scripts/vendor-material-icons.ts",
    "```",
    "",
  ].join("\n"),
);

rmSync(tmpDir, { recursive: true, force: true });

const svgCount = readdirSync(outIcons).filter((f) => f.endsWith(".svg")).length;
console.log(`copied ${copied} icons (${svgCount} svg files) -> ${outDir}`);
