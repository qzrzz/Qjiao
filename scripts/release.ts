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
import { join, resolve } from "node:path";
import { extractReleaseNotes } from "./changelog";
import { generateAppcast } from "./generate-appcast";
import { die, need, say } from "./lib";

/** 公证提交返回的必要字段。 */
interface INotarySubmission {
  id: string;
  status: string;
}

/** 可安全断点续跑的发布步骤。 */
type IReleaseStep =
  | "archive-created"
  | "app-exported"
  | "app-prepared"
  | "dmg-created"
  | "notarized"
  | "updates-generated"
  | "tag-pushed"
  | "release-published";

/** 用于判断旧产物是否仍属于当前发布源码。 */
interface IReleaseIdentity {
  version: string;
  build: string;
  commit: string;
  configuration: string;
}

/** 持久化在 build 目录内的发布断点。 */
interface IReleaseState extends IReleaseIdentity {
  schemaVersion: 1;
  completedSteps: IReleaseStep[];
}

const RELEASE_STEPS: IReleaseStep[] = [
  "archive-created",
  "app-exported",
  "app-prepared",
  "dmg-created",
  "notarized",
  "updates-generated",
  "tag-pushed",
  "release-published",
];

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
const RELEASE_STATE_PATH = join(BUILD_DIR, "release-state.json");
const REUSE_BUILD = process.env.REUSE_BUILD === "1";
const RESET_RELEASE = process.env.RESET_RELEASE === "1";
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
let allowExistingArtifactAdoption = false;

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

const app = APP_PATH;
const identity = await readReleaseIdentity();
const version = identity.version;
const build = identity.build;
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
const dmgStaging = join(BUILD_DIR, "dmg");
const appcastPath = join(UPDATES_DIR, "appcast.xml");
const releaseState = await initializeReleaseState(identity);

say(`Preparing Qjiao ${version} (build ${build})…`);
if (
  await shouldResumeStep(releaseState, "app-prepared", () =>
    validatePreparedApp(app, identity),
  )
) {
  say("Resuming: exported arm64 App is already prepared.");
} else {
  const exportedAppReady = await shouldResumeStep(
    releaseState,
    "app-exported",
    () => validateExportedApp(app, identity),
  );
  if (exportedAppReady) {
    say("Resuming: Developer ID App export is already complete.");
  } else if (REUSE_BUILD) {
    die(
      `REUSE_BUILD=1 requires a valid exported App at ${APP_PATH}; ` +
        "remove REUSE_BUILD or restore the App",
    );
  } else {
    if (
      await shouldResumeStep(releaseState, "archive-created", () =>
        validateArchive(identity),
      )
    ) {
      say("Resuming: Xcode archive is already complete.");
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
      if (!(await validateArchive(identity))) {
        die("the Xcode archive failed version or signature checks");
      }
      await completeReleaseStep(releaseState, "archive-created");
    }

    say("Exporting Developer ID app…");
    rmSync(EXPORT_DIR, { recursive: true, force: true });
    await $`xcodebuild -exportArchive -archivePath ${ARCHIVE_PATH} -exportOptionsPlist ${EXPORT_OPTIONS} -exportPath ${EXPORT_DIR}`;
    if (!(await validateExportedApp(app, identity))) {
      die("the exported App failed version or signature checks");
    }
    await completeReleaseStep(releaseState, "app-exported");
  }

  say("Thinning Qjiao to arm64 and re-signing nested code…");
  await prepareAndSignExportedApp(app, SIGN_IDENTITY);
  if (!(await validatePreparedApp(app, identity))) {
    die("the prepared App failed version, architecture, or signature checks");
  }
  await completeReleaseStep(releaseState, "app-prepared");
}

