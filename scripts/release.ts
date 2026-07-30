#!/usr/bin/env bun
// 构建、签名、公证 Qjiao，并将全部发布资产上传到 GitHub Releases。
import { $ } from "bun";
import {
  copyFileSync,
  existsSync,
  lstatSync,
  mkdirSync,
  readFileSync,
  readdirSync,
  renameSync,
  rmSync,
} from "node:fs";
import { join } from "node:path";
import { extractReleaseNotes } from "./changelog";
import { generateAppcast } from "./generate-appcast";
import { die, need, say } from "./lib";

/** 公证提交返回的必要字段。 */
interface INotarySubmission {
  id: string;
  status: string;
}

const PROJECT = "Qjiao.xcodeproj";
const SCHEME = "Qjiao";
const APP_NAME = "Qjiao";
const ARTIFACT_PREFIX = "qjiao";
const CONFIGURATION = process.env.CONFIGURATION ?? "Release";
const BUILD_DIR = process.env.BUILD_DIR ?? "build";
const UPDATES_DIR = join(BUILD_DIR, "updates");
const ARCHIVE_PATH = join(BUILD_DIR, "Qjiao.xcarchive");
const EXPORT_DIR = join(BUILD_DIR, "export");
const APP_PATH = join(EXPORT_DIR, `${APP_NAME}.app`);
const REUSE_BUILD = process.env.REUSE_BUILD === "1";
const EXPORT_OPTIONS_SOURCE =
  process.env.EXPORT_OPTIONS ?? "scripts/ExportOptions.plist";
const EXPORT_OPTIONS = join(BUILD_DIR, "ExportOptions.plist");
const SIGN_IDENTITY =
  process.env.SIGN_IDENTITY ??
  process.env.MACOS_SIGNING_IDENTITY ??
  "Developer ID Application";
const NOTARY_PROFILE = process.env.NOTARY_PROFILE ?? "NOTARY";
const GITHUB_REPOSITORY = process.env.GITHUB_REPOSITORY ?? "qzrzz/Qjiao";
const SPARKLE_ACCOUNT = process.env.SPARKLE_ACCOUNT ?? "qjiao";
const FORCE_RELEASE = process.env.FORCE !== "0";

process.chdir(join(import.meta.dir, ".."));
if (!process.env.DEVELOPER_DIR) {
  const betaDeveloperDir = "/Applications/Xcode-beta.app/Contents/Developer";
  if (existsSync(betaDeveloperDir)) {
    process.env.DEVELOPER_DIR = betaDeveloperDir;
  }
}

need("xcodebuild");
need("ditto");
need("xcrun");
need("plutil");
need("create-dmg");
need("codesign");
need("file");
need("lipo");
need("xattr");
if (process.env.PUBLISH !== "0") {
  need("git");
  need("gh");
  const changes = (await $`git status --porcelain`.text()).trim();
  if (changes) {
    die("the Git worktree must be clean before publishing a release");
  }
}
if (!existsSync(EXPORT_OPTIONS_SOURCE)) {
  die(`export options not found: ${EXPORT_OPTIONS_SOURCE}`);
}

const sourceInfoPlist = "kero/Info.plist";
const configuredSparklePublicKey = (
  await $`plutil -extract SUPublicEDKey raw ${sourceInfoPlist}`.text()
).trim();
if (!isValidSparklePublicKey(configuredSparklePublicKey)) {
  die(
    "set Qjiao's Sparkle public key in kero/Info.plist before releasing; " +
      "see RELEASING.md → 生成 Qjiao 的 Sparkle 密钥",
  );
}

const configuredTeamId = (
  await $`plutil -extract teamID raw ${EXPORT_OPTIONS_SOURCE}`.text()
).trim();
const teamId = process.env.APPLE_TEAM_ID ?? configuredTeamId;
if (!teamId || teamId === "YOUR_TEAM_ID") {
  die("set teamID in scripts/ExportOptions.plist or APPLE_TEAM_ID");
}
if (!/^[A-Z0-9]{10}$/.test(teamId)) {
  die("APPLE_TEAM_ID must be a 10-character Apple Developer Team ID");
}
if (!/^[A-Za-z0-9_.-]+\/[A-Za-z0-9_.-]+$/.test(GITHUB_REPOSITORY)) {
  die(`invalid GITHUB_REPOSITORY: ${GITHUB_REPOSITORY}`);
}

