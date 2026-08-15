import { mkdtempSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { expect, test } from "bun:test";
import {
  collectSparkleAttachments,
  r2PublicUrl,
  readSparkleSignatures,
} from "./qrls-publish";

const sampleAppcast = `<?xml version="1.0" encoding="utf-8"?>
<rss version="2.0" xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle">
  <channel>
    <item>
      <title>1.1.49</title>
      <enclosure url="https://download.qzrzz.com/qjiao/qjiao-1.1.49.zip" sparkle:version="149" sparkle:shortVersionString="1.1.49" length="10" type="application/octet-stream" sparkle:edSignature="zip-sig" />
      <sparkle:deltas>
        <enclosure url="https://download.qzrzz.com/qjiao/Qjiao149-148.delta" sparkle:version="149" sparkle:shortVersionString="1.1.49" length="4" type="application/octet-stream" sparkle:deltaFrom="148" sparkle:edSignature="delta-sig" />
      </sparkle:deltas>
    </item>
  </channel>
</rss>
`;

test("r2PublicUrl 使用稳定公开前缀", () => {
  expect(r2PublicUrl("appcast.xml")).toBe(
    "https://download.qzrzz.com/qjiao/appcast.xml",
  );
});

test("从 generate_appcast 产物读取当前 build 的 ZIP 与 delta 签名", () => {
  const dir = mkdtempSync(join(tmpdir(), "qjiao-qrls-"));
  const appcastPath = join(dir, "appcast.xml");
  writeFileSync(appcastPath, sampleAppcast);
  const signatures = readSparkleSignatures(appcastPath, "149");
  expect(signatures.zipSignature).toBe("zip-sig");
  expect(signatures.deltas).toEqual([
    {
      name: "Qjiao149-148.delta",
      edSignature: "delta-sig",
      deltaFromVersion: "148",
    },
  ]);
});

test("collectSparkleAttachments 把签名挂到 ZIP 和 delta 上", () => {
  const dir = mkdtempSync(join(tmpdir(), "qjiao-qrls-"));
  const zipPath = join(dir, "qjiao-1.1.49.zip");
  const notesPath = join(dir, "qjiao-1.1.49.md");
  const deltaPath = join(dir, "Qjiao149-148.delta");
  const appcastPath = join(dir, "appcast.xml");
  writeFileSync(zipPath, "zip");
  writeFileSync(notesPath, "notes");
  writeFileSync(deltaPath, "delta");
  writeFileSync(appcastPath, sampleAppcast);

  const files = collectSparkleAttachments(
    {
      dmgPath: join(dir, "missing.dmg"),
      zipPath,
      notesPath,
      appcastPath,
      deltaPaths: [deltaPath],
    },
    "149",
  );

  expect(files).toHaveLength(3);
  expect(files[0]).toMatchObject({
    name: "qjiao-1.1.49.zip",
    edSignature: "zip-sig",
  });
  expect(files[2]).toMatchObject({
    name: "Qjiao149-148.delta",
    edSignature: "delta-sig",
    deltaFromVersion: "148",
  });
});
