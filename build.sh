#!/bin/bash
# ============================================================================
#  Build libplacebo as a single self-contained DLL for MSVC consumption
#  (no MSYS2 runtime, no third-party DLL dependencies)
#
#  Strategy: static glslang + SPIRV-Tools instead of shared shaderc.
#  All C++ deps absorbed into one DLL. Zero extra DLLs.
#
#  Usage:
#    ./build.sh                           # auto-clone libplacebo, then build
#    ./build.sh --source /path/to/libplacebo  # use existing source tree
#    ./build.sh --source /path/to/libplacebo --output /path/to/dist
#
#  Or place this script inside a libplacebo clone and run directly:
#    cp build.sh ../libplacebo/ && cd ../libplacebo && ./build.sh
#
#  Optional env vars:
#    LIBPLACEBO_SOURCE=/path     same as --source
#    LIBPLACEBO_OUTPUT=/path     same as --output
#    BUILD_TYPE=debug            build type (default: release)
#    JOBS=8                      parallel jobs (default: all cores)
#    ENABLE_VULKAN=0             disable Vulkan backend
#    ENABLE_D3D11=0              disable D3D11 backend
#    ENABLE_OPENGL=0             disable OpenGL backend
#    ENABLE_SHADERC=1            use shaderc instead of glslang (adds DLL dep)
#
#  Output (in dist/ or --output):
#    bin/libplacebo-<apiver>.dll   single self-contained DLL
#    lib/libplacebo-<apiver>.def   export definitions
#    lib/libplacebo.lib            MSVC import library (COFF)
#    lib/libplacebo.dll.a          MinGW import library
#    include/libplacebo/           public headers
# ============================================================================

set -euo pipefail

# ---- Configuration ----
BUILD_TYPE="${BUILD_TYPE:-release}"
JOBS="${JOBS:-$(nproc 2>/dev/null || echo 4)}"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DIST_DIR=""
BUILD_DIR=""

# Feature toggles
ENABLE_VULKAN="${ENABLE_VULKAN:-1}"
ENABLE_D3D11="${ENABLE_D3D11:-1}"
ENABLE_OPENGL="${ENABLE_OPENGL:-1}"
ENABLE_SHADERC="${ENABLE_SHADERC:-0}"
ENABLE_LCMS=1
ENABLE_DOVI=1

# ---- Resolve libplacebo source ----
SOURCE=""
OUTPUT=""

while [[ $# -gt 0 ]]; do
    case "$1" in
        --source) SOURCE="$2"; shift 2 ;;
        --output) OUTPUT="$2"; shift 2 ;;
        --help|-h)
            echo "Usage: $0 [--source PATH] [--output PATH]"
            echo ""
            echo "  --source PATH   Path to libplacebo source tree (default: auto-detect or clone)"
            echo "  --output PATH   Output directory (default: <source>/dist)"
            echo ""
            echo "If --source is omitted:"
            echo "  1. Uses \$LIBPLACEBO_SOURCE if set"
            echo "  2. Uses the directory containing this script if it looks like libplacebo"
            echo "  3. Otherwise, clones libplacebo from GitHub"
            exit 0
            ;;
        *) echo "Unknown option: $1"; exit 1 ;;
    esac
done

# Resolve source directory
if [[ -n "$SOURCE" ]]; then
    PL_SOURCE="$(cd "$SOURCE" 2>/dev/null && pwd)" || {
        echo "ERROR: --source directory does not exist: $SOURCE"
        exit 1
    }
elif [[ -n "${LIBPLACEBO_SOURCE:-}" ]]; then
    PL_SOURCE="$(cd "$LIBPLACEBO_SOURCE" 2>/dev/null && pwd)" || {
        echo "ERROR: LIBPLACEBO_SOURCE directory does not exist: $LIBPLACEBO_SOURCE"
        exit 1
    }
elif [[ -f "$SCRIPT_DIR/meson.build" && -d "$SCRIPT_DIR/src" ]]; then
    PL_SOURCE="$SCRIPT_DIR"
else
    echo "No --source given and script is not inside a libplacebo tree."
    echo "Cloning libplacebo from GitHub..."
    PL_SOURCE="$SCRIPT_DIR/build/libplacebo-src"
    if [[ ! -d "$PL_SOURCE" ]]; then
        git clone https://github.com/haasn/libplacebo.git "$PL_SOURCE"
    fi
fi

