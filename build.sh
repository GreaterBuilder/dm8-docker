#!/usr/bin/env bash
###############################################################################
# 达梦 DM8 ARM64 镜像一键构建（在 aarch64 Linux 上执行）
#
#   bash build.sh                                        # 自动用当前目录的 dm8_*.zip
#   bash build.sh dm8_20260708_HWarm920_kylin10_sp1_64.zip
#   bash build.sh /path/xxx.iso                          # 直接给 ISO 也行
#   SKIP_EXTRACT=1 bash build.sh                         # 已放好 DMInstall.bin，只构建
#
# 可覆盖的环境变量：
#   IMAGE_NAME=dm8  IMAGE_TAG=arm64
#   BASE_IMAGE=almalinux:8  DM_ARCH=aarch64  SLIM=1  TRIM=1  FAKE_KYLIN=1
#   DM_INSTALL_DIR=/opt/dmdbms  DM_DATA_DIR=/opt/dmdbms/data
#   KEEP_BUILD_DIR=1    保留 .dm-build 解包目录
###############################################################################
set -euo pipefail

SCRIPT_DIR=$(cd "$(dirname "$0")" && pwd)
cd "$SCRIPT_DIR"

IMAGE_NAME=${IMAGE_NAME:-dm8}
IMAGE_TAG=${IMAGE_TAG:-arm64}
BASE_IMAGE=${BASE_IMAGE:-almalinux:8}
DM_ARCH=${DM_ARCH:-aarch64}
SLIM=${SLIM:-1}
TRIM=${TRIM:-1}
FAKE_KYLIN=${FAKE_KYLIN:-1}
DM_INSTALL_DIR=${DM_INSTALL_DIR:-/opt/dmdbms}
DM_DATA_DIR=${DM_DATA_DIR:-/opt/dmdbms/data}
KEEP_BUILD_DIR=${KEEP_BUILD_DIR:-0}
SKIP_EXTRACT=${SKIP_EXTRACT:-0}

BUILD_DIR="$SCRIPT_DIR/.dm-build"
BIN_NAME="DMInstall.bin"
PKG_PATH="${1:-}"

info() { echo "==> $*"; }
die()  { echo "ERROR: $*" >&2; exit 1; }
need_cmd() { command -v "$1" >/dev/null 2>&1; }

# ---------------------------------------------------------------- 选安装包
pick_package() {
  if [ -n "$PKG_PATH" ]; then
    [ -f "$PKG_PATH" ] || die "找不到安装包: $PKG_PATH"
    PKG_PATH=$(cd "$(dirname "$PKG_PATH")" && pwd)/$(basename "$PKG_PATH")
    return
  fi
  shopt -s nullglob
  local pkgs=( *.zip *.ZIP *.iso *.ISO )
  shopt -u nullglob
  [ ${#pkgs[@]} -gt 0 ] || die "当前目录没有 zip/iso 安装包，请把 dm8_20260708_HWarm920_kylin10_sp1_64.zip 放进来，或用第一个参数指定"
  PKG_PATH="$SCRIPT_DIR/${pkgs[0]}"
}

# ---------------------------------------------------------------- 解压
unzip_pkg() {  # $1=zip $2=dest
  local zip="$1" dest="$2"
  rm -rf "$dest"; mkdir -p "$dest"
  if need_cmd unzip; then
    unzip -o -q "$zip" -d "$dest"
  elif need_cmd 7z; then
    7z x -y -o"$dest" "$zip" >/dev/null
  elif need_cmd bsdtar; then
    bsdtar -xf "$zip" -C "$dest"
  elif need_cmd python3; then
    python3 - "$zip" "$dest" <<'PY'
import sys, zipfile
zipfile.ZipFile(sys.argv[1]).extractall(sys.argv[2])
PY
  else
    die "没有可用的解压工具，请安装 unzip 或 p7zip"
  fi
}

extract_iso() {  # $1=iso $2=dest
  local iso="$1" dest="$2"
  mkdir -p "$dest"
  if need_cmd 7z; then
    7z x -y -o"$dest" "$iso" >/dev/null
  elif need_cmd 7zz; then
    7zz x -y -o"$dest" "$iso" >/dev/null
  elif need_cmd bsdtar; then
    bsdtar -xf "$iso" -C "$dest"
  else
    local mnt="$dest.mnt" sudo_cmd=""
    mkdir -p "$mnt"
    if [ "$(id -u)" -ne 0 ]; then
      need_cmd sudo || die "解压 ISO 需要 7z/bsdtar，或 root 权限"
      sudo_cmd="sudo"
    fi
    info "回环挂载 ISO 提取"
    $sudo_cmd mount -o loop,ro "$iso" "$mnt"
    cp -a "$mnt/." "$dest/"
    $sudo_cmd umount "$mnt"
    rmdir "$mnt" 2>/dev/null || true
  fi
}

# ---------------------------------------------------------------- 找 DMInstall.bin
prepare_installer() {  # $1=package
  local pkg="$1" bin="" iso=""
  rm -rf "$BUILD_DIR"; mkdir -p "$BUILD_DIR"

  case "$pkg" in
    *.iso|*.ISO) info "解压 ISO: $(basename "$pkg")"; extract_iso "$pkg" "$BUILD_DIR/iso" ;;
    *)           info "解压安装包: $(basename "$pkg")"; unzip_pkg "$pkg" "$BUILD_DIR/zip" ;;
  esac

  bin=$(find "$BUILD_DIR" -maxdepth 6 -name "$BIN_NAME" -type f -print -quit 2>/dev/null || true)

  if [ -z "$bin" ]; then
    iso=$(find "$BUILD_DIR" -maxdepth 6 -iname '*.iso' -type f -print -quit 2>/dev/null || true)
    [ -n "$iso" ] || die "安装包里既没有 $BIN_NAME，也没有 .iso，请确认下载的是完整包"
    info "从 ISO 提取: $(basename "$iso")"
    extract_iso "$iso" "$BUILD_DIR/iso"
    bin=$(find "$BUILD_DIR/iso" -maxdepth 6 -name "$BIN_NAME" -type f -print -quit 2>/dev/null || true)
  fi

  [ -n "$bin" ] || die "ISO/zip 中未找到 $BIN_NAME"
  cp -f "$bin" "$SCRIPT_DIR/$BIN_NAME"
  chmod +x "$SCRIPT_DIR/$BIN_NAME"
  info "安装文件就绪: $SCRIPT_DIR/$BIN_NAME ($(du -h "$SCRIPT_DIR/$BIN_NAME" | cut -f1))"
}

