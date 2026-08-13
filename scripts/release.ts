#!/usr/bin/env bun
// 构建、签名、公证 Qjiao，并将全部发布资产上传到 GitHub Releases。
import { $ } from "bun";
import {
  constants as fsConstants,
  copyFileSync,
  existsSync,
  lstatSync,
  mkdirSync,
  readFileSync,
  readdirSync,
  renameSync,
  rmSync,
} from "node:fs";
import { createHash } from "node:crypto";
import { basename, join, resolve } from "node:path";
import { extractReleaseNotes } from "./changelog";
import {
  DOWNLOAD_MANIFEST_RELATIVE_PATHS,
  LEGACY_LATEST_JSON_RELATIVE_PATHS,
  buildDownloadManifest,
  isDownloadManifest,
  writeDownloadManifestFiles,
} from "./download-manifest";
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
  | "dmg-packaged"
  | "dmg-signed"
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
  appSourceFingerprint: string;
  releaseNotesFingerprint: string;
}

/** 持久化在 build 目录内的发布断点。 */
interface IReleaseState extends IReleaseIdentity {
  schemaVersion: 2;
  completedSteps: IReleaseStep[];
}

/** release/ 中一个经过校验的完整更新归档。 */
interface IReleaseCacheEntry {
  version: string;
  build: string;
  tag: string;
  archiveName: string;
  sha256: string;
  size: number;
  publishedAt: string;
}

/** release/ 中的本地 Sparkle 历史清单。 */
interface IReleaseCacheManifest {
  schemaVersion: 1;
  entries: IReleaseCacheEntry[];
}

const RELEASE_STEPS: IReleaseStep[] = [
  "archive-created",
  "app-exported",
  "app-prepared",
  "dmg-packaged",
  "dmg-signed",
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
const RELEASE_CACHE_DIR = process.env.RELEASE_CACHE_DIR ?? "release";
const RELEASE_CACHE_ARCHIVES_DIR = join(RELEASE_CACHE_DIR, "archives");
const RELEASE_CACHE_APPCAST_PATH = join(RELEASE_CACHE_DIR, "appcast.xml");
const RELEASE_CACHE_MANIFEST_PATH = join(RELEASE_CACHE_DIR, "manifest.json");
const MAX_DELTA_BASELINES = 3;
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
const UPDATE_PIPELINE_VERSION = "5";
const FORCE_RELEASE = process.env.FORCE !== "0";
const ARCHIVE_RETRIES = readPositiveInteger(
  "ARCHIVE_RETRIES",
  process.env.ARCHIVE_RETRIES,
  3,
);
const TIMESTAMP_RETRIES = readPositiveInteger(
  "TIMESTAMP_RETRIES",
  process.env.TIMESTAMP_RETRIES,
  3,
);
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
need("hdiutil");
need("lipo");
need("xattr");
if (process.env.PUBLISH !== "0") {
  need("git");
  need("gh");
  const changes = (
    await $`git -c core.fsmonitor=false status --porcelain`.text()
  ).trim();
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
if (!releaseState.completedSteps.includes("updates-generated")) {
  assertBuildIsNewerThanCache(build, version);
}

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
      allowExistingArtifactAdoption = false;
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
      await archiveWithCodeSignRetry(signingArgs);
      if (!(await validateArchive(identity))) {
        die("the Xcode archive failed version or signature checks");
      }
      await completeReleaseStep(releaseState, "archive-created");
    }

    allowExistingArtifactAdoption = false;
    say("Exporting Developer ID app…");
    rmSync(EXPORT_DIR, { recursive: true, force: true });
    await $`xcodebuild -exportArchive -archivePath ${ARCHIVE_PATH} -exportOptionsPlist ${EXPORT_OPTIONS} -exportPath ${EXPORT_DIR}`;
    if (!(await validateExportedApp(app, identity))) {
      die("the exported App failed version or signature checks");
    }
    await completeReleaseStep(releaseState, "app-exported");
  }

  allowExistingArtifactAdoption = false;
  say("Thinning Qjiao to arm64 and re-signing nested code…");
  await prepareAndSignExportedApp(app, SIGN_IDENTITY);
  if (!(await validatePreparedApp(app, identity))) {
    die("the prepared App failed version, architecture, or signature checks");
  }
  await completeReleaseStep(releaseState, "app-prepared");
}