# Validate source
if [[ ! -f "$PL_SOURCE/meson.build" ]]; then
    echo "ERROR: $PL_SOURCE does not look like a libplacebo source tree (no meson.build)"
    exit 1
fi

echo "  Source:      $PL_SOURCE"

# Resolve output directory
if [[ -n "$OUTPUT" ]]; then
    DIST_DIR="$OUTPUT"
elif [[ -n "${LIBPLACEBO_OUTPUT:-}" ]]; then
    DIST_DIR="$LIBPLACEBO_OUTPUT"
else
    DIST_DIR="$PL_SOURCE/dist"
fi

BUILD_DIR="$PL_SOURCE/build"
mkdir -p "$DIST_DIR"

# ---- Check environment ----
if [[ "${MSYSTEM:-}" != "UCRT64" ]]; then
    echo "ERROR: This script must be run from an MSYS2 UCRT64 shell."
    echo "       Start Menu -> MSYS2 -> UCRT64"
    echo "       Current MSYSTEM=${MSYSTEM:-<not set>}"
    exit 1
fi

echo "============================================"
echo " libplacebo self-contained DLL build"
echo "============================================"
echo "  Build type:  $BUILD_TYPE"
echo "  Jobs:        $JOBS"
echo "  Dist dir:    $DIST_DIR"
echo "  Source:      $PL_SOURCE"
echo "  Vulkan:      $([ "$ENABLE_VULKAN" == "1" ] && echo yes || echo no)"
echo "  D3D11:       $([ "$ENABLE_D3D11" == "1" ] && echo yes || echo no)"
echo "  OpenGL:      $([ "$ENABLE_OPENGL" == "1" ] && echo yes || echo no)"
echo "============================================"

# ---- Step 1: Install dependencies ----
echo ""
echo "[1/7] Checking MSYS2 packages..."

PACKAGES=(
    mingw-w64-ucrt-x86_64-meson
    mingw-w64-ucrt-x86_64-ninja
    mingw-w64-ucrt-x86_64-gcc
    mingw-w64-ucrt-x86_64-python
    mingw-w64-ucrt-x86_64-vulkan-headers
    mingw-w64-ucrt-x86_64-vulkan-loader
    mingw-w64-ucrt-x86_64-lcms2
    mingw-w64-ucrt-x86_64-spirv-cross
    mingw-w64-ucrt-x86_64-llvm
    mingw-w64-ucrt-x86_64-tools      # gendef
    mingw-w64-ucrt-x86_64-glslang     # static SPIR-V compiler (replaces shaderc)
    mingw-w64-ucrt-x86_64-spirv-tools # SPIR-V optimizer libs
    mingw-w64-ucrt-x86_64-libdovi
)

MISSING=()
for pkg in "${PACKAGES[@]}"; do
    if ! pacman -Q "$pkg" &>/dev/null; then
        MISSING+=("$pkg")
    fi
done