mkdirSync(BUILD_DIR, { recursive: true });
copyFileSync(EXPORT_OPTIONS_SOURCE, EXPORT_OPTIONS);
await $`plutil -replace teamID -string ${teamId} ${EXPORT_OPTIONS}`;

if (REUSE_BUILD) {
  say("REUSE_BUILD=1: reusing the existing exported Qjiao.app…");
  if (!existsSync(APP_PATH)) {
    die(`cannot reuse build because ${APP_PATH} does not exist`);
  }
} else {
  say(`Archiving Qjiao (${CONFIGURATION})…`);
  rmSync(ARCHIVE_PATH, { recursive: true, force: true });
  rmSync(EXPORT_DIR, { recursive: true, force: true });
  const signingArgs = [
    `DEVELOPMENT_TEAM=${teamId}`,
    "CODE_SIGN_STYLE=Manual",
    `CODE_SIGN_IDENTITY=${SIGN_IDENTITY}`,
    "ARCHS=arm64",
    "ONLY_ACTIVE_ARCH=YES",
  ];
  await $`xcodebuild -project ${PROJECT} -scheme ${SCHEME} -configuration ${CONFIGURATION} -archivePath ${ARCHIVE_PATH} ${signingArgs} archive`;

  say("Exporting Developer ID app…");
  await $`xcodebuild -exportArchive -archivePath ${ARCHIVE_PATH} -exportOptionsPlist ${EXPORT_OPTIONS} -exportPath ${EXPORT_DIR}`;
}

const app = APP_PATH;
if (!existsSync(app)) die(`exported app not found at ${app}`);
say("Thinning Qjiao to arm64 and re-signing nested code…");
await prepareAndSignExportedApp(app, SIGN_IDENTITY);
const appPlist = join(app, "Contents/Info.plist");
const version = (
  await $`plutil -extract CFBundleShortVersionString raw ${appPlist}`.text()
).trim();
const build = (
  await $`plutil -extract CFBundleVersion raw ${appPlist}`.text()
).trim();
const sparklePublicKey = (
  await $`plutil -extract SUPublicEDKey raw ${appPlist}`.text()
).trim();
if (!version || !build) die("could not read the built app version");
if (!isValidSparklePublicKey(sparklePublicKey)) {
  die("the built app does not contain a valid Qjiao Sparkle public key");
}

const tag = process.env.RELEASE_TAG ?? `v${version}`;
if (tag !== `v${version}`) {
  die(`release tag ${tag} does not match MARKETING_VERSION ${version}`);
}
const zipName = `${ARTIFACT_PREFIX}-${version}.zip`;
const dmgName = `${ARTIFACT_PREFIX}-${version}.dmg`;
const notesName = `${ARTIFACT_PREFIX}-${version}.md`;
const zipPath = join(UPDATES_DIR, zipName);
const dmgPath = join(BUILD_DIR, dmgName);
const notesPath = join(UPDATES_DIR, notesName);
say(`Packaging Qjiao ${version} (build ${build})…`);

rmSync(UPDATES_DIR, { recursive: true, force: true });
mkdirSync(UPDATES_DIR, { recursive: true });
if (process.env.PUBLISH !== "0" && process.env.NO_HISTORY !== "1") {
  say("Downloading the previous appcast from GitHub Releases…");
  // 第一次发布没有历史 appcast，允许下载失败后生成新文件。
  await $`gh release download --repo ${GITHUB_REPOSITORY} --pattern appcast.xml --dir ${UPDATES_DIR} --clobber`.nothrow();
}

