#!/usr/bin/env bash
# 从 libjxl 源码编译自包含的 cjxl / djxl / jxlinfo，安装到 kero/VendorBin。
#
# 目标：otool -L 仅依赖系统库（/usr/lib/*），不依赖 Homebrew 动态库。
#
# 用法：
#   bun run scripts/vendor-jxl.sh
#   ./scripts/vendor-jxl.sh
#   JPEGXL_TAG=v0.12.0 ./scripts/vendor-jxl.sh
#
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
DEST="${ROOT}/kero/VendorBin"
TAG="${JPEGXL_TAG:-v0.12.0}"
WORKDIR="${JPEGXL_BUILD_DIR:-${TMPDIR:-/tmp}/qjiao-libjxl-build}"
SRC="${WORKDIR}/libjxl"
BUILD="${SRC}/build-qjiao"

need() {
  command -v "$1" >/dev/null 2>&1 || {
    echo "error: missing required tool: $1" >&2
    exit 1
  }
}

need git
need cmake
need ninja
need clang++
need otool
need strip

echo "==> libjxl ${TAG} → ${DEST}"
mkdir -p "${WORKDIR}" "${DEST}"

if [[ -d "${SRC}/.git" ]]; then
  echo "==> reuse clone ${SRC}"
  git -C "${SRC}" fetch --depth 1 origin "refs/tags/${TAG}:refs/tags/${TAG}" 2>/dev/null || true
  git -C "${SRC}" checkout -f "tags/${TAG}" 2>/dev/null || git -C "${SRC}" checkout -f "${TAG}"
else
  echo "==> clone https://github.com/libjxl/libjxl @ ${TAG}"
  rm -rf "${SRC}"
  git clone --depth 1 --branch "${TAG}" --recursive --shallow-submodules \
    https://github.com/libjxl/libjxl.git "${SRC}"
fi

# 确保 submodule 齐全
git -C "${SRC}" submodule update --init --recursive --depth 1 --recommend-shallow

echo "==> cmake configure (JPEGXL_STATIC, no system GIF/JPEG/OpenEXR)"
rm -rf "${BUILD}"
mkdir -p "${BUILD}"
cmake -S "${SRC}" -B "${BUILD}" -G Ninja \
  -DCMAKE_BUILD_TYPE=Release \
  -DJPEGXL_STATIC=ON \
  -DBUILD_SHARED_LIBS=OFF \
  -DJPEGXL_ENABLE_TOOLS=ON \
  -DJPEGXL_ENABLE_DEVTOOLS=OFF \
  -DJPEGXL_ENABLE_BENCHMARK=OFF \
  -DJPEGXL_ENABLE_EXAMPLES=OFF \
  -DJPEGXL_ENABLE_JNI=OFF \
  -DJPEGXL_ENABLE_OPENEXR=OFF \
  -DJPEGXL_ENABLE_SJPEG=ON \
  -DJPEGXL_ENABLE_SKCMS=ON \
  -DJPEGXL_BUNDLE_LIBPNG=ON \
  -DJPEGXL_ENABLE_DOXYGEN=OFF \
  -DJPEGXL_ENABLE_MANPAGES=OFF \
  -DJPEGXL_ENABLE_VIEWERS=OFF \
  -DJPEGXL_ENABLE_PLUGINS=OFF \
  -DJPEGXL_ENABLE_FUZZERS=OFF \
  -DJPEGXL_FORCE_SYSTEM_BROTLI=OFF \
  -DJPEGXL_FORCE_SYSTEM_HWY=OFF \
  -DJPEGXL_FORCE_SYSTEM_LCMS2=OFF \
  -DJPEGXL_TEST_TOOLS=OFF \
  -DBUILD_TESTING=OFF \
  -DCMAKE_DISABLE_FIND_PACKAGE_GIF=ON \
  -DCMAKE_DISABLE_FIND_PACKAGE_JPEG=ON

echo "==> build cjxl djxl jxlinfo"
cmake --build "${BUILD}" -j "$(sysctl -n hw.ncpu 2>/dev/null || echo 4)" \
  --target cjxl djxl jxlinfo

install_tool() {
  local name="$1"
  local src="${BUILD}/tools/${name}"
  local dst="${DEST}/${name}"
  [[ -x "${src}" ]] || {
    echo "error: missing ${src}" >&2
    exit 1
  }
  cp -f "${src}" "${dst}"
  chmod 755 "${dst}"
  strip -x "${dst}" 2>/dev/null || true
  # ad-hoc 签名，避免 quarantine / 改 strip 后无法执行
  codesign --force -s - "${dst}" 2>/dev/null || true
  echo "    installed ${dst} ($(du -h "${dst}" | awk '{print $1}'))"
}

echo "==> install to VendorBin"
install_tool cjxl
install_tool djxl
install_tool jxlinfo

# 静态链接后不再需要 VendorBin/lib 中的 libjxl dylib
if [[ -d "${DEST}/lib" ]]; then
  rm -f "${DEST}/lib"/libjxl* 2>/dev/null || true
  rmdir "${DEST}/lib" 2>/dev/null || true
fi

echo "==> dependency check (must not contain /opt/homebrew)"
bad=0
for t in cjxl djxl jxlinfo; do
  echo "--- ${t} ---"
  otool -L "${DEST}/${t}"
  if otool -L "${DEST}/${t}" | grep -q '/opt/homebrew\|@rpath'; then
    echo "error: ${t} still links non-system dylibs" >&2
    bad=1
  fi
done
[[ "${bad}" -eq 0 ]] || exit 1

echo "==> smoke encode"
tmp="$(mktemp -d)"
trap 'rm -rf "${tmp}"' EXIT
# 任意小 PNG；优先项目 icon
png="${ROOT}/icon/icon-128.png"
if [[ ! -f "${png}" ]]; then
  # 无 icon 时用 sips 造一张
  png="${tmp}/t.png"
  # 1x1 png via printf base64
  printf '%s' 'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8z8BQDwAEhQGAhKmMIQAAAABJRU5ErkJggg==' \
    | base64 -d >"${png}"
fi
"${DEST}/cjxl" "${png}" "${tmp}/out.jxl" --quality=90 --effort=5
"${DEST}/jxlinfo" "${tmp}/out.jxl" >/dev/null
echo "==> done. tag=${TAG} → kero/VendorBin/{cjxl,djxl,jxlinfo}"