if [[ ${#MISSING[@]} -gt 0 ]]; then
    echo "  Missing packages:"
    for p in "${MISSING[@]}"; do
        echo "    - $p"
    done
    echo ""
    read -r -p "  Install them now? [Y/n] " answer
    if [[ "${answer,,}" != "n" ]]; then
        pacman -S --needed "${MISSING[@]}"
    else
        echo "  Aborted. Please install missing packages and re-run."
        exit 1
    fi
fi

for tool in meson ninja gendef llvm-dlltool; do
    if ! command -v "$tool" &>/dev/null; then
        echo "ERROR: $tool not found after package install."
        exit 1
    fi
done

echo "  All dependencies ready."

# ---- Step 2: Prepare static linking shims ----
echo ""
echo "[2/7] Resolving static libraries..."

# Strategy: All third-party C++ libraries must be linked statically to
# eliminate runtime DLL dependencies (especially libwinpthread-1.dll).
# We hide .dll.a import libs so the linker picks up .a static libs.
#
# With glslang (default), the dependency chain is:
#   libplacebo → glslang + SPIRV + SPIRV-Tools-opt + SPIRV-Tools + SPIRV-Tools-link
# All available as static .a in MSYS2 UCRT64.
#
# pkg-config name            import lib                     static lib
# ---------------------------------------------------------------------
# glslang         → (no .pc)                 libglslang.dll.a         libglslang.a
# SPIRV           → (no .pc)                 libSPIRV.dll.a           libSPIRV.a
# SPIRV-Tools     → SPIRV-Tools.pc           libSPIRV-Tools.dll.a     libSPIRV-Tools.a
# shaderc (opt)   → shaderc.pc               libshaderc_shared.dll.a  (shared only)
# lcms2           → lcms2.pc                 liblcms2.dll.a           liblcms2.a
# spirv-cross     → spirv-cross-c-shared.pc  libspirv-cross-c-shared.dll.a libspirv-cross-c.a
# dovi            → dovi.pc                  libdovi.dll.a            libdovi.a

MINGW_LIB="$MINGW_PREFIX/lib"
RESTORE_LIST=()
EXTRA_LINK_ARGS=()

# Helper: hide import lib, optionally symlink static .a to match expected name
force_static() {
    local dll_a_name="$1"    # e.g. "libspirv-cross-c-shared.dll.a"
    local static_a_name="$2" # e.g. "libspirv-cross-c.a"
    local link_as="$3"       # e.g. "libspirv-cross-c-shared.a" (symlink name)

    if [[ -f "$MINGW_LIB/$dll_a_name" ]]; then
        mv "$MINGW_LIB/$dll_a_name" "$MINGW_LIB/${dll_a_name}.build-msvc-bak"
        RESTORE_LIST+=("$MINGW_LIB/$dll_a_name:$MINGW_LIB/${dll_a_name}.build-msvc-bak")
        echo "    Hid $dll_a_name"
    fi

    if [[ -n "$link_as" && -f "$MINGW_LIB/$static_a_name" && ! -f "$MINGW_LIB/$link_as" ]]; then
        ln -sf "$static_a_name" "$MINGW_LIB/$link_as"
        RESTORE_LIST+=("$MINGW_LIB/$link_as:link")
        echo "    Linked $link_as -> $static_a_name"
    fi
}

cleanup_static_shims() {
    for entry in "${RESTORE_LIST[@]}"; do
        local path="${entry%%:*}"
        local action="${entry##*:}"
        if [[ "$action" == "link" ]]; then
            rm -f "$path"
        else
            mv "$action" "$path" 2>/dev/null || true
        fi
    done
    RESTORE_LIST=()
}

trap cleanup_static_shims EXIT

# ---- glslang + SPIRV-Tools (static, for Vulkan/D3D11 SPIR-V compilation) ----
# glslang has no .pc file; libplacebo's meson.build uses find_library with
# static:true. We hide the .dll.a files so the linker picks up the .a versions.
# SPIRV-Tools has a .pc file (SPIRV-Tools.pc) with Libs pointing to the .dll.a
# variants. We hide those too.
if [[ "$ENABLE_SHADERC" != "1" ]]; then
    # glslang + SPIRV
    force_static "libglslang.dll.a"  "libglslang.a"  ""
    force_static "libSPIRV.dll.a"    "libSPIRV.a"    ""
    force_static "libglslang-default-resource-limits.dll.a" \
                 "libglslang-default-resource-limits.a" ""

    # SPIRV-Tools
    force_static "libSPIRV-Tools.dll.a"     "libSPIRV-Tools.a"     ""
    force_static "libSPIRV-Tools-opt.dll.a"  "libSPIRV-Tools-opt.a"  ""
    force_static "libSPIRV-Tools-link.dll.a" "libSPIRV-Tools-link.a" ""

    echo "    Hid glslang/SPIRV-Tools .dll.a files (using static .a)"
else
    # ---- shaderc (KEEP AS SHARED DLL) ----
    # When user opts into shaderc, we accept the DLL dependency.
    # Hide static variants so meson only finds the shared variant.
    for pc in shaderc_combined shaderc_static; do
        pc_path="$MINGW_PREFIX/lib/pkgconfig/${pc}.pc"
        if [[ -f "$pc_path" ]]; then
            mv "$pc_path" "${pc_path}.build-msvc-bak"
            RESTORE_LIST+=("$pc_path:${pc_path}.build-msvc-bak")
            echo "    Hid ${pc}.pc"
        fi
    done
fi

# ---- lcms2 ----
# pkg-config: -llcms2 -llcms2_fast_float
# static: liblcms2.a, liblcms2_fast_float.a (same names, just hide .dll.a)
if [[ "$ENABLE_LCMS" == "1" ]]; then
    force_static "liblcms2.dll.a"           "liblcms2.a"           ""
    force_static "liblcms2_fast_float.dll.a" "liblcms2_fast_float.a" ""
fi

# ---- spirv-cross (for d3d11) ----
# pkg-config: -lspirv-cross-c-shared  (NO Libs.private listed)
# static: libspirv-cross-c.a, plus we must manually add the C++ impl libs
if [[ "$ENABLE_D3D11" == "1" ]]; then
    force_static \
        "libspirv-cross-c-shared.dll.a" \
        "libspirv-cross-c.a" \
        "libspirv-cross-c-shared.a"

    # spirv-cross-c-shared.pc has no Libs.private, so meson won't add
    # the C++ implementation libs. Add them manually via link args.
    # These are needed at link time because spirv-cross-c.a references
    # symbols from them.
    EXTRA_LINK_ARGS+=(
        "-lspirv-cross-core"
        "-lspirv-cross-cpp"
        "-lspirv-cross-glsl"
        "-lspirv-cross-hlsl"
        "-lspirv-cross-msl"
        "-lspirv-cross-reflect"
        "-lspirv-cross-util"
    )

    echo "    Adding spirv-cross C++ impl libs to link"
fi

# ---- libwinpthread (always force static) ----
# MinGW C++ libraries (glslang, SPIRV-Tools, spirv-cross, lcms2) are
# compiled with posix thread model. Their std::thread usage resolves
# through libstdc++.a → libwinpthread. We must absorb winpthread into
# our DLL, otherwise libwinpthread-1.dll becomes a runtime dependency.
# Using -Wl,-Bstatic ensures static binding even though GCC specs
# append -lpthread later (with -Bdynamic default).
force_static "libwinpthread.dll.a" "libwinpthread.a" ""
EXTRA_LINK_ARGS+=(
    "-Wl,--whole-archive"
    "-lwinpthread"
    "-Wl,--no-whole-archive"
)

# ---- libdovi ----
# pkg-config: -ldovi
# static: libdovi.a (same name, just hide .dll.a)
if [[ "$ENABLE_DOVI" == "1" ]]; then
    force_static "libdovi.dll.a" "libdovi.a" ""
fi

echo "  Static shims ready."

# ---- Step 3: Configure meson ----
echo ""
echo "[3/7] Configuring meson..."

MESON_OPTS=(
    --buildtype="$BUILD_TYPE"
    --prefix="$DIST_DIR"
    -Ddefault_library=shared
    -Dprefer_static=true
    -Ddemos=false
    -Dtests=false
    -Dbench=false
    -Dfuzz=false
    -Ddebug-abort=false
)

# Build meson array-style value: ['arg1','arg2',...]
build_meson_array() {
    local result="["
    local first=true
    for a in "$@"; do
        if $first; then first=false; else result+=","; fi
        result+="'$a'"
    done
    result+="]"
    echo "$result"
}

# Static-link compiler runtimes -> no MSYS2 DLL deps
# -static-libgcc/static-libstdc++: eliminate libgcc_s_seh / libstdc++ DLL deps.
# -Wl,-Bstatic -lwinpthread -Wl,-Bdynamic: absorb winpthread into our DLL,
# counteracting GCC specs' implicit -lpthread at end of link line.
c_args=("-static-libgcc" "${EXTRA_LINK_ARGS[@]}")
cpp_args=("-static-libgcc" "-static-libstdc++" "${EXTRA_LINK_ARGS[@]}")

MESON_OPTS+=(-Dc_link_args="$(build_meson_array "${c_args[@]}")")
MESON_OPTS+=(-Dcpp_link_args="$(build_meson_array "${cpp_args[@]}")")

# Graphics backends
if [[ "$ENABLE_VULKAN" == "1" ]]; then
    MESON_OPTS+=(-Dvulkan=enabled -Dvk-proc-addr=enabled)
else
    MESON_OPTS+=(-Dvulkan=disabled)
fi

if [[ "$ENABLE_D3D11" == "1" ]]; then
    MESON_OPTS+=(-Dd3d11=enabled)
else
    MESON_OPTS+=(-Dd3d11=disabled)
fi

if [[ "$ENABLE_OPENGL" == "1" ]]; then
    MESON_OPTS+=(-Dopengl=enabled -Dgl-proc-addr=enabled)
else
    MESON_OPTS+=(-Dopengl=disabled)
fi

# SPIR-V compiler
if [[ "$ENABLE_SHADERC" == "1" ]]; then
    MESON_OPTS+=(-Dshaderc=enabled -Dglslang=disabled)
else
    MESON_OPTS+=(-Dshaderc=disabled -Dglslang=enabled)
fi

# Optional features
if [[ "$ENABLE_LCMS" == "1" ]]; then
    MESON_OPTS+=(-Dlcms=enabled)
else
    MESON_OPTS+=(-Dlcms=disabled)
fi

if [[ "$ENABLE_DOVI" == "1" ]]; then
    MESON_OPTS+=(-Ddovi=enabled -Dlibdovi=enabled)
else
    MESON_OPTS+=(-Ddovi=disabled -Dlibdovi=disabled)
fi

export PKG_CONFIG_PATH="$MINGW_PREFIX/lib/pkgconfig:$MINGW_PREFIX/share/pkgconfig"

meson setup "$BUILD_DIR" "$PL_SOURCE" "${MESON_OPTS[@]}"

# ---- Step 4: Verify meson found deps correctly ----
echo ""
echo "[4/7] Verifying dependency resolution..."

# Extract the link command from build.ninja to check for shared libs
if [[ "$ENABLE_SHADERC" == "1" ]]; then
    if grep -q 'shaderc_shared\.dll' "$BUILD_DIR/build.ninja" 2>/dev/null; then
        echo "  OK: shaderc_shared.dll (expected in shaderc mode)"
    fi
else
    if grep -qE ' (libglslang|libSPIRV(-Tools)?)(-[a-z]+)?\.dll' "$BUILD_DIR/build.ninja" 2>/dev/null; then
        echo "  WARNING: shared SPIR-V compiler DLL detected — static linking may have failed"
        grep -oE '[^ ]*\.dll[^ ]*' "$BUILD_DIR/build.ninja" 2>/dev/null | head -5
    else
        echo "  OK: no shared SPIR-V compiler DLLs in link command"
    fi
fi

echo "  Build configuration OK."

# ---- Step 5: Build ----
echo ""
echo "[5/7] Building..."

meson compile -C "$BUILD_DIR" -j"$JOBS"

# ---- Step 6: Post-process (def, lib, package) ----
echo ""
echo "[6/7] Generating MSVC artifacts..."

rm -rf "$DIST_DIR"
meson install -C "$BUILD_DIR"

# Find the DLL
DLL=$(find "$DIST_DIR/bin" -name 'libplacebo-*.dll' 2>/dev/null | head -1)
if [[ -z "$DLL" ]]; then
    DLL=$(find "$BUILD_DIR/src" -name 'libplacebo-*.dll' 2>/dev/null | head -1)
fi
if [[ -z "$DLL" ]]; then
    echo "ERROR: Could not find libplacebo DLL"
    exit 1
fi

DLL_NAME=$(basename "$DLL")
DLL_BASENAME="${DLL_NAME%.*}"

# Ensure dist layout
mkdir -p "$DIST_DIR/bin" "$DIST_DIR/lib"
if [[ "$DLL" != "$DIST_DIR/bin/$DLL_NAME" ]]; then
    cp "$DLL" "$DIST_DIR/bin/$DLL_NAME"
fi

# Copy dll.a
DLL_A=$(find "$BUILD_DIR/src" -name 'libplacebo.dll.a' 2>/dev/null | head -1)
if [[ -n "$DLL_A" ]]; then
    cp "$DLL_A" "$DIST_DIR/lib/libplacebo.dll.a"
    echo "  Copied: libplacebo.dll.a"
fi

# Generate .def from DLL
DEF_FILE="$DIST_DIR/lib/${DLL_BASENAME}.def"
gendef - "$DIST_DIR/bin/$DLL_NAME" > "$DEF_FILE" 2>/dev/null || true
if [[ ! -s "$DEF_FILE" ]]; then
    gendef "$DIST_DIR/bin/$DLL_NAME" 2>/dev/null || true
    if [[ -f "$DIST_DIR/bin/${DLL_BASENAME}.def" ]]; then
        mv "$DIST_DIR/bin/${DLL_BASENAME}.def" "$DEF_FILE"
    fi
fi

if [[ -s "$DEF_FILE" ]]; then
    EXPORT_COUNT=$(wc -l < "$DEF_FILE")
    echo "  Generated: ${DLL_BASENAME}.def ($EXPORT_COUNT exports)"
else
    echo "WARNING: gendef failed, using llvm-nm fallback..."
    {
        echo "EXPORTS"
        llvm-nm --defined-only --extern-only -g "$DIST_DIR/bin/$DLL_NAME" 2>/dev/null | \
            awk '{print $NF}' | grep -E '^(pl_|PL_)' | sort -u
    } > "$DEF_FILE"
    if [[ -s "$DEF_FILE" ]]; then
        echo "  Generated .def from llvm-nm fallback"
    else
        echo "ERROR: Could not extract exports"
        exit 1
    fi
fi

# Generate MSVC import library (.lib) from .def
LIB_FILE="$DIST_DIR/lib/libplacebo.lib"
llvm-dlltool -m i386:x86-64 -d "$DEF_FILE" -l "$LIB_FILE"
echo "  Generated: libplacebo.lib"

# ---- Step 7: Verify DLL is self-contained ----
echo ""
echo "[7/7] Verifying DLL dependencies..."

BUNDLED_DLLS=()

while read -r line; do
    dllname=$(echo "$line" | awk '{print $NF}')
    case "$dllname" in
        KERNEL32.dll|ADVAPI32.dll|SHELL32.dll|USER32.dll|GDI32.dll|OLE32.dll|\
        ole32.dll|WS2_32.dll|SETUPAPI.dll|SHLWAPI.dll|VERSION.dll|WINMM.dll|\
        bcrypt.dll|bcryptprimitives.dll|CFGMGR32.dll|ntdll.dll|kernelbase.dll|\
        ucrtbase.dll|api-ms-win-*|msvcrt.dll|vulkan-1.dll|d3d11.dll|dxgi.dll|\
        d3dcompiler_47.dll|d2d1.dll|dwrite.dll|mfplat.dll|combase.dll|\
        dwmapi.dll|graphicscapture.dll|IPHLPAPI.DLL|MSIMG32.dll|Psapi.dll|\
        shfolder.dll|USERENV.dll)
            ;;  # system DLL — always present, no action
        libgcc_*|libstdc++*|msys-*|cygwin*)
            echo "  *** ERROR: unexpected compiler/MSYS2 runtime: $dllname ***"
            BUNDLED_DLLS+=("$dllname")
            ;;
        libshaderc_shared.dll|glslang.dll|SPIRV.dll|libSPIRV-Tools*.dll|\
        libwinpthread-1.dll|liblcms2-*.dll|libdovi.dll)
            echo "  *** ERROR: third-party DLL leaked: $dllname ***"
            echo "  Static linking failed for this dependency."
            BUNDLED_DLLS+=("$dllname")
            ;;
        *)
            echo "  Required: $dllname"
            BUNDLED_DLLS+=("$dllname")
            ;;
    esac
