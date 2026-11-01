# 设置最低 CMake 版本
cmake_minimum_required(VERSION 3.5.0)

project(openconnect_bridge)

# 设置 C/C++ 标准
set(CMAKE_C_STANDARD 11)
set(CMAKE_CXX_STANDARD 17)
set(CMAKE_CXX_STANDARD_REQUIRED ON)

# 打开编译器警告
set(CMAKE_C_FLAGS "${CMAKE_C_FLAGS} -Wall -Wno-unused-function")
set(CMAKE_CXX_FLAGS "${CMAKE_CXX_FLAGS} -Wall -Wno-unused-function")

# 需要 C++ 运行时支持（NAPI 环境已带 libc++）
set(CMAKE_SHARED_LINKER_FLAGS "${CMAKE_SHARED_LINKER_FLAGS}")

# ---------------------------------------------------------------------------
# libopenconnect 静态库（及其第三方依赖）
# 期望路径：entry/src/main/cpp/third_party/<abi>/lib*.a
# 请按照《移植方案》第 5 节脚本预先交叉编译 OpenSSL/zlib/lz4/libxml2/openconnect，
# 并把生成物放到对应 <abi> 目录下。
# ---------------------------------------------------------------------------
set(OC_THIRD_PARTY_DIR "${CMAKE_CURRENT_SOURCE_DIR}/third_party")

# arm64-v8a (aarch64) 交叉编译产物目录：third_party/aarch64-linux-ohos/
set(OC_ABI_DIR "aarch64-linux-ohos")

add_library(openconnect STATIC IMPORTED)
set_target_properties(openconnect PROPERTIES
    IMPORTED_LOCATION "${OC_THIRD_PARTY_DIR}/${OC_ABI_DIR}/libopenconnect.a")

add_library(ssl STATIC IMPORTED)
set_target_properties(ssl PROPERTIES
    IMPORTED_LOCATION "${OC_THIRD_PARTY_DIR}/${OC_ABI_DIR}/libssl.a")

add_library(crypto STATIC IMPORTED)
set_target_properties(crypto PROPERTIES
    IMPORTED_LOCATION "${OC_THIRD_PARTY_DIR}/${OC_ABI_DIR}/libcrypto.a")

add_library(z STATIC IMPORTED)
set_target_properties(z PROPERTIES
    IMPORTED_LOCATION "${OC_THIRD_PARTY_DIR}/${OC_ABI_DIR}/libz.a")

add_library(xml2 STATIC IMPORTED)
set_target_properties(xml2 PROPERTIES
    IMPORTED_LOCATION "${OC_THIRD_PARTY_DIR}/${OC_ABI_DIR}/libxml2.a")

# ---------------------------------------------------------------------------
# 本模块源码
# ---------------------------------------------------------------------------
add_library(openconnect_bridge SHARED
    napi_init.cpp
    openconnect_bridge.cpp
)

# 依赖 openconnect 及其第三方静态库
target_link_libraries(openconnect_bridge
    PUBLIC
    openconnect
    ssl
    crypto
    z
    xml2
    hilog_ndk.z
    ace_napi.z
    c++
)

# 头文件搜索路径（include 目录由构建时通过 CMAKE_INCLUDE_PATH 提供）
target_include_directories(openconnect_bridge PUBLIC
    ${OC_THIRD_PARTY_DIR}/include
)

# NAPI 模块加载入口
set_target_properties(openconnect_bridge PROPERTIES
    OUTPUT_NAME "openconnect"
)