# ---------------------------------------------------------------- 构建
build_image() {
  info "构建 ${IMAGE_NAME}:${IMAGE_TAG}  主机架构=$(uname -m)"
  info "  BASE_IMAGE=${BASE_IMAGE}  DM_ARCH=${DM_ARCH}  SLIM=${SLIM}  TRIM=${TRIM}"

  docker build \
    --build-arg "BASE_IMAGE=${BASE_IMAGE}" \
    --build-arg "DM_ARCH=${DM_ARCH}" \
    --build-arg "DM_INSTALL_DIR=${DM_INSTALL_DIR}" \
    --build-arg "DM_DATA_DIR=${DM_DATA_DIR}" \
    --build-arg "FAKE_KYLIN=${FAKE_KYLIN}" \
    --build-arg "SLIM=${SLIM}" \
    --build-arg "TRIM=${TRIM}" \
    -t "${IMAGE_NAME}:${IMAGE_TAG}" \
    -f "$SCRIPT_DIR/Dockerfile" \
    "$SCRIPT_DIR"
}

# ---------------------------------------------------------------- main
need_cmd docker || die "未找到 docker 命令"

if [ "$SKIP_EXTRACT" = "1" ]; then
  [ -f "$SCRIPT_DIR/$BIN_NAME" ] || die "SKIP_EXTRACT=1 但目录下没有 $BIN_NAME"
  info "跳过解包，使用已有 $BIN_NAME"
elif [ -z "$PKG_PATH" ] && [ -f "$SCRIPT_DIR/$BIN_NAME" ]; then
  info "已存在 $BIN_NAME，跳过解包（要重新解包请先删除它）"
else
  pick_package
  prepare_installer "$PKG_PATH"
fi

build_image

docker image inspect "${IMAGE_NAME}:${IMAGE_TAG}" \
  --format '==> 完成: {{.RepoTags}}  arch={{.Architecture}}  size={{.Size}}' || true

[ "$KEEP_BUILD_DIR" = "1" ] || rm -rf "$BUILD_DIR"

cat <<EOF

运行（首次启动会自动建库）：
  docker run -d --name dm8 -p 5236:5236 \\
      -v dm8data:/opt/dmdbms/data \\
      -v dm8log:/opt/dmdbms/log \\
      -e SYSDBA_PWD='ChangeMe_123' -e SYSAUDITOR_PWD='ChangeMe_123' \\
      -e UNICODE_FLAG=1 -e PAGE_SIZE=16 -e EXTENT_SIZE=16 \\
      ${IMAGE_NAME}:${IMAGE_TAG}

验证：
  docker logs -f dm8
  docker exec -it dm8 /opt/dmdbms/bin/disql SYSDBA/ChangeMe_123
EOF
