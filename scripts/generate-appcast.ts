#!/usr/bin/env bun
// 为 Qjiao 更新归档签名，并生成或增量更新 Sparkle appcast。
import { $ } from "bun";
import { existsSync } from "node:fs";
import { homedir } from "node:os";
import { join } from "node:path";
import { die } from "./lib";

/** 生成 appcast 时需要的发布参数。 */
export interface IGenerateAppcastOptions {
  downloadUrlPrefix: string;
  edKeyFile?: string;
}

/** 依次从环境变量、PATH 和 Xcode DerivedData 查找 Sparkle 工具。 */
export async function findGenerateAppcast(): Promise<string | null> {
  const fromEnv = process.env.SPARKLE_BIN;
  if (fromEnv && existsSync(join(fromEnv, "generate_appcast"))) {
    return join(fromEnv, "generate_appcast");
  }

  const onPath = Bun.which("generate_appcast");
  if (onPath) return onPath;

  const derived = join(homedir(), "Library/Developer/Xcode/DerivedData");
  if (existsSync(derived)) {
    const pattern = "*/artifacts/*/Sparkle/bin/generate_appcast";
    try {
      const out = await $`find ${derived} -path ${pattern} -type f`.text();
      const hit = out.split("\n").filter(Boolean)[0];
      if (hit) return hit;
    } catch {
      // DerivedData 不存在匹配项时继续返回 null，由调用方输出统一错误。
    }
  }
  return null;
}

/** 为归档签名并在 updatesDir 中生成或更新 appcast.xml。 */
export async function generateAppcast(
  updatesDir: string,
  options: IGenerateAppcastOptions,
): Promise<void> {
  const gen = await findGenerateAppcast();
  if (!gen) {
    die(
      "generate_appcast not found. Set SPARKLE_BIN to the Sparkle tools 'bin' " +
        "dir, or download it from https://github.com/sparkle-project/Sparkle/releases",
    );
  }
  console.log(`Using: ${gen}`);
  const signingArgs = options.edKeyFile
    ? ["--ed-key-file", options.edKeyFile]
    : [];
  // ZIP 与同名 Markdown 都作为当前 GitHub Release 的资产发布。
  await $`${gen} ${signingArgs} --download-url-prefix ${options.downloadUrlPrefix} --release-notes-url-prefix ${options.downloadUrlPrefix} --maximum-versions 10 ${updatesDir}`;
  console.log(`Wrote ${join(updatesDir, "appcast.xml")}`);
}

if (import.meta.main) {
  const updatesDir = process.argv[2];
  if (!updatesDir) die("usage: bun scripts/generate-appcast.ts <updates-dir>");
  const repository = process.env.GITHUB_REPOSITORY ?? "qzrzz/Qjiao";
  const tag = process.env.RELEASE_TAG;
  if (!tag) die("set RELEASE_TAG, for example RELEASE_TAG=v0.2.0");
  await generateAppcast(updatesDir, {
    downloadUrlPrefix: `https://github.com/${repository}/releases/download/${tag}/`,
    edKeyFile: process.env.SPARKLE_PRIVATE_KEY_FILE,
  });
}
