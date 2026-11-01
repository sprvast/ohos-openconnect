# third_party 第三方库目录

本目录用于放置为 `aarch64-linux-ohos` 交叉编译好的静态库，供 `CMakeLists.txt` 链接。

## 目录结构约定

```
third_party/
├── aarch64-linux-ohos/          # arm64-ohos 静态库
│   ├── libz.a      ✅ zlib 1.3.1（POC-A 已交叉编译）
│   ├── libssl.a / libcrypto.a   ✅ OpenSSL 3.0.13（aarch64）
│   ├── libxml2.a                ✅ libxml2 2.12.9（aarch64）
│   └── libopenconnect.a         # openconnect 本体（先应用 patches/0001-ohos-adaptation.patch）
└── include/                     # 各库的公开头文件
    ├── openssl/                 ✅ OpenSSL 3.0.13 头（135 个）
    ├── libxml/                  ✅ libxml2 2.12.9 头（46 个）
    ├── zlib.h / zconf.h         ✅ zlib 1.3.1 头
    └── openconnect.h            # openconnect 本体头（移植时复制）
```

> ✅ **工具链验证 (POC-A + 扩展)**：已用鸿蒙 NDK
> (`sdk/default/openharmony/native`，HarmonyOS 26 / API 26) 交叉编译出
> **zlib 1.3.1、OpenSSL 3.0.13、libxml2 2.12.9** 三个 arm64 静态库，
> 并最终用三条静态库联合链接出测试程序（`elf64-littleaarch64` / aarch64），
> 整条 `clang --target=aarch64-linux-ohos --sysroot=... -D__MUSL__` 依赖链已打通。

## 交叉编译要点

本仓库提供可复现脚本：

- `scripts/cross-build-zlib-ohos.sh`            —— 交叉编译 zlib
- `scripts/cross-build-openssl-libxml2-ohos.sh` —— 交叉编译 OpenSSL + libxml2

### 关键经验（Windows + msys 环境）

1. **JDK/NDK 路径不要含空格**：`C:\Program Files\...` 中的空格会导致 OpenSSL
   的 `.pl → .S` 汇编规则在 msys sh 下被拆分而失败。解决：为 NDK 建无空格 junction：
   ```powershell
   New-Item -ItemType Junction -Path "C:\OHROOT" -Target "C:\Program Files\Huawei\DevEco Studio\sdk\default\openharmony\native"
   ```
   然后 sysroot 用 `C:/OHROOT/sysroot`，clang 用 `C:/OHROOT/llvm/bin/clang.exe`。

2. **OpenSSL 需要 perl**：本机 git-bash 的 perl 是残缺 stub。可在 MSYS2 仓库下载完整 perl 包
   （`perl-5.42.2-1-x86_64.pkg.tar.zst`，含 `msys-perl5_42.dll`），解压进 git-bash 的 `usr/` 即可。
   执行 perl 前确保 PATH 含 git 的 `usr/bin`、`bin`。

3. **OpenSSL 交叉编译命令**：
   ```bash
   ./Configure linux-aarch64 --prefix=$PREFIX no-shared no-tests \
        CC="$CLANG --target=aarch64-linux-ohos --sysroot=$SYSROOT -D__MUSL__" \
        AR=llvm-ar  RANLIB=llvm-ranlib
   make build_libs CC="$CLANG --target=aarch64-linux-ohos --sysroot=$SYSROOT -D__MUSL__" ...
   ```

4. **libxml2**：`config.sub` 不识别 `ohos`，需用 `--host=aarch64-linux-gnu`
   （让 autotools 通过），再用 CC/LD 显式指定 `--target=aarch64-linux-ohos`：
   ```bash
   ./configure --host=aarch64-linux-gnu --build=x86_64-pc-linux-gnu \
       --disable-shared --enable-static --without-iconv --without-zlib \
       --without-lzma --without-python --without-http --without-ftp --without-threads \
       CC="$CLANG --target=aarch64-linux-ohos --sysroot=$SYSROOT -D__MUSL__" LD=... AR=llvm-ar RANLIB=llvm-ranlib
   ```
   同时必须设 `LD="$CLANG --target=aarch64-linux-ohos --sysroot=$SYSROOT"`（否则报 no acceptable ld）。

5. **make**：本机 git-bash 无 make。可用 `winget install ezwinports.make` 安装独立 GNU make。

`CMakeLists.txt` 通过 `${OHOS_ARCH}`（hvigor 注入，值为 `aarch64-linux-ohos` 等）定位 `<abi>` 子目录，
现三依赖均已就位，只差交叉编译 openconnect 本体（见 BUILD.md）后放 `libopenconnect.a`。
