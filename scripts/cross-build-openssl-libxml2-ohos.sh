#!/usr/bin/env bash
# =============================================================================
# cross-build-openssl-libxml2-ohos.sh
# 在 Windows + msys(git-bash) 环境下，用鸿蒙(OpenHarmony) NDK 交叉编译
#   OpenSSL 3.0.13 与 libxml2 2.12.9 静态库，目标 aarch64-linux-ohos (arm64-v8a)。
#
# 环境要求：
#   * DevEco Studio 内置完整 NDK：sdk/default/openharmony/native
#     （其中 sysroot 含标准 musl libc 头文件）
#   * 已为 NDK 建立无空格 junction 别名 C:\OHROOT（避免 clang 路径含空格
#     导致 OpenSSL 汇编规则在 msys sh 下被拆分）
#   * git 自带 msys(bash/perl、make、ar 等)，make 可用
#   * Python 3 + zstandard（解压 .pkg.tar.zst 的 MSYS perl），或已有可用 perl
#
# 产物：copy 到 ohos-openconnect/entry/src/main/cpp/third_party/ 下
#   aarch64-linux-ohos/{libssl.a,libcrypto.a,libxml2.a}
#   include/openssl/*.h, include/libxml/*.h
# =============================================================================
set -euo pipefail

# ---------- 关键路径（按需修改） ----------
NDK="C:/OHROOT"                                   # 无空格 junction 指向 native/
SYSROOT="$NDK/sysroot"
LLVM="$NDK/llvm"
CLANG="$LLVM/bin/clang.exe"
ARR="llvm-ar.exe"
RAN="llvm-ranlib.exe"
NM="llvm-nm.exe"
OBJDUMP="$LLVM/bin/llvm-objdump.exe"

MAKE="make"                                       # GnuWin32 或 msys 的 make
TARGET="aarch64-linux-ohos"
TRIAL="aarch64-linux-gnu"                         # config.sub 不认识 ohos，用 gnu 蒙混

WORK="$HOME/oc-dep-build"
THIRD="$(cd "$(dirname "$0")/../entry/src/main/cpp/third_party" && pwd)"
ABI="$THIRD/aarch64-linux-ohos"

# ---------- 编译器/工具变量 ----------
export PATH="$LLVM/bin:/usr/bin:/bin:$PATH"
export PERL="perl"

mkcc() { echo "$CLANG --target=$TARGET --sysroot=$SYSROOT -D__MUSL__"; }

# ---------- OpenSSL ----------
build_openssl() {
  local ver="3.0.13" out="$WORK/openssl-$ver"
  echo "==> OpenSSL $ver"
  mkdir -p "$WORK"; cd "$WORK"
  [ -f "openssl-$ver.tar.gz" ] || curl -fsSL -o "openssl-$ver.tar.gz" \
      "https://www.openssl.org/source/openssl-$ver.tar.gz"
  rm -rf "$out"; tar xzf "openssl-$ver.tar.gz"
  cd "$out"
  ./Configure linux-aarch64 --prefix="$WORK/openresult" no-shared no-tests "$@" \
      CC="$(mkcc)" AR="$ARR" RANLIB="$RAN"
  "$MAKE" build_libs \
      CC="$(mkcc)" AR="$ARR" RANLIB="$RAN" PERL="perl"
  cp libssl.a libcrypto.a "$ABI/"
  mkdir -p "$THIRD/include/openssl"
  cp include/openssl/*.h "$THIRD/include/openssl/"
  echo "   -> $ABI/libssl.a, libcrypto.a ; include/openssl/*.h"
}

# ---------- libxml2 ----------
build_libxml2() {
  local ver="2.12.9" out="$WORK/libxml2-$ver"
  echo "==> libxml2 $ver"
  mkdir -p "$WORK"; cd "$WORK"
  [ -f "libxml2-$ver.tar.xz" ] || python -c "import urllib.request,os; urllib.request.urlretrieve('https://download.gnome.org/sources/libxml2/2.12/libxml2-$ver.tar.xz','libxml2-$ver.tar.xz')"
  rm -rf "$out"; tar xJf "libxml2-$ver.tar.xz"
  cd "$out"
  ./configure --host="$TRIAL" --build=x86_64-pc-linux-gnu \
      --prefix="$WORK/xmlresult" --disable-shared --enable-static \
      --without-iconv --without-zlib --without-lzma --without-python \
      --without-http --without-ftp --without-threads \
      CC="$(mkcc)" LD="$(mkcc)" AR="$ARR" RANLIB="$RAN" NM="$NM"
  "$MAKE" -j4 CC="$(mkcc)" LD="$(mkcc)" AR="$ARR" RANLIB="$RAN"
  cp .libs/libxml2.a "$ABI/"
  mkdir -p "$THIRD/include/libxml"
  cp include/libxml/*.h "$THIRD/include/libxml/"
  echo "   -> $ABI/libxml2.a ; include/libxml/*.h"
}

# ---------- 验证 ----------
verify() {
  echo "==> 架构验证"
  "$OBJDUMP" -f "$ABI/libssl.a"    | sed -n '2p'
  "$OBJDUMP" -f "$ABI/libcrypto.a" | sed -n '2p'
  "$OBJDUMP" -f "$ABI/libxml2.a"   | sed -n '2p'
}

mkdir -p "$ABI"
build_openssl
build_libxml2
verify
echo "DONE: all libs in $ABI"
