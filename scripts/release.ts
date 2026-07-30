#!/usr/bin/env bun
// 构建、签名、公证 Qjiao，并将全部发布资产上传到 GitHub Releases。
import { $ } from "bun";
import {
  copyFileSync,
  existsSync,
  mkdirSync,
  readFileSync,
  readdirSync,
  rmSync,
  statSync,
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
  ];
  await $`xcodebuild -project ${PROJECT} -scheme ${SCHEME} -configuration ${CONFIGURATION} -archivePath ${ARCHIVE_PATH} ${signingArgs} archive`;

  say("Exporting Developer ID app…");
  await $`xcodebuild -exportArchive -archivePath ${ARCHIVE_PATH} -exportOptionsPlist ${EXPORT_OPTIONS} -exportPath ${EXPORT_DIR}`;
}

const app = APP_PATH;
if (!existsSync(app)) die(`exported app not found at ${app}`);
say("Re-signing bundled executables with Hardened Runtime…");
await signExportedApp(app, SIGN_IDENTITY);
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
  (await $`gh release view ${tag} --repo ${GITHUB_REPOSITORY}`.nothrow())
    .exitCode === 0;
if (existingRelease && process.env.FORCE !== "1") {
  die(`${tag} already exists; set FORCE=1 to replace its assets`);
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

/** 显式签署资源目录中的 Mach-O 工具，再重新签署最外层 App。 */
async function signExportedApp(
  appPath: string,
  identity: string,
): Promise<void> {
  const resourcesPath = join(appPath, "Contents", "Resources");
  // 清理 Finder/quarantine 扩展属性，避免它们污染资源封印。
  await $`xattr -cr ${appPath}`;
  for (const path of listExecutableFiles(resourcesPath)) {
    const description = (await $`file -b ${path}`.text()).trim();
    if (!description.includes("Mach-O")) continue;
    await $`codesign --force --timestamp --options runtime --sign ${identity} ${path}`;
  }
  await $`codesign --force --timestamp --options runtime --entitlements ${"kero/kero.entitlements"} --sign ${identity} ${appPath}`;
  await $`codesign --verify --deep --strict --verbose=2 ${appPath}`;
}

/** 递归列出目录内具有可执行权限的普通文件。 */
function listExecutableFiles(directory: string): string[] {
  const result: string[] = [];
  for (const entry of readdirSync(directory)) {
    const path = join(directory, entry);
    const stat = statSync(path);
    if (stat.isDirectory()) {
      result.push(...listExecutableFiles(path));
    } else if (stat.isFile() && (stat.mode & 0o111) !== 0) {
      result.push(path);
    }
  }
  return result;
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
      die(`${tag} already points to a different commit`);
    }
  } else {
    say(`Creating Git tag ${tag}…`);
    await $`git tag --annotate ${tag} --message ${`Qjiao ${version}`}`;
  }

  say(`Pushing Git tag ${tag}…`);
  await $`git push origin ${tag}`;
}

/** 判断 Info.plist 中是否已经配置有效的 Sparkle EdDSA 公钥。 */
function isValidSparklePublicKey(publicKey: string): boolean {
  return (
    publicKey !== "REPLACE_WITH_QJIAO_SPARKLE_PUBLIC_KEY" &&
    /^[A-Za-z0-9+/]{43}=$/.test(publicKey)
  );
}