if (
  await shouldResumeStep(releaseState, "dmg-created", () =>
    validateSignedDmg(dmgPath),
  )
) {
  say("Resuming: signed DMG is already complete.");
} else {
  say(`Packaging Qjiao ${version} (build ${build})…`);
  rmSync(dmgStaging, { recursive: true, force: true });
  rmSync(dmgPath, { force: true });
  mkdirSync(dmgStaging, { recursive: true });
  await $`ditto ${app} ${join(dmgStaging, `${APP_NAME}.app`)}`;
  await $`create-dmg --volname ${`${APP_NAME} ${version}`} --window-size 540 380 --icon-size 128 --icon ${`${APP_NAME}.app`} 150 195 --app-drop-link 390 195 --hide-extension ${`${APP_NAME}.app`} --no-internet-enable ${dmgPath} ${dmgStaging}`.nothrow();
  if (!existsSync(dmgPath)) die("create-dmg did not produce a disk image");
  await $`codesign --force --timestamp --sign ${SIGN_IDENTITY} ${dmgPath}`;
  await $`codesign --verify --strict --verbose=2 ${dmgPath}`;
  await completeReleaseStep(releaseState, "dmg-created");
}

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
if (
  await shouldResumeStep(releaseState, "notarized", () =>
    validateStapledArtifacts(app, dmgPath),
  )
) {
  say("Resuming: Apple notarization tickets are already stapled.");
} else {
  await notarizeArtifact(dmgPath, notaryAuthArgs);
  await $`xcrun stapler staple ${dmgPath}`;
  await $`xcrun stapler staple ${app}`;
  if (!(await validateStapledArtifacts(app, dmgPath))) {
    die("stapled App or DMG validation failed");
  }
  await completeReleaseStep(releaseState, "notarized");
}

if (
  await shouldResumeStep(releaseState, "updates-generated", () =>
    validateUpdateArtifacts(zipPath, notesPath, appcastPath, version),
  )
) {
  say("Resuming: Sparkle ZIP, notes, and appcast are already complete.");
} else {
  rmSync(UPDATES_DIR, { recursive: true, force: true });
  mkdirSync(UPDATES_DIR, { recursive: true });
  if (process.env.PUBLISH !== "0" && process.env.NO_HISTORY !== "1") {
    say("Downloading the previous appcast from GitHub Releases…");
    // 第一次发布没有历史 appcast，允许下载失败后生成新文件。
    await $`gh release download --repo ${GITHUB_REPOSITORY} --pattern appcast.xml --dir ${UPDATES_DIR} --clobber`
      .quiet()
      .nothrow();
  }

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
  if (
    !(await validateUpdateArtifacts(zipPath, notesPath, appcastPath, version))
  ) {
    die("generated Sparkle update artifacts failed validation");
  }
  await completeReleaseStep(releaseState, "updates-generated");
}

if (process.env.PUBLISH === "0") {
  say("PUBLISH=0: artifacts are ready without creating a GitHub Release.");
  process.exit(0);
}

if (
  await shouldResumeStep(releaseState, "tag-pushed", () =>
    validateReleaseTag(tag),
  )
) {
  say(`Resuming: Git tag ${tag} already points to the current commit.`);
} else {
  await createAndPushReleaseTag(tag, version);
  await completeReleaseStep(releaseState, "tag-pushed");
}

const releaseAssetNames = [dmgName, zipName, notesName, "appcast.xml"];
if (
  await shouldResumeStep(releaseState, "release-published", () =>
    validatePublishedRelease(tag, releaseAssetNames),
  )
) {
  say(`Resuming: GitHub Release ${tag} is already complete.`);
} else {
  const existingRelease =
    (
      await $`gh release view ${tag} --repo ${GITHUB_REPOSITORY}`
        .quiet()
        .nothrow()
    ).exitCode === 0;
  if (existingRelease && !FORCE_RELEASE) {
    die(`${tag} already exists and FORCE=0 prevents replacing its assets`);
  }
  say(`Publishing ${tag} to GitHub Releases…`);
  if (existingRelease) {
    await $`gh release upload ${tag} ${dmgPath} ${zipPath} ${notesPath} ${appcastPath} --repo ${GITHUB_REPOSITORY} --clobber`;
    await $`gh release edit ${tag} --repo ${GITHUB_REPOSITORY} --title ${`${APP_NAME} ${version}`} --notes-file ${notesPath}`;
  } else {
    await $`gh release create ${tag} ${dmgPath} ${zipPath} ${notesPath} ${appcastPath} --repo ${GITHUB_REPOSITORY} --verify-tag --title ${`${APP_NAME} ${version}`} --notes-file ${notesPath}`;
  }
  if (!(await validatePublishedRelease(tag, releaseAssetNames))) {
    die(`GitHub Release ${tag} is missing one or more required assets`);
  }
  await completeReleaseStep(releaseState, "release-published");
}

