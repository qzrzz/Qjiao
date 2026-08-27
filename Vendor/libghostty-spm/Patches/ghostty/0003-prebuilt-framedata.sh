#!/bin/zsh

set -euo pipefail

SOURCE_DIR=${1:-}

if [ -z "$SOURCE_DIR" ]; then
    echo "[-] missing source_dir"
    exit 1
fi

FRAME_ZIG="$SOURCE_DIR/src/build/GhosttyFrameData.zig"
FRAME_DST="$SOURCE_DIR/src/build/framegen/framedata.compressed"
FRAME_SRC="$(cd "$(dirname "$0")" && pwd)/assets/framedata.compressed"
MARKER="LIBGHOSTTY_SPM_PREBUILT_FRAMEDATA"

if [ ! -f "$FRAME_ZIG" ]; then
    echo "[-] GhosttyFrameData.zig not found: $FRAME_ZIG"
    exit 1
fi

if [ ! -f "$FRAME_SRC" ]; then
    echo "[-] prebuilt framedata not found: $FRAME_SRC"
    exit 1
fi

mkdir -p "$(dirname "$FRAME_DST")"
if [ ! -f "$FRAME_DST" ] || ! cmp -s "$FRAME_SRC" "$FRAME_DST"; then
    cp "$FRAME_SRC" "$FRAME_DST"
fi

if grep -Fq "$MARKER" "$FRAME_ZIG"; then
    echo "[+] patch already applied: 0003-prebuilt-framedata"
    exit 0
fi

python3 - "$FRAME_ZIG" "$MARKER" <<'PY'
import pathlib
import sys

path = pathlib.Path(sys.argv[1])
marker = sys.argv[2]
text = path.read_text()

old_copy = '_ = wf.addCopyFile(dist.framedata.path(b), "framedata.compressed");'
new_copy = f'_ = wf.addCopyFile(dist.framedata.generated, "framedata.compressed"); // {marker}'
if old_copy not in text:
    if new_copy not in text and "dist.framedata.generated" not in text:
        raise SystemExit("framedata copy site not found")
else:
    text = text.replace(old_copy, new_copy, 1)

start = text.find("    const exe = b.addExecutable(.{\n        .name = \"framegen\",")
if start == -1:
    if marker in text:
        path.write_text(text)
        raise SystemExit(0)
    raise SystemExit("framegen executable block not found")

end = text.find("    return .{", start)
if end == -1:
    raise SystemExit("framegen return site not found")

replacement = f"""    // {marker}: skip the C framegen tool and use the shipped compressed file.
    return {{
"""
text = text[:start] + replacement + text[end + len("    return {"):]
text = text.replace(
    ".generated = compressed_file,",
    ".generated = b.path(\"src/build/framegen/framedata.compressed\"),",
    1,
)
path.write_text(text)
PY

if ! grep -Fq "$MARKER" "$FRAME_ZIG"; then
    echo "[-] failed to apply patch: 0003-prebuilt-framedata"
    exit 1
fi

echo "[+] applied patch: 0003-prebuilt-framedata"