if (
  await shouldResumeStep(releaseState, "dmg-signed", () =>
    validateSignedDmg(dmgPath),
  )
) {
  say("Resuming: signed DMG is already complete.");
} else {
  if (
    await shouldResumeStep(releaseState, "dmg-packaged", () =>
      validatePackagedDmg(dmgPath),
    )
  ) {
    say("Resuming: unsigned DMG package is already complete.");
  } else {
    allowExistingArtifactAdoption = false;
    say(`Packaging Qjiao ${version} (build ${build})…`);
    rmSync(dmgStaging, { recursive: true, force: true });
    rmSync(dmgPath, { force: true });
    mkdirSync(dmgStaging, { recursive: true });
    await $`ditto ${app} ${join(dmgStaging, `${APP_NAME}.app`)}`;
    await $`create-dmg --volname ${`${APP_NAME} ${version}`} --window-size 540 380 --icon-size 128 --icon ${`${APP_NAME}.app`} 150 195 --app-drop-link 390 195 --hide-extension ${`${APP_NAME}.app`} --no-internet-enable ${dmgPath} ${dmgStaging}`.nothrow();
    if (!(await validatePackagedDmg(dmgPath))) {
      die("create-dmg did not produce a valid disk image");
    }
    await completeReleaseStep(releaseState, "dmg-packaged");
  }

  allowExistingArtifactAdoption = false;
  say("Signing DMG with Apple secure timestamp…");
  await signDmgWithRetry(dmgPath, SIGN_IDENTITY);
  await $`codesign --verify --strict --verbose=2 ${dmgPath}`;
  await completeReleaseStep(releaseState, "dmg-signed");
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
  allowExistingArtifactAdoption = false;
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
    validateUpdateArtifacts(
      zipPath,
      notesPath,
      appcastPath,
      version,
      build,
      tag,
    ),
  )
) {
  say("Resuming: Sparkle ZIP, notes, and appcast are already complete.");
} else {
  allowExistingArtifactAdoption = false;
  rmSync(UPDATES_DIR, { recursive: true, force: true });
  mkdirSync(UPDATES_DIR, { recursive: true });
  if (process.env.NO_HISTORY !== "1") {
    await prepareLocalDeltaBaselines(build);
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
    versions: [build],
  });
  await normalizeAppcastArchiveUrls(appcastPath);
  if (
    !(await validateUpdateArtifacts(
      zipPath,
      notesPath,
      appcastPath,
      version,
      build,
      tag,
    ))
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
  allowExistingArtifactAdoption = false;
  await createAndPushReleaseTag(tag, version);
  await completeReleaseStep(releaseState, "tag-pushed");
}

const releaseAssetPaths = [
  dmgPath,
  zipPath,
  notesPath,
  appcastPath,
  ...listGeneratedDeltaPaths(),
];
const releaseAssetNames = releaseAssetPaths.map((path) => basename(path));
if (
  await shouldResumeStep(releaseState, "release-published", () =>
    validatePublishedRelease(tag, releaseAssetNames),
  )
) {
  say(`Resuming: GitHub Release ${tag} is already complete.`);
} else {
  allowExistingArtifactAdoption = false;
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
  if (!existingRelease) {
    await $`gh release create ${tag} --repo ${GITHUB_REPOSITORY} --verify-tag --title ${`${APP_NAME} ${version}`} --notes-file ${notesPath}`;
  }
  for (const [index, assetPath] of releaseAssetPaths.entries()) {
    await uploadReleaseAsset(
      tag,
      assetPath,
      index + 1,
      releaseAssetPaths.length,
    );
  }
  await $`gh release edit ${tag} --repo ${GITHUB_REPOSITORY} --draft=false --latest --title ${`${APP_NAME} ${version}`} --notes-file ${notesPath}`;
  if (!(await validatePublishedRelease(tag, releaseAssetNames))) {
    die(`GitHub Release ${tag} is still a draft or missing required assets`);
  }
  await completeReleaseStep(releaseState, "release-published");
}

await persistReleaseCache(identity, tag, zipPath, appcastPath);

say("Writing website download manifest…");
const downloadManifest = buildDownloadManifest({
  repository: GITHUB_REPOSITORY,
  version,
  tag,
  publishedAt: await readPublishedAt(tag),
});
const writtenDownloadPaths = writeDownloadManifestFiles(
  downloadManifest,
  GITHUB_REPOSITORY,
);
if (!isDownloadManifest(downloadManifest) || !downloadManifest.dmg.url) {
  die("generated website download manifest is invalid");
}
await commitAndPushWebsiteDownloadManifest(version);
say(`Website download manifest: ${writtenDownloadPaths[0]}`);