const dmgStaging = join(BUILD_DIR, "dmg");
rmSync(dmgStaging, { recursive: true, force: true });
rmSync(dmgPath, { force: true });
mkdirSync(dmgStaging, { recursive: true });
await $`ditto ${app} ${join(dmgStaging, `${APP_NAME}.app`)}`;
await $`create-dmg --volname ${`${APP_NAME} ${version}`} --window-size 540 380 --icon-size 128 --icon ${`${APP_NAME}.app`} 150 195 --app-drop-link 390 195 --hide-extension ${`${APP_NAME}.app`} --no-internet-enable ${dmgPath} ${dmgStaging}`.nothrow();
if (!existsSync(dmgPath)) die("create-dmg did not produce a disk image");
await $`codesign --force --timestamp --sign ${SIGN_IDENTITY} ${dmgPath}`;
await $`codesign --verify --strict --verbose=2 ${dmgPath}`;

say("Notarizing and stapling release artifacts…");
const notaryKeyPath = process.env.APPLE_API_KEY_PATH;
const notaryKeyId = process.env.APPLE_API_KEY_ID;
const notaryIssuer = process.env.APPLE_API_ISSUER;
const appleId = process.env.APPLE_ID;
const appleAppSpecificPassword = process.env.APPLE_APP_SPECIFIC_PASSWORD;
if (
  (appleId && !appleAppSpecificPassword) ||
  (!appleId && appleAppSpecificPassword)
) {
  die("APPLE_ID and APPLE_APP_SPECIFIC_PASSWORD must be set together");
}
let notaryAuthArgs: string[];
if (notaryKeyPath && notaryKeyId && notaryIssuer) {
  notaryAuthArgs = [
    "--key",
    notaryKeyPath,
    "--key-id",
    notaryKeyId,
    "--issuer",
    notaryIssuer,
  ];
} else if (appleId && appleAppSpecificPassword) {
  notaryAuthArgs = [
    "--apple-id",
    appleId,
    "--password",
    appleAppSpecificPassword,
    "--team-id",
    teamId,
  ];
} else {
  notaryAuthArgs = ["--keychain-profile", NOTARY_PROFILE];
}
await notarizeArtifact(dmgPath, notaryAuthArgs);
await $`xcrun stapler staple ${dmgPath}`;
await $`xcrun stapler staple ${app}`;
await $`ditto -c -k --keepParent ${app} ${zipPath}`;

const changelog = "CHANGELOG.md";
const notes = existsSync(changelog)
  ? extractReleaseNotes(readFileSync(changelog, "utf8"), version)
  : null;
await Bun.write(notesPath, `${notes ?? `Qjiao ${version} release.`}\n`);

say("Generating the Sparkle appcast…");
const sparklePrivateKeyFile = process.env.SPARKLE_PRIVATE_KEY_FILE;
if (sparklePrivateKeyFile && !existsSync(sparklePrivateKeyFile)) {
  die(
    "SPARKLE_PRIVATE_KEY_FILE must point to the exported Sparkle private key",
  );
}
const downloadUrlPrefix = `https://github.com/${GITHUB_REPOSITORY}/releases/download/${tag}/`;
await generateAppcast(UPDATES_DIR, {
  downloadUrlPrefix,
  edKeyFile: sparklePrivateKeyFile,
  account: SPARKLE_ACCOUNT,
});

if (process.env.PUBLISH === "0") {
  say("PUBLISH=0: artifacts are ready without creating a GitHub Release.");
  process.exit(0);
}

const appcastPath = join(UPDATES_DIR, "appcast.xml");
const existingRelease =
  (
    await $`gh release view ${tag} --repo ${GITHUB_REPOSITORY}`
      .quiet()
      .nothrow()
  ).exitCode === 0;