say(`Qjiao ${version} is live on GitHub:`);
console.log(
  `  release: https://github.com/${GITHUB_REPOSITORY}/releases/tag/${tag}`,
);
console.log(
  `  latest:  https://github.com/${GITHUB_REPOSITORY}/releases/latest`,
);

/** 读取当前 Release 配置中的版本、构建号和源码提交。 */
async function readReleaseIdentity(): Promise<IReleaseIdentity> {
  const output =
    await $`xcodebuild -project ${PROJECT} -scheme ${SCHEME} -configuration ${CONFIGURATION} -showBuildSettings`
      .quiet()
      .text();
  const version = readBuildSetting(output, "MARKETING_VERSION");
  const build = readBuildSetting(output, "CURRENT_PROJECT_VERSION");
  const commitResult = await $`git rev-parse HEAD`.quiet().nothrow();
  const commit =
    commitResult.exitCode === 0
      ? commitResult.stdout.toString().trim()
      : "git-unavailable";
  if (!version || !build) {
    die("could not read MARKETING_VERSION or CURRENT_PROJECT_VERSION");
  }
  return { version, build, commit, configuration: CONFIGURATION };
}

/** 从 xcodebuild 的 Build Settings 输出中读取单个配置值。 */
function readBuildSetting(output: string, name: string): string {
  const match = output.match(new RegExp(`^\\s*${name} = (.+)$`, "m"));
  return match?.[1]?.trim() ?? "";
}

/** 加载匹配当前版本的断点；首次升级脚本时允许验证并接管旧产物。 */
async function initializeReleaseState(
  identity: IReleaseIdentity,
): Promise<IReleaseState> {
  if (RESET_RELEASE) {
    rmSync(RELEASE_STATE_PATH, { force: true });
  }

  const existingState = readReleaseState();
  if (existingState && releaseIdentityMatches(existingState, identity)) {
    allowExistingArtifactAdoption = true;
    return existingState;
  }

  if (existingState) {
    say("Release identity changed; previous checkpoints will not be reused.");
  } else if (!RESET_RELEASE) {
    // 兼容升级断点脚本前已经生成的同版本 App 和 DMG。
    allowExistingArtifactAdoption = true;
  }

  const state: IReleaseState = {
    schemaVersion: 1,
    ...identity,
    completedSteps: [],
  };
  await writeReleaseState(state);
  return state;
}

/** 读取并校验发布断点文件，损坏的状态会被安全忽略。 */
function readReleaseState(): IReleaseState | null {
  if (!existsSync(RELEASE_STATE_PATH)) return null;
  try {
    const value = JSON.parse(
      readFileSync(RELEASE_STATE_PATH, "utf8"),
    ) as Partial<IReleaseState>;
    if (
      value.schemaVersion === 1 &&
      typeof value.version === "string" &&
      typeof value.build === "string" &&
      typeof value.commit === "string" &&
      typeof value.configuration === "string" &&
      Array.isArray(value.completedSteps) &&
      value.completedSteps.every(
        (step, index) => isReleaseStep(step) && step === RELEASE_STEPS[index],
      )
    ) {
      return value as IReleaseState;
    }
  } catch {
    // 损坏或旧格式状态不能作为跳过发布步骤的依据。
  }
  return null;
}