say(`Qjiao ${version} is live on GitHub:`);
console.log(
  `  release: https://github.com/${GITHUB_REPOSITORY}/releases/tag/${tag}`,
);
console.log(
  `  latest:  https://github.com/${GITHUB_REPOSITORY}/releases/latest`,
);
console.log(`  dmg:     ${downloadManifest.dmg.url}`);

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
  if (!/^[1-9][0-9]*$/.test(build)) {
    die("CURRENT_PROJECT_VERSION must be a positive integer");
  }
  const appSourceFingerprint = await createAppSourceFingerprint();
  const releaseNotesFingerprint = createUpdateArtifactsFingerprint();
  return {
    version,
    build,
    commit,
    configuration: CONFIGURATION,
    appSourceFingerprint,
    releaseNotesFingerprint,
  };
}

/** 从 xcodebuild 的 Build Settings 输出中读取单个配置值。 */
function readBuildSetting(output: string, name: string): string {
  const match = output.match(new RegExp(`^\\s*${name} = (.+)$`, "m"));
  return match?.[1]?.trim() ?? "";
}

/** 读取正整数环境变量，非法输入立即终止发布。 */
function readPositiveInteger(
  name: string,
  value: string | undefined,
  fallback: number,
): number {
  if (value === undefined) return fallback;
  const parsed = Number(value);
  if (!Number.isInteger(parsed) || parsed < 1) {
    die(`${name} must be a positive integer`);
  }
  return parsed;
}

/**
 * Xcode 偶尔会在并行归档资源 bundle 时留下不完整签名。
 * 仅对明确的 CodeSign 失败增量重试，并保留 DerivedData 编译缓存。
 */
async function archiveWithCodeSignRetry(signingArgs: string[]): Promise<void> {
  for (let attempt = 1; attempt <= ARCHIVE_RETRIES; attempt += 1) {
    const result =
      await $`xcodebuild -project ${PROJECT} -scheme ${SCHEME} -configuration ${CONFIGURATION} -archivePath ${ARCHIVE_PATH} ${signingArgs} archive`.nothrow();
    if (result.exitCode === 0) return;

    const output = `${result.stdout.toString()}\n${result.stderr.toString()}`;
    const isCodeSignFailure = /Command CodeSign failed|^\s*CodeSign\s+/im.test(
      output,
    );
    if (!isCodeSignFailure || attempt === ARCHIVE_RETRIES) {
      die(
        isCodeSignFailure
          ? `Xcode archive CodeSign failed after ${ARCHIVE_RETRIES} attempts`
          : "Xcode archive failed",
      );
    }

    const delay = Math.min(attempt * 3_000, 10_000);
    say(
      `Xcode archive hit a transient CodeSign failure; retrying ` +
        `incrementally in ${delay / 1_000}s (${attempt}/${ARCHIVE_RETRIES})…`,
    );
    await Bun.sleep(delay);
  }
}

/** 逐个上传 Release 资产，并定期报告等待时间。 */
async function uploadReleaseAsset(
  tag: string,
  assetPath: string,
  index: number,
  total: number,
): Promise<void> {
  const name = assetPath.split("/").at(-1) ?? assetPath;
  const size = formatByteSize(Bun.file(assetPath).size);
  const startedAt = Date.now();
  say(`Uploading asset ${index}/${total}: ${name} (${size})…`);
  const heartbeat = setInterval(() => {
    const elapsed = Math.floor((Date.now() - startedAt) / 1_000);
    console.log(`  ${name}: upload still running (${elapsed}s elapsed)`);
  }, 15_000);

  try {
    await $`gh release upload ${tag} ${assetPath} --repo ${GITHUB_REPOSITORY} --clobber`;
  } finally {
    clearInterval(heartbeat);
  }
  const elapsed = Math.max(1, Math.round((Date.now() - startedAt) / 1_000));
  say(`Uploaded ${name} in ${elapsed}s.`);
}

/** 将字节数格式化为适合发布日志的二进制单位。 */
function formatByteSize(bytes: number): string {
  if (bytes < 1_024) return `${bytes} B`;
  const units = ["KiB", "MiB", "GiB"];
  let value = bytes / 1_024;
  let unit = units[0];
  for (let index = 1; index < units.length && value >= 1_024; index += 1) {
    value /= 1_024;
    unit = units[index];
  }
  return `${value.toFixed(1)} ${unit}`;
}