if (existingRelease && !FORCE_RELEASE) {
  die(`${tag} already exists and FORCE=0 prevents replacing its assets`);
}
await createAndPushReleaseTag(tag, version);
say(`Publishing ${tag} to GitHub Releases…`);
if (existingRelease) {
  await $`gh release upload ${tag} ${dmgPath} ${zipPath} ${notesPath} ${appcastPath} --repo ${GITHUB_REPOSITORY} --clobber`;
  await $`gh release edit ${tag} --repo ${GITHUB_REPOSITORY} --title ${`${APP_NAME} ${version}`} --notes-file ${notesPath}`;
} else {
  await $`gh release create ${tag} ${dmgPath} ${zipPath} ${notesPath} ${appcastPath} --repo ${GITHUB_REPOSITORY} --verify-tag --title ${`${APP_NAME} ${version}`} --notes-file ${notesPath}`;
}

say(`Qjiao ${version} is live on GitHub:`);
console.log(
  `  release: https://github.com/${GITHUB_REPOSITORY}/releases/tag/${tag}`,
);
console.log(
  `  latest:  https://github.com/${GITHUB_REPOSITORY}/releases/latest`,
);

/** 将导出的 App 裁成纯 arm64，并按由内到外的顺序重新签名。 */
async function prepareAndSignExportedApp(
  appPath: string,
  identity: string,
): Promise<void> {
  // 清理 Finder/quarantine 扩展属性，避免它们污染资源封印。
  await $`xattr -cr ${appPath}`;

  const machOBinaries = await listMachOBinaries(appPath);
  for (const path of machOBinaries) {
    await thinBinaryToArm64(path);
  }
  for (const path of machOBinaries) {
    await signNestedCode(path, identity);
  }
  for (const path of listNestedCodeBundles(appPath)) {
    await signNestedCode(path, identity);
  }
  await $`codesign --force --timestamp --options runtime --entitlements ${"kero/kero.entitlements"} --sign ${identity} ${appPath}`;
  await $`codesign --verify --deep --strict --verbose=2 ${appPath}`;

  for (const path of machOBinaries) {
    const architectures = await readArchitectures(path);
    if (architectures.length !== 1 || architectures[0] !== "arm64") {
      die(`non-arm64 architecture remains in ${path}: ${architectures}`);
    }
  }
}

/** 递归列出目录内具有可执行权限的普通文件，并跳过符号链接。 */
function listExecutableFiles(directory: string): string[] {
  const result: string[] = [];
  for (const entry of readdirSync(directory)) {
    const path = join(directory, entry);
    const stat = lstatSync(path);
    if (stat.isSymbolicLink()) continue;
    if (stat.isDirectory()) {
      result.push(...listExecutableFiles(path));
    } else if (stat.isFile() && (stat.mode & 0o111) !== 0) {
      result.push(path);
    }
  }
  return result;
}

/** 找出 App 中全部可执行 Mach-O 文件。 */
async function listMachOBinaries(appPath: string): Promise<string[]> {
  const result: string[] = [];
  for (const path of listExecutableFiles(appPath)) {
    const description = (await $`file -b ${path}`.text()).trim();
    if (description.includes("Mach-O")) result.push(path);
  }
  return result;
}

/** 读取 Mach-O 文件包含的架构列表。 */
async function readArchitectures(path: string): Promise<string[]> {
  return (await $`lipo -archs ${path}`.text()).trim().split(/\s+/);
}

/** 删除 Mach-O 中除 arm64 外的架构切片。 */
async function thinBinaryToArm64(path: string): Promise<void> {
  const architectures = await readArchitectures(path);
  if (!architectures.includes("arm64")) {
    die(`embedded executable does not support arm64: ${path}`);
  }
  if (architectures.length === 1) return;

  const temporaryPath = `${path}.qjiao-arm64`;
  rmSync(temporaryPath, { force: true });
  await $`lipo ${path} -thin arm64 -output ${temporaryPath}`;
  renameSync(temporaryPath, path);
}

/** 递归列出需要独立签名的嵌套代码 Bundle，最深层优先。 */
function listNestedCodeBundles(appPath: string): string[] {
  const result: string[] = [];
  const visit = (directory: string): void => {
    for (const entry of readdirSync(directory)) {
      const path = join(directory, entry);
      const stat = lstatSync(path);
      if (stat.isSymbolicLink() || !stat.isDirectory()) continue;
      visit(path);
      if (/\.(?:app|framework|xpc)$/.test(entry)) result.push(path);
    }
  };
  visit(appPath);
  return result;
}