/** 判断外部 JSON 中的字符串是否属于已知发布步骤。 */
function isReleaseStep(value: unknown): value is IReleaseStep {
  return (
    typeof value === "string" && RELEASE_STEPS.includes(value as IReleaseStep)
  );
}

/** 判断断点记录是否准确对应当前源码发布身份。 */
function releaseIdentityMatches(
  state: IReleaseState,
  identity: IReleaseIdentity,
): boolean {
  return (
    state.version === identity.version &&
    state.build === identity.build &&
    state.commit === identity.commit &&
    state.configuration === identity.configuration
  );
}

/** 验证完成标记或首次接管的产物，验证失败时清除该步及后续断点。 */
async function shouldResumeStep(
  state: IReleaseState,
  step: IReleaseStep,
  validate: () => Promise<boolean>,
): Promise<boolean> {
  const wasCompleted = state.completedSteps.includes(step);
  if (!wasCompleted && !allowExistingArtifactAdoption) return false;

  let valid = false;
  try {
    valid = await validate();
  } catch {
    valid = false;
  }
  if (valid) {
    if (!wasCompleted) await completeReleaseStep(state, step);
    return true;
  }
  allowExistingArtifactAdoption = false;
  if (wasCompleted) await invalidateReleaseStep(state, step);
  return false;
}

/** 原子写入一个成功步骤，进程中断不会留下半份 JSON。 */
async function completeReleaseStep(
  state: IReleaseState,
  step: IReleaseStep,
): Promise<void> {
  if (!state.completedSteps.includes(step)) {
    state.completedSteps = RELEASE_STEPS.slice(
      0,
      RELEASE_STEPS.indexOf(step) + 1,
    );
    await writeReleaseState(state);
  }
}

/** 清除无效步骤及依赖它的全部后续步骤。 */
async function invalidateReleaseStep(
  state: IReleaseState,
  step: IReleaseStep,
): Promise<void> {
  const invalidIndex = RELEASE_STEPS.indexOf(step);
  state.completedSteps = state.completedSteps.filter(
    (completed) => RELEASE_STEPS.indexOf(completed) < invalidIndex,
  );
  await writeReleaseState(state);
}

/** 使用临时文件替换发布状态，避免异常退出损坏断点。 */
async function writeReleaseState(state: IReleaseState): Promise<void> {
  const temporaryPath = `${RELEASE_STATE_PATH}.tmp`;
  await Bun.write(temporaryPath, `${JSON.stringify(state, null, 2)}\n`);
  renameSync(temporaryPath, RELEASE_STATE_PATH);
}

/** 验证 Xcode archive 内的 App 版本和签名。 */
async function validateArchive(identity: IReleaseIdentity): Promise<boolean> {
  const archivedApp = join(
    ARCHIVE_PATH,
    "Products",
    "Applications",
    `${APP_NAME}.app`,
  );
  return validateAppIdentityAndSignature(archivedApp, identity);
}

/** 验证 Developer ID 导出的 App 版本和签名。 */
async function validateExportedApp(
  appPath: string,
  identity: IReleaseIdentity,
): Promise<boolean> {
  return validateAppIdentityAndSignature(appPath, identity);
}

/** 验证 App 版本、Sparkle 公钥、arm64 架构和完整代码签名。 */
async function validatePreparedApp(
  appPath: string,
  identity: IReleaseIdentity,
): Promise<boolean> {
  if (!(await validateAppIdentityAndSignature(appPath, identity))) return false;
  for (const path of await listMachOBinaries(appPath)) {
    const architectures = await readArchitectures(path);
    if (architectures.length !== 1 || architectures[0] !== "arm64") {
      return false;
    }
  }
  return true;
}