/** 将本地 release/ 历史复制到临时更新目录，作为 delta 生成基线。 */
async function prepareLocalDeltaBaselines(currentBuild: string): Promise<void> {
  const manifest = readReleaseCacheManifest();
  if (
    existsSync(RELEASE_CACHE_APPCAST_PATH) &&
    Bun.file(RELEASE_CACHE_APPCAST_PATH).size > 0
  ) {
    copyFileAtomically(RELEASE_CACHE_APPCAST_PATH, appcastPath);
    await normalizeAppcastArchiveUrls(appcastPath);
    say(`Using local Sparkle history: ${RELEASE_CACHE_APPCAST_PATH}`);
  }

  const candidates = manifest.entries
    .filter((entry) => entry.build !== currentBuild)
    .sort(
      (left, right) =>
        Date.parse(right.publishedAt) - Date.parse(left.publishedAt),
    )
    .slice(0, MAX_DELTA_BASELINES);
  let copied = 0;
  for (const entry of candidates) {
    if (!(await validateReleaseCacheEntry(entry))) {
      console.warn(
        `warning: ignoring invalid delta baseline ${entry.archiveName}`,
      );
      continue;
    }
    copyFileAtomically(
      join(RELEASE_CACHE_ARCHIVES_DIR, entry.archiveName),
      join(UPDATES_DIR, entry.archiveName),
    );
    copied += 1;
    say(
      `Using delta baseline ${copied}/${MAX_DELTA_BASELINES}: ` +
        `${entry.archiveName} (build ${entry.build})`,
    );
  }
  if (copied === 0) {
    say("No valid local delta baseline; generating a full update only.");
  }
}

/** 防止重新签名后覆盖或回退已发布的 delta 基线。 */
function assertBuildIsNewerThanCache(build: string, version: string): void {
  const cachedBuilds = readReleaseCacheManifest().entries.map((entry) =>
    BigInt(entry.build),
  );
  if (cachedBuilds.length === 0) return;
  const latestBuild = cachedBuilds.reduce((latest, cached) =>
    cached > latest ? cached : latest,
  );
  if (BigInt(build) <= latestBuild) {
    die(
      `build ${build} is not newer than cached build ${latestBuild}; ` +
        `increment CURRENT_PROJECT_VERSION before publishing ${version}`,
    );
  }
}