/** 给内层 Mach-O 或代码 Bundle 保留必要元数据后补签。 */
async function signNestedCode(path: string, identity: string): Promise<void> {
  const existingSignature = await $`codesign --display ${path}`
    .quiet()
    .nothrow();
  if (existingSignature.exitCode === 0) {
    await $`codesign --force --timestamp --options runtime --preserve-metadata=identifier,entitlements,requirements --sign ${identity} ${path}`;
  } else {
    await $`codesign --force --timestamp --options runtime --sign ${identity} ${path}`;
  }
}

/** 提交公证并验证最终状态；失败时立即下载 Apple 的详细日志。 */
async function notarizeArtifact(
  artifactPath: string,
  authArgs: string[],
): Promise<void> {
  // 敏感参数通过 Bun.spawn 传递，避免 ShellError 将凭据写入日志。
  const child = Bun.spawn(
    [
      "xcrun",
      "notarytool",
      "submit",
      artifactPath,
      ...authArgs,
      "--wait",
      "--output-format",
      "json",
    ],
    {
      env: process.env,
      stdin: "inherit",
      stdout: "pipe",
      stderr: "inherit",
    },
  );
  const output = await new Response(child.stdout).text();
  const exitCode = await child.exited;
  if (exitCode !== 0) {
    die(`notarytool failed with exit code ${exitCode}`);
  }
  const submission = parseNotarySubmission(output);
  console.log(output.trim());
  if (submission.status === "Accepted") return;

  console.error("\nApple notarization log:");
  const log = Bun.spawn(
    ["xcrun", "notarytool", "log", submission.id, ...authArgs],
    {
      env: process.env,
      stdin: "inherit",
      stdout: "inherit",
      stderr: "inherit",
    },
  );
  await log.exited;
  die(`notarization finished with status ${submission.status}`);
}

/** 解析 notarytool JSON，并拒绝缺少必要字段的异常响应。 */
function parseNotarySubmission(output: string): INotarySubmission {
  try {
    const value = JSON.parse(output) as Partial<INotarySubmission>;
    if (typeof value.id === "string" && typeof value.status === "string") {
      return { id: value.id, status: value.status };
    }
  } catch {
    // 统一交由下方错误处理，避免输出可能包含环境信息的原始异常对象。
  }
  die("notarytool returned an invalid JSON response");
}

/** 创建指向当前提交的版本标签，并将标签推送到 origin。 */
async function createAndPushReleaseTag(
  tag: string,
  version: string,
): Promise<void> {
  const head = (await $`git rev-parse HEAD`.text()).trim();
  const localTag = await $`git rev-parse --verify ${`refs/tags/${tag}`}`
    .quiet()
    .nothrow();
  if (localTag.exitCode === 0) {
    const taggedCommit = (await $`git rev-list -n 1 ${tag}`.text()).trim();
    if (taggedCommit !== head) {
      if (!FORCE_RELEASE) {
        die(
          `${tag} already points to a different commit and FORCE=0 prevents moving it`,
        );
      }
      say(`Moving Git tag ${tag} to the current commit…`);
      await $`git tag --delete ${tag}`;
      await $`git tag --annotate ${tag} --message ${`Qjiao ${version}`}`;
    }
  } else {
    say(`Creating Git tag ${tag}…`);
    await $`git tag --annotate ${tag} --message ${`Qjiao ${version}`}`;
  }

  say(`Pushing Git tag ${tag}…`);
  if (FORCE_RELEASE) {
    await $`git push --force origin ${tag}`;
  } else {
    await $`git push origin ${tag}`;
  }
}

/** 判断 Info.plist 中是否已经配置有效的 Sparkle EdDSA 公钥。 */
function isValidSparklePublicKey(publicKey: string): boolean {
  return (
    publicKey !== "REPLACE_WITH_QJIAO_SPARKLE_PUBLIC_KEY" &&
    /^[A-Za-z0-9+/]{43}=$/.test(publicKey)
  );
}