done < <(objdump -p "$DIST_DIR/bin/$DLL_NAME" 2>/dev/null | grep 'DLL Name:' || true)

# Bundle non-system DLLs that couldn't be eliminated
for dep in "${BUNDLED_DLLS[@]}"; do
    dep_path=$(find "$MINGW_PREFIX/bin" /usr/bin -name "$dep" 2>/dev/null | head -1)
    if [[ -n "$dep_path" && -f "$dep_path" ]]; then
        cp "$dep_path" "$DIST_DIR/bin/$dep"
        echo "    Bundled: $dep"
    else
        echo "    WARNING: Could not find $dep to bundle"
    fi
done

echo ""
if [[ ${#BUNDLED_DLLS[@]} -eq 0 ]]; then
    echo "  DLL is fully self-contained (only Windows system DLLs + graphics API DLLs)"
else
    echo "  ${#BUNDLED_DLLS[@]} runtime DLL(s) bundled in dist/bin/."
    if [[ "$ENABLE_SHADERC" == "1" ]]; then
        echo "  (shaderc mode: libshaderc_shared.dll is expected)"
    fi
fi

# Show final layout
echo ""
echo "  Output layout:"
find "$DIST_DIR" -type f 2>/dev/null | sort | while read -r f; do
    rel="${f#$DIST_DIR/}"
    size=$(stat -c%s "$f" 2>/dev/null || echo "?")
    if [[ "$size" != "?" ]]; then
        if [[ $size -gt 1048576 ]]; then
            size_str="$(( size / 1048576 )) MB"
        elif [[ $size -gt 1024 ]]; then
            size_str="$(( size / 1024 )) KB"
        else
            size_str="${size} B"
        fi
        echo "    $rel  ($size_str)"
    else
        echo "    $rel"
    fi
done

echo ""
echo "============================================"
echo " Build complete!"
echo "============================================"
echo ""
echo "Consumer usage:"
echo "  MSVC:  /I $DIST_DIR/include  /link $DIST_DIR/lib/libplacebo.lib"
echo "  MinGW: -I$DIST_DIR/include   -L$DIST_DIR/lib -lplacebo"