/** 生成前后强制历史完整 ZIP 指向其自身的 GitHub tag。 */
async function normalizeAppcastArchiveUrls(path: string): Promise<void> {
  const original = readFileSync(path, "utf8");
  const normalized = original.replace(
    /<item>[\s\S]*?<\/item>/g,
    (item): string => {
      const version = item.match(
        /<sparkle:shortVersionString>([^<]+)<\/sparkle:shortVersionString>/,
      )?.[1];
      if (!version || !/^[0-9A-Za-z.+-]+$/.test(version)) return item;

      const archiveUrl = expectedArchiveUrl(version);
      return item
        .replace(/<title>[^<]*<\/title>/, `<title>${version}</title>`)
        .replace(/(<enclosure\s+url=")[^"]+\.zip(")/, `$1${archiveUrl}$2`);
    },
  );
  if (normalized !== original) {
    await Bun.write(path, normalized);
  }
}

/** 构造项目约定的按版本 tag 托管地址。 */
function expectedArchiveUrl(version: string): string {
  const tag = `v${version}`;
  const name = `${ARTIFACT_PREFIX}-${version}.zip`;
  return (
    `https://github.com/${GITHUB_REPOSITORY}/releases/download/` +
    `${encodeURIComponent(tag)}/${encodeURIComponent(name)}`
  );
}

/** 正式发布成功后，把当前完整 ZIP 和 appcast 原子写入 release/。 */
async function persistReleaseCache(
  identity: IReleaseIdentity,
  tag: string,
  zipPath: string,
  appcastPath: string,
): Promise<void> {
  if (
    !existsSync(zipPath) ||
    Bun.file(zipPath).size === 0 ||
    !existsSync(appcastPath) ||
    Bun.file(appcastPath).size === 0
  ) {
    die("cannot persist incomplete Sparkle release cache");
  }

  mkdirSync(RELEASE_CACHE_ARCHIVES_DIR, { recursive: true });
  const archiveName = basename(zipPath);
  const cachedArchivePath = join(RELEASE_CACHE_ARCHIVES_DIR, archiveName);
  const entry: IReleaseCacheEntry = {
    version: identity.version,
    build: identity.build,
    tag,
    archiveName,
    sha256: await createFileSha256(zipPath),
    size: Bun.file(zipPath).size,
    publishedAt: new Date().toISOString(),
  };

  copyFileAtomically(zipPath, cachedArchivePath);
  if (!(await validateReleaseCacheEntry(entry))) {
    die(`cached update archive failed validation: ${archiveName}`);
  }
  copyFileAtomically(appcastPath, RELEASE_CACHE_APPCAST_PATH);

  const previousManifest = readReleaseCacheManifest();
  const entries = [
    entry,
    ...previousManifest.entries.filter(
      (cached) =>
        cached.build !== entry.build &&
        cached.archiveName !== entry.archiveName,
    ),
  ]
    .sort(
      (left, right) =>
        Date.parse(right.publishedAt) - Date.parse(left.publishedAt),
    )
    .slice(0, MAX_DELTA_BASELINES);
  await writeReleaseCacheManifest({ schemaVersion: 1, entries });

  const keptNames = new Set(entries.map((cached) => cached.archiveName));
  for (const name of readdirSync(RELEASE_CACHE_ARCHIVES_DIR)) {
    if (
      name.startsWith(`${ARTIFACT_PREFIX}-`) &&
      name.endsWith(".zip") &&
      !keptNames.has(name)
    ) {
      rmSync(join(RELEASE_CACHE_ARCHIVES_DIR, name), {
        force: true,
      });
    }
  }
  say(
    `Stored local Sparkle history in ${RELEASE_CACHE_DIR} ` +
      `(${entries.length}/${MAX_DELTA_BASELINES} versions).`,
  );
}

/** 读取 release/manifest.json；损坏清单不会用于生成差分。 */
function readReleaseCacheManifest(): IReleaseCacheManifest {
  if (!existsSync(RELEASE_CACHE_MANIFEST_PATH)) {
    return { schemaVersion: 1, entries: [] };
  }
  try {
    const value = JSON.parse(
      readFileSync(RELEASE_CACHE_MANIFEST_PATH, "utf8"),
    ) as {
      schemaVersion?: unknown;
      entries?: unknown;
    };
    if (value.schemaVersion !== 1 || !Array.isArray(value.entries)) {
      throw new Error("unsupported manifest schema");
    }
    const entries = value.entries.filter(isReleaseCacheEntry);
    if (entries.length !== value.entries.length) {
      throw new Error("invalid manifest entry");
    }
    return { schemaVersion: 1, entries };
  } catch {
    console.warn(
      `warning: ignoring invalid release cache manifest: ` +
        RELEASE_CACHE_MANIFEST_PATH,
    );
    return { schemaVersion: 1, entries: [] };
  }
}

/** 校验来自 JSON 的 release 缓存条目，避免路径越界和伪造摘要。 */
function isReleaseCacheEntry(value: unknown): value is IReleaseCacheEntry {
  if (!value || typeof value !== "object") return false;
  const entry = value as Partial<IReleaseCacheEntry>;
  return (
    typeof entry.version === "string" &&
    entry.version.length > 0 &&
    typeof entry.build === "string" &&
    /^[1-9][0-9]*$/.test(entry.build) &&
    typeof entry.tag === "string" &&
    entry.tag.length > 0 &&
    typeof entry.archiveName === "string" &&
    basename(entry.archiveName) === entry.archiveName &&
    entry.archiveName.endsWith(".zip") &&
    typeof entry.sha256 === "string" &&
    /^[a-f0-9]{64}$/.test(entry.sha256) &&
    typeof entry.size === "number" &&
    Number.isSafeInteger(entry.size) &&
    entry.size > 0 &&
    typeof entry.publishedAt === "string" &&
    Number.isFinite(Date.parse(entry.publishedAt))
  );
}

/** 复验缓存 ZIP 的文件大小和 SHA-256。 */
async function validateReleaseCacheEntry(
  entry: IReleaseCacheEntry,
): Promise<boolean> {
  const path = join(RELEASE_CACHE_ARCHIVES_DIR, entry.archiveName);
  return (
    existsSync(path) &&
    Bun.file(path).size === entry.size &&
    (await createFileSha256(path)) === entry.sha256
  );
}

/** 流式计算大文件 SHA-256，避免一次把 ZIP 全部读入内存。 */
async function createFileSha256(path: string): Promise<string> {
  const hash = new Bun.CryptoHasher("sha256");
  for await (const chunk of Bun.file(path).stream()) {
    hash.update(chunk);
  }
  return hash.digest("hex");
}

/** 通过同目录临时文件原子复制；APFS 上优先使用写时复制。 */
function copyFileAtomically(source: string, destination: string): void {
  const temporaryPath = `${destination}.${process.pid}.tmp`;
  rmSync(temporaryPath, { force: true });
  try {
    copyFileSync(source, temporaryPath, fsConstants.COPYFILE_FICLONE);
    renameSync(temporaryPath, destination);
  } finally {
    rmSync(temporaryPath, { force: true });
  }
}

/** 原子保存 release/manifest.json。 */
async function writeReleaseCacheManifest(
  manifest: IReleaseCacheManifest,
): Promise<void> {
  mkdirSync(RELEASE_CACHE_DIR, { recursive: true });
  const temporaryPath = `${RELEASE_CACHE_MANIFEST_PATH}.${process.pid}.tmp`;
  try {
    await Bun.write(temporaryPath, `${JSON.stringify(manifest, null, 2)}\n`);
    renameSync(temporaryPath, RELEASE_CACHE_MANIFEST_PATH);
  } finally {
    rmSync(temporaryPath, { force: true });
  }
}

/** 列出 generate_appcast 在本次更新目录生成的 delta 资产。 */
function listGeneratedDeltaPaths(): string[] {
  if (!existsSync(UPDATES_DIR)) return [];
  return readdirSync(UPDATES_DIR)
    .filter((name) => name.endsWith(".delta"))
    .sort()
    .map((name) => join(UPDATES_DIR, name));
}

/** 计算真正影响 macOS App 构建和签名的输入指纹。 */
async function createAppSourceFingerprint(): Promise<string> {
  const hash = createHash("sha256");
  for (const path of ["Qjiao.xcodeproj", "kero"]) {
    const result = await $`git rev-parse ${`HEAD:${path}`}`.quiet().nothrow();
    hash.update(path);
    hash.update(
      result.exitCode === 0 ? result.stdout.toString().trim() : "unavailable",
    );
  }
  hash.update(teamId);
  hash.update(SIGN_IDENTITY);
  return hash.digest("hex");
}

/** 计算单个发布输入文件的内容指纹。 */
function createFileFingerprint(path: string): string {
  const hash = createHash("sha256");
  hash.update(existsSync(path) ? readFileSync(path) : "missing");
  return hash.digest("hex");
}

/** 让更新产物生成方式升级时仅使更新及后续断点失效。 */
function createUpdateArtifactsFingerprint(): string {
  const hash = createHash("sha256");
  hash.update(createFileFingerprint("CHANGELOG.md"));
  hash.update(UPDATE_PIPELINE_VERSION);
  return hash.digest("hex");
}

/** 加载断点，并仅使受当前变更影响的步骤失效。 */
async function initializeReleaseState(
  identity: IReleaseIdentity,
): Promise<IReleaseState> {
  if (RESET_RELEASE) {
    rmSync(RELEASE_STATE_PATH, { force: true });
  }

  const existingState = readReleaseState();
  if (
    existingState &&
    existingState.version === identity.version &&
    existingState.build === identity.build &&
    existingState.configuration === identity.configuration
  ) {
    allowExistingArtifactAdoption = true;
    if (
      existingState.appSourceFingerprint &&
      existingState.appSourceFingerprint !== identity.appSourceFingerprint
    ) {
      say("App source changed; archive and all later checkpoints are invalid.");
      truncateReleaseSteps(existingState, "archive-created");
      allowExistingArtifactAdoption = false;
    } else if (!existingState.appSourceFingerprint) {
      say("Migrating legacy checkpoints after validating their artifacts.");
    }
    if (
      existingState.releaseNotesFingerprint &&
      existingState.releaseNotesFingerprint !== identity.releaseNotesFingerprint
    ) {
      say(
        "CHANGELOG changed; update artifacts and later checkpoints are invalid.",
      );
      truncateReleaseSteps(existingState, "updates-generated");
    }
    if (existingState.commit !== identity.commit) {
      say(
        "Git commit changed; keeping build artifacts and refreshing tag/release.",
      );
      truncateReleaseSteps(existingState, "tag-pushed");
    }
    Object.assign(existingState, identity, { schemaVersion: 2 as const });
    await writeReleaseState(existingState);
    return existingState;
  }

  if (existingState) {
    const changes = [
      existingState.version !== identity.version
        ? `version ${existingState.version} → ${identity.version}`
        : null,
      existingState.build !== identity.build
        ? `build ${existingState.build} → ${identity.build}`
        : null,
      existingState.configuration !== identity.configuration
        ? `configuration ${existingState.configuration} → ${identity.configuration}`
        : null,
    ].filter((change): change is string => change !== null);
    say(`Release identity changed (${changes.join(", ")}); rebuilding.`);
  } else if (!RESET_RELEASE) {
    // 兼容升级断点脚本前已经生成的同版本 App 和 DMG。
    allowExistingArtifactAdoption = true;
  }

  const state: IReleaseState = {
    schemaVersion: 2,
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
    const value = JSON.parse(readFileSync(RELEASE_STATE_PATH, "utf8")) as {
      schemaVersion?: unknown;
      version?: unknown;
      build?: unknown;
      commit?: unknown;
      configuration?: unknown;
      appSourceFingerprint?: unknown;
      releaseNotesFingerprint?: unknown;
      completedSteps?: unknown;
    };
    if (
      typeof value.version !== "string" ||
      typeof value.build !== "string" ||
      typeof value.commit !== "string" ||
      typeof value.configuration !== "string" ||
      !Array.isArray(value.completedSteps)
    ) {
      return null;
    }

    const completedSteps = normalizeStoredReleaseSteps(
      value.schemaVersion,
      value.completedSteps,
    );
    if (!completedSteps) return null;
    return {
      schemaVersion: 2,
      version: value.version,
      build: value.build,
      commit: value.commit,
      configuration: value.configuration,
      appSourceFingerprint:
        typeof value.appSourceFingerprint === "string"
          ? value.appSourceFingerprint
          : "",
      releaseNotesFingerprint:
        typeof value.releaseNotesFingerprint === "string"
          ? value.releaseNotesFingerprint
          : "",
      completedSteps,
    };
  } catch {
    // 损坏或旧格式状态不能作为跳过发布步骤的依据。
  }
  return null;
}

/** 迁移旧版步骤名称，并确保断点始终是连续前缀。 */
function normalizeStoredReleaseSteps(
  schemaVersion: unknown,
  steps: unknown[],
): IReleaseStep[] | null {
  if (schemaVersion === 1) {
    const legacySteps = [
      "archive-created",
      "app-exported",
      "app-prepared",
      "dmg-created",
      "notarized",
      "updates-generated",
      "tag-pushed",
      "release-published",
    ];
    if (!steps.every((step, index) => step === legacySteps[index])) return null;
    return steps.flatMap((step) =>
      step === "dmg-created"
        ? (["dmg-packaged", "dmg-signed"] as IReleaseStep[])
        : ([step] as IReleaseStep[]),
    );
  }
  if (
    schemaVersion === 2 &&
    steps.every(
      (step, index) => isReleaseStep(step) && step === RELEASE_STEPS[index],
    )
  ) {
    return steps as IReleaseStep[];
  }
  return null;
}

/** 判断外部 JSON 中的字符串是否属于已知发布步骤。 */
function isReleaseStep(value: unknown): value is IReleaseStep {
  return (
    typeof value === "string" && RELEASE_STEPS.includes(value as IReleaseStep)
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
  truncateReleaseSteps(state, step);
  await writeReleaseState(state);
}

/** 在内存中清除指定步骤及依赖它的全部后续步骤。 */
function truncateReleaseSteps(state: IReleaseState, step: IReleaseStep): void {
  const invalidIndex = RELEASE_STEPS.indexOf(step);
  state.completedSteps = state.completedSteps.filter(
    (completed) => RELEASE_STEPS.indexOf(completed) < invalidIndex,
  );
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
  // zsh 会写入历史文件；签名包中出现该文件会让运行后的 App 失去 delta 资格。
  if (containsFileNamed(appPath, ".zsh_history")) return false;
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

/** 验证未签名或待重签的 DMG 文件系统映像完整。 */
async function validatePackagedDmg(path: string): Promise<boolean> {
  if (!existsSync(path) || Bun.file(path).size === 0) return false;
  return (
    (await $`hdiutil verify ${resolve(path)}`.quiet().nothrow()).exitCode === 0
  );
}

/** 重试依赖 Apple 在线服务的 DMG secure timestamp 签名。 */
async function signDmgWithRetry(path: string, identity: string): Promise<void> {
  for (let attempt = 1; attempt <= TIMESTAMP_RETRIES; attempt += 1) {
    const result =
      await $`codesign --force --timestamp --sign ${identity} ${path}`
        .quiet()
        .nothrow();
    if (result.exitCode === 0) return;

    const message = result.stderr.toString().trim();
    if (message) console.error(message);
    if (attempt === TIMESTAMP_RETRIES) {
      die(`DMG timestamp signing failed after ${TIMESTAMP_RETRIES} attempts`);
    }
    const delay = Math.min(attempt * 3_000, 10_000);
    say(
      `Timestamp service unavailable; retrying in ${delay / 1_000}s ` +
        `(${attempt}/${TIMESTAMP_RETRIES})…`,
    );
    await Bun.sleep(delay);
  }
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
  build: string,
  tag: string,
): Promise<boolean> {
  for (const path of [zipPath, notesPath, appcastPath]) {
    if (!existsSync(path) || Bun.file(path).size === 0) return false;
  }
  const appcast = readFileSync(appcastPath, "utf8");
  if (
    !appcast.includes(`<sparkle:version>${build}</sparkle:version>`) ||
    !appcast.includes(
      `<sparkle:shortVersionString>${version}</sparkle:shortVersionString>`,
    )
  ) {
    return false;
  }
  if (!validateAppcastArchiveUrls(appcast)) return false;
  for (const name of listReferencedDeltaNames(appcast, tag)) {
    const path = join(UPDATES_DIR, name);
    if (!existsSync(path) || Bun.file(path).size === 0) return false;
  }
  return true;
}

/** 验证每个历史完整 ZIP 仍指向其自身的版本 tag。 */
function validateAppcastArchiveUrls(appcast: string): boolean {
  let itemCount = 0;
  for (const match of appcast.matchAll(/<item>[\s\S]*?<\/item>/g)) {
    const item = match[0];
    const version = item.match(
      /<sparkle:shortVersionString>([^<]+)<\/sparkle:shortVersionString>/,
    )?.[1];
    const archiveUrl = item.match(/<enclosure\s+url="([^"]+\.zip)"/)?.[1];
    if (!version || archiveUrl !== expectedArchiveUrl(version)) return false;
    itemCount += 1;
  }
  return itemCount > 0;
}

/** 提取 appcast 当前托管地址引用的 delta 文件名。 */
function listReferencedDeltaNames(appcast: string, tag: string): string[] {
  const names = new Set<string>();
  for (const match of appcast.matchAll(/\burl="([^"]+\.delta)"/g)) {
    try {
      const url = new URL(match[1].replaceAll("&amp;", "&"));
      const parts = url.pathname
        .split("/")
        .filter(Boolean)
        .map(decodeURIComponent);
      if (
        url.hostname === "github.com" &&
        parts.length === 6 &&
        `${parts[0]}/${parts[1]}`.toLowerCase() ===
          GITHUB_REPOSITORY.toLowerCase() &&
        parts[2] === "releases" &&
        parts[3] === "download" &&
        parts[4] === tag
      ) {
        names.add(parts[5]);
      }
    } catch {
      // 非法 URL 会在 Sparkle 实际读取前由其他 appcast 验证发现。
    }
  }
  return [...names];
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

/** 验证 GitHub Release 已正式发布并包含全部必需资产。 */
async function validatePublishedRelease(
  tag: string,
  requiredAssetNames: string[],
): Promise<boolean> {
  const result =
    await $`gh release view ${tag} --repo ${GITHUB_REPOSITORY} --json assets,isDraft,tagName`
      .quiet()
      .nothrow();
  if (result.exitCode !== 0) return false;
  try {
    const value = JSON.parse(result.stdout.toString()) as {
      assets?: Array<{ name?: unknown }>;
      isDraft?: unknown;
      tagName?: unknown;
    };
    if (value.isDraft !== false || value.tagName !== tag) return false;
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

/** 判断目录树中是否包含指定文件，并避免进入 Bundle 内的符号链接。 */
function containsFileNamed(directory: string, fileName: string): boolean {
  for (const entry of readdirSync(directory)) {
    const path = join(directory, entry);
    const stat = lstatSync(path);
    if (stat.isSymbolicLink()) continue;
    if (stat.isDirectory()) {
      if (containsFileNamed(path, fileName)) return true;
    } else if (stat.isFile() && entry === fileName) {
      return true;
    }
  }
  return false;
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

/** 读取已发布 GitHub Release 的时间，失败时用当前时间兜底。 */
async function readPublishedAt(tag: string): Promise<string> {
  const result =
    await $`gh release view ${tag} --repo ${GITHUB_REPOSITORY} --json publishedAt`
      .quiet()
      .nothrow();
  if (result.exitCode === 0) {
    try {
      const value = JSON.parse(result.stdout.toString()) as {
        publishedAt?: unknown;
      };
      if (typeof value.publishedAt === "string" && value.publishedAt) {
        return value.publishedAt;
      }
    } catch {
      // 解析失败时用本地时间，不阻断已成功的 GitHub 发布。
    }
  }
  return new Date().toISOString();
}

/** 将官网下载清单提交并推送，让 GitHub Pages 能立刻提供直链。 */
async function commitAndPushWebsiteDownloadManifest(
  version: string,
): Promise<void> {
  const paths = [
    ...DOWNLOAD_MANIFEST_RELATIVE_PATHS,
    ...LEGACY_LATEST_JSON_RELATIVE_PATHS,
  ];
  const status = (
    await $`git -c core.fsmonitor=false status --porcelain ${paths}`.text()
  ).trim();
  if (!status) {
    say("Website download manifest is already committed.");
    return;
  }

  await $`git add ${paths}`;
  const commit = await $`git commit -m ${`chore(release): 更新官网下载清单 ${version}`}`
    .nothrow();
  if (commit.exitCode !== 0) {
    console.error(
      "warning: failed to commit website download manifest; commit it manually",
    );
    return;
  }

  const push = await $`git push origin HEAD`.nothrow();
  if (push.exitCode !== 0) {
    console.error(
      "warning: failed to push website download manifest; push the commit manually",
    );
    return;
  }
  say(`Pushed website download manifest for ${version}.`);
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