/** 验证 App 的版本、Sparkle 公钥与代码签名。 */
async function validateAppIdentityAndSignature(
  appPath: string,
  identity: IReleaseIdentity,
): Promise<boolean> {
  if (!existsSync(appPath)) return false;
  const plistPath = join(appPath, "Contents", "Info.plist");
  const version = await readPlistValue(plistPath, "CFBundleShortVersionString");
  const build = await readPlistValue(plistPath, "CFBundleVersion");
  const publicKey = await readPlistValue(plistPath, "SUPublicEDKey");
  if (
    version !== identity.version ||
    build !== identity.build ||
    !isValidSparklePublicKey(publicKey)
  ) {
    return false;
  }

  const signature =
    await $`codesign --verify --deep --strict --verbose=2 ${appPath}`
      .quiet()
      .nothrow();
  if (signature.exitCode !== 0) return false;
  return true;
}

/** 安全读取 Plist 原始字符串；缺失字段返回空字符串。 */
async function readPlistValue(path: string, key: string): Promise<string> {
  const result = await $`plutil -extract ${key} raw ${path}`.quiet().nothrow();
  return result.exitCode === 0 ? result.stdout.toString().trim() : "";
}

/** 验证 DMG 存在且代码签名完整。 */
async function validateSignedDmg(path: string): Promise<boolean> {
  if (!existsSync(path) || Bun.file(path).size === 0) return false;
  return (
    (await $`codesign --verify --strict --verbose=2 ${path}`.quiet().nothrow())
      .exitCode === 0
  );
}

/** 验证 App 与 DMG 均已装订有效的 Apple 公证票据。 */
async function validateStapledArtifacts(
  appPath: string,
  dmgPath: string,
): Promise<boolean> {
  if (!existsSync(appPath) || !existsSync(dmgPath)) return false;
  const absoluteAppPath = resolve(appPath);
  const absoluteDmgPath = resolve(dmgPath);
  const appTicket = await $`xcrun stapler validate ${absoluteAppPath}`
    .quiet()
    .nothrow();
  const dmgTicket = await $`xcrun stapler validate ${absoluteDmgPath}`
    .quiet()
    .nothrow();
  return appTicket.exitCode === 0 && dmgTicket.exitCode === 0;
}

/** 验证 Sparkle 更新产物齐全，且 appcast 包含当前版本。 */
async function validateUpdateArtifacts(
  zipPath: string,
  notesPath: string,
  appcastPath: string,
  version: string,
): Promise<boolean> {
  for (const path of [zipPath, notesPath, appcastPath]) {
    if (!existsSync(path) || Bun.file(path).size === 0) return false;
  }
  return readFileSync(appcastPath, "utf8").includes(version);
}

/** 验证本地及远端标签都指向当前提交。 */
async function validateReleaseTag(tag: string): Promise<boolean> {
  const head = (await $`git rev-parse HEAD`.text()).trim();
  const localTag = await $`git rev-list -n 1 ${tag}`.quiet().nothrow();
  if (localTag.exitCode !== 0 || localTag.stdout.toString().trim() !== head) {
    return false;
  }
  const remoteTag =
    await $`git ls-remote origin ${`refs/tags/${tag}`} ${`refs/tags/${tag}^{}`}`
      .quiet()
      .nothrow();
  return (
    remoteTag.exitCode === 0 &&
    remoteTag.stdout.toString().split(/\s+/).includes(head)
  );
}

/** 验证 GitHub Release 中包含全部必需资产。 */
async function validatePublishedRelease(
  tag: string,
  requiredAssetNames: string[],
): Promise<boolean> {
  const result =
    await $`gh release view ${tag} --repo ${GITHUB_REPOSITORY} --json assets`
      .quiet()
      .nothrow();
  if (result.exitCode !== 0) return false;
  try {
    const value = JSON.parse(result.stdout.toString()) as {
      assets?: Array<{ name?: unknown }>;
    };
    const assetNames = new Set(
      value.assets
        ?.map((asset) => asset.name)
        .filter((name): name is string => typeof name === "string") ?? [],
    );
    return requiredAssetNames.every((name) => assetNames.has(name));
  } catch {
    return false;
  }
}

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
