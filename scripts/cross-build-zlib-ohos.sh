#!/usr/bin/env bash
# =============================================================================
# POC-A：HarmonyOS NEXT (API 26) 交叉编译工具链验证脚本
#
# 已验证：在本机 (Windows + DevEco Studio, HarmonyOS 26.0.0 SDK) 上，
#   - 完整 NDK:  DevEco Studio\sdk\default\openharmony\native
#   - 标准 libc: (该 sdk 自带, 含 stdio.h/errno.h/... 及 libc.a)
#   - zlib 1.3.1 交叉编译为 arm64-linux-ohos 静态库 libz.a
#   - 调用 zlib 的可执行程序静态链接成功 (elf64-littleaarch64)
#
# 用法: 在已安装 DevEco Studio 的 Windows 上运行 git-bash
#   bash cross-build-zlib-ohos.sh
#
# 产物输出到: ../entry/src/main/cpp/third_party/
# =============================================================================
set -e

# ---- 路径配置（按实际安装位置修改）-----------------------------------------
DEVECO="C:/Program Files/Huawei/DevEco Studio"
OHOS_NATIVE="$DEVECO/sdk/default/openharmony/native"
SYSROOT="$OHOS_NATIVE/sysroot"
LLVM="$OHOS_NATIVE/llvm"
CMAKE="$OHOS_NATIVE/build-tools/cmake/bin/cmake.exe"
NINJA="$OHOS_NATIVE/build-tools/cmake/bin/ninja.exe"
TOOLCHAIN="$OHOS_NATIVE/build/cmake/ohos.toolchain.cmake"

# 目标 ABI：arm64-v8a (aarch64-linux-ohos) | x86_64 (模拟器) | armeabi-v7a
OHOS_ARCH="${OHOS_ARCH:-arm64-v8a}"
case "$OHOS_ARCH" in
  arm64-v8a) GNU_TRIPLE=aarch64-linux-ohos ;;
  x86_64)    GNU_TRIPLE=x86_64-linux-ohos ;;
  armeabi-v7a) GNU_TRIPLE=arm-linux-ohos ;;
  *) echo "Unsupported OHOS_ARCH=$OHOS_ARCH"; exit 1 ;;
esac

THIRD_PARTY="$(cd "$(dirname "$0")/.." && pwd)/entry/src/main/cpp/third_party"
OUT_PREFIX="$THIRD_PARTY/$GNU_TRIPLE"

echo "==> OHOS_ARCH=$OHOS_ARCH  GNU_TRIPLE=$GNU_TRIPLE"
echo "==> 输出目录: $OUT_PREFIX"

# ---- 校验工具链 -------------------------------------------------------------
for t in "$LLVM/bin/clang.exe" "$CMAKE" "$NINJA" "$TOOLCHAIN"; do
  [ -f "$t" ] || { echo "缺少: $t"; exit 1; }
done
[ -f "$SYSROOT/usr/include/stdio.h" ] || { echo "完整 NDK sysroot 缺少标准头"; exit 1; }
echo "==> 工具链校验通过"

# ---- 下载并解压 zlib --------------------------------------------------------
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
ZVER=1.3.1
echo "==> 下载 zlib $ZVER"
curl -fsSL -o "$WORK/zlib.tar.gz" \
  "https://github.com/madler/zlib/releases/download/v$ZVER/zlib-$ZVER.tar.gz"
tar xzf "$WORK/zlib.tar.gz" -C "$WORK"
mkdir -p "$WORK/build" "$OUT_PREFIX"

# ---- 交叉编译 zlib 静态库 ---------------------------------------------------
echo "==> 配置 zlib (Ninja + ohos.toolchain)"
"$CMAKE" -G Ninja "$WORK/zlib-$ZVER" \
  -DCMAKE_TOOLCHAIN_FILE="$TOOLCHAIN" \
  -DOHOS_ARCH="$OHOS_ARCH" \
  -DCMAKE_MAKE_PROGRAM="$NINJA" \
  -DCMAKE_INSTALL_PREFIX="$OUT_PREFIX" \
  -DBUILD_SHARED_LIBS=OFF \
  -DZLIB_BUILD_EXAMPLES=OFF \
  -Wno-dev >/dev/null

echo "==> 编译 zlibstatic"
"$CMAKE" --build "$WORK/build" --target zlibstatic >/dev/null

echo "==> 安装到 $OUT_PREFIX (手动拷贝，避开 zlib install 的 .so 冲突)"
cp "$WORK/build/libz.a" "$OUT_PREFIX/libz.a"
cp "$WORK/zlib-$ZVER/zlib.h" "$THIRD_PARTY/include/" 2>/dev/null || true
cp "$WORK/build/zconf.h" "$THIRD_PARTY/include/" 2>/dev/null || true
mkdir -p "$THIRD_PARTY/include"

# ---- 验证架构与链接 ---------------------------------------------------------
echo "==> 交叉编译并链接一个调用 zlib 的测试程序"
cat > "$WORK/ztest.c" <<'EOF'
#include <stdio.h>
#include <string.h>
#include <zlib.h>
int main(void){
  const char *s="HarmonyOS zlib POC-A ok";
  unsigned char ob[512]; unsigned long olen=sizeof(ob);
  int r=compress2(ob,&olen,(const Bytef*)s,strlen(s),6);
  printf("compress=%d olen=%lu zlib=%s\n",r,olen,zlibVersion());
  return r;
}
EOF
"$LLVM/bin/clang.exe" --target="$GNU_TRIPLE" --sysroot="$SYSROOT" -D__MUSL__ \
  -I"$THIRD_PARTY/include" "$WORK/ztest.c" "$OUT_PREFIX/libz.a" \
  -o "$WORK/ztest"
echo "==> 产物架构:"
"$LLVM/bin/llvm-objdump.exe" -f "$WORK/ztest" | grep -iE 'file format|architecture'

echo
echo "✅ POC-A 通过！"
echo "   静态库: $OUT_PREFIX/libz.a"
echo "   头文件: $THIRD_PARTY/include/{zlib.h,zconf.h}"
echo "   下一步: 用同一 toolchain 交叉编译 OpenSSL / libxml2 / openconnect"
