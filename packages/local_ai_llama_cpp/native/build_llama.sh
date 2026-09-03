#!/usr/bin/env bash
#
# Builds the llama.cpp shared library this adapter loads at runtime.
#
#   ./build_llama.sh <linux|macos|ios|android> [options]
#
#   --ref <git-ref>       llama.cpp revision to build (default: $LLAMA_CPP_REF)
#   --backend <name>      cpu | vulkan | opencl | metal | cuda   (default: auto)
#   --out <dir>           output directory (default: build/<platform>)
#   --abis "a b"          Android ABIs (default: "arm64-v8a x86_64")
#
# Output: libmtmd.<so|dylib> plus the libllama/libggml* libraries it links
# against, copied into the output directory. `mtmd` is llama.cpp's
# multimodal tool library; it re-exports the whole llama API, and its name
# is what `LlamaCppRuntime.defaultLibraryName` expects — build it even
# though this adapter does not use vision yet, or override the name with
# `LlamaCppRuntime.useLibrary(...)`.
#
# See README.md in this directory for where each platform's build expects
# the result to be placed.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SOURCE_DIR="${SCRIPT_DIR}/llama.cpp"

# Pin this to the llama.cpp revision the installed llama_cpp_dart's bindings
# were generated against; a much newer revision can change the C API those
# bindings call. `master` is the "I know what I'm doing" default.
LLAMA_CPP_REF="${LLAMA_CPP_REF:-master}"
LLAMA_CPP_REPO="${LLAMA_CPP_REPO:-https://github.com/ggml-org/llama.cpp.git}"

PLATFORM="${1:-}"
shift || true
BACKEND="auto"
OUT_DIR=""
ANDROID_ABIS="arm64-v8a x86_64"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --ref) LLAMA_CPP_REF="$2"; shift 2 ;;
    --backend) BACKEND="$2"; shift 2 ;;
    --out) OUT_DIR="$2"; shift 2 ;;
    --abis) ANDROID_ABIS="$2"; shift 2 ;;
    *) echo "unknown option: $1" >&2; exit 64 ;;
  esac
done

case "${PLATFORM}" in
  linux|macos|ios|android) ;;
  *) echo "usage: $0 <linux|macos|ios|android> [options]" >&2; exit 64 ;;
esac

OUT_DIR="${OUT_DIR:-${SCRIPT_DIR}/build/${PLATFORM}}"

if [[ "${BACKEND}" == "auto" ]]; then
  case "${PLATFORM}" in
    macos|ios) BACKEND="metal" ;;
    android)   BACKEND="vulkan" ;;   # OpenCL is the alternative on Adreno
    linux)     BACKEND="vulkan" ;;
  esac
fi

# --- source -----------------------------------------------------------------

if [[ ! -d "${SOURCE_DIR}/.git" ]]; then
  echo "==> cloning llama.cpp into ${SOURCE_DIR}"
  git clone --recursive "${LLAMA_CPP_REPO}" "${SOURCE_DIR}"
fi
echo "==> checking out ${LLAMA_CPP_REF}"
git -C "${SOURCE_DIR}" fetch --tags origin
git -C "${SOURCE_DIR}" checkout --detach "${LLAMA_CPP_REF}"
git -C "${SOURCE_DIR}" submodule update --init --recursive

# Shared flags: no CLI tools, no tests, no curl dependency — just the
# libraries, plus mtmd (LLAMA_BUILD_TOOLS) for the library name above.
COMMON_FLAGS=(
  -DBUILD_SHARED_LIBS=ON
  -DLLAMA_BUILD_TESTS=OFF
  -DLLAMA_BUILD_EXAMPLES=OFF
  -DLLAMA_BUILD_SERVER=OFF
  -DLLAMA_BUILD_TOOLS=ON
  -DLLAMA_CURL=OFF
  -DGGML_NATIVE=OFF
  -DCMAKE_BUILD_TYPE=Release
)

backend_flags() {
  case "$1" in
    cpu)    echo "" ;;
    metal)  echo "-DGGML_METAL=ON -DGGML_METAL_EMBED_LIBRARY=ON" ;;
    vulkan) echo "-DGGML_VULKAN=ON" ;;
    opencl) echo "-DGGML_OPENCL=ON -DGGML_OPENCL_EMBED_KERNELS=ON" ;;
    cuda)   echo "-DGGML_CUDA=ON" ;;
    *) echo "unknown backend: $1" >&2; exit 64 ;;
  esac
}

collect() {
  local build_dir="$1" dest="$2"
  mkdir -p "${dest}"
  find "${build_dir}" -name 'libmtmd.*' -o -name 'libllama.*' \
       -o -name 'libggml*.so' -o -name 'libggml*.dylib' \
    | while read -r artifact; do cp -f "${artifact}" "${dest}/"; done
  echo "==> artifacts in ${dest}:"
  ls -1 "${dest}"
}

# --- per-platform builds ----------------------------------------------------

case "${PLATFORM}" in
  linux|macos)
    BUILD_DIR="${SCRIPT_DIR}/build/cmake-${PLATFORM}"
    # shellcheck disable=SC2046
    cmake -S "${SOURCE_DIR}" -B "${BUILD_DIR}" \
      "${COMMON_FLAGS[@]}" $(backend_flags "${BACKEND}")
    cmake --build "${BUILD_DIR}" --config Release -j "$(getconf _NPROCESSORS_ONLN)"
    collect "${BUILD_DIR}" "${OUT_DIR}"
    ;;

  ios)
    # llama.cpp ships its own xcframework build; it produces the static
    # framework an iOS app links (a dynamic library inside an app bundle
    # needs code-signing work a static link avoids), which is why
    # `LlamaCppRuntime.defaultLibraryName` resolves symbols from the
    # process on iOS instead of opening a library by name.
    if [[ ! -x "${SOURCE_DIR}/build-xcframework.sh" ]]; then
      echo "llama.cpp revision ${LLAMA_CPP_REF} has no build-xcframework.sh" >&2
      exit 1
    fi
    (cd "${SOURCE_DIR}" && ./build-xcframework.sh)
    mkdir -p "${OUT_DIR}"
    cp -R "${SOURCE_DIR}/build-apple/llama.xcframework" "${OUT_DIR}/"
    echo "==> artifacts in ${OUT_DIR}: llama.xcframework"
    ;;

  android)
    : "${ANDROID_NDK_HOME:?set ANDROID_NDK_HOME to your NDK path}"
    for abi in ${ANDROID_ABIS}; do
      BUILD_DIR="${SCRIPT_DIR}/build/cmake-android-${abi}"
      # shellcheck disable=SC2046
      cmake -S "${SOURCE_DIR}" -B "${BUILD_DIR}" \
        "${COMMON_FLAGS[@]}" $(backend_flags "${BACKEND}") \
        -DCMAKE_TOOLCHAIN_FILE="${ANDROID_NDK_HOME}/build/cmake/android.toolchain.cmake" \
        -DANDROID_ABI="${abi}" \
        -DANDROID_PLATFORM=android-29 \
        -DANDROID_STL=c++_shared
      cmake --build "${BUILD_DIR}" --config Release -j "$(getconf _NPROCESSORS_ONLN)"
      collect "${BUILD_DIR}" "${OUT_DIR}/${abi}"
    done
    ;;
esac
