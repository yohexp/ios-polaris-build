#!/bin/bash
# Build Turnip (Mesa freedreno Vulkan, darwin KMD), SweetMetal2.bundle and the
# NativeAdreno ABI test (v2test) for iOS 16 arm64, on a macOS runner.
#
#   metal/build-userland.sh
#
# Sources (pinned by UniXNU's adreno-compiler-inputs.json):
#   mesa            85fda3b36405bcaea8bffc64aa4f2651dc90770d + patches/mesa/*
#   metal2vulkan    720ef1ce                              + phone/metal2/bridge/patches/*
# Output: out/SweetMetal2.bundle, out/libvulkan_freedreno.dylib, out/v2test
set -euo pipefail
cd "$(dirname "$0")/.."
ROOT=$PWD
W=$ROOT/_metal
rm -rf "$W" "$ROOT/out"
mkdir -p "$W" "$ROOT/out"

export PATH="/opt/homebrew/opt/bison/bin:/opt/homebrew/opt/flex/bin:/opt/homebrew/opt/llvm/bin:$PATH"
SDK=$(xcrun --sdk iphoneos --show-sdk-path)

# ---- UniXNU: the mesa patch set -------------------------------------------
git clone --depth 1 --filter=blob:none --sparse https://github.com/UniXNU/UniXNU.git "$W/unixnu" >/dev/null 2>&1
git -C "$W/unixnu" sparse-checkout set patches/mesa scripts/data >/dev/null 2>&1
python3 - "$W/unixnu" > "$W/mesa-patches.txt" <<'PY'
import json, sys
d = json.load(open(sys.argv[1] + '/scripts/data/adreno-compiler-inputs.json'))
print('\n'.join(d['patches']))
PY
head -3 "$W/mesa-patches.txt"

# ---- Mesa (sparse) + the turnip-darwin patches -----------------------------
git clone --depth 1 --filter=blob:none --sparse https://gitlab.freedesktop.org/mesa/mesa.git "$W/mesa" >/dev/null 2>&1
python3 - "$W/unixnu" > "$W/mesa-dirs.txt" <<'PY'
import json, sys
d = json.load(open(sys.argv[1] + '/scripts/data/adreno-compiler-inputs.json'))
print('\n'.join(d['mesa']['sparse_directories']))
PY
git -C "$W/mesa" sparse-checkout set $(cat "$W/mesa-dirs.txt")
git -C "$W/mesa" fetch --depth 1 origin 85fda3b36405bcaea8bffc64aa4f2651dc90770d
git -C "$W/mesa" checkout -q FETCH_HEAD
while read -r p; do
	[ -n "$p" ] || continue
	echo "apply $p"
	patch -p1 -d "$W/mesa" -s < "$W/unixnu/$p"
done < "$W/mesa-patches.txt"

# ---- Turnip ---------------------------------------------------------------
FLAGS="'-target', 'arm64-apple-ios16.0', '-isysroot', '$SDK', '-fstack-protector-strong'"
cat > "$W/ios16.cross" <<EOF
[binaries]
c = '$(xcrun --sdk iphoneos --find clang)'
cpp = '$(xcrun --sdk iphoneos --find clang++)'
objc = '$(xcrun --sdk iphoneos --find clang)'
ar = '$(xcrun --sdk iphoneos --find ar)'
strip = '$(xcrun --sdk iphoneos --find strip)'
pkg-config = '/usr/bin/false'
[host_machine]
system = 'darwin'
cpu_family = 'aarch64'
cpu = 'arm64'
endian = 'little'
[properties]
needs_exe_wrapper = true
[built-in options]
c_args = [$FLAGS]
cpp_args = [$FLAGS]
objc_args = [$FLAGS]
c_link_args = [$FLAGS]
cpp_link_args = [$FLAGS]
objc_link_args = [$FLAGS]
EOF
python3 -m pip install --quiet mako pyyaml 2>/dev/null || true
meson setup "$W/build-ios" "$W/mesa" --cross-file "$W/ios16.cross" \
	-Dgallium-drivers= -Dvulkan-drivers=freedreno -Dfreedreno-kmds=darwin \
	-Dtu-darwin-abi-dir="$ROOT/phone/turnip" -Dplatforms=macos -Dglx=disabled \
	-Degl=disabled -Dgbm=disabled -Dopengl=false -Dgles1=disabled -Dgles2=disabled \
	-Dllvm=disabled -Dshared-glapi=disabled -Dxmlconfig=disabled -Dshader-cache=disabled \
	-Dtools= -Dbuild-tests=false -Dvideo-codecs= -Dvulkan-layers= -Dlibunwind=disabled \
	-Dlmsensors=disabled -Dvalgrind=disabled -Dexpat=disabled -Dzstd=disabled \
	-Dbuildtype=release -Db_ndebug=true > "$W/configure.log" 2>&1 || {
		tail -40 "$W/configure.log"; exit 1; }
ninja -C "$W/build-ios" src/freedreno/vulkan/libvulkan_freedreno.dylib > "$W/turnip.log" 2>&1 || {
		grep -E "error:|FAILED" "$W/turnip.log" | head -40; exit 1; }
cp "$W/build-ios/src/freedreno/vulkan/libvulkan_freedreno.dylib" "$ROOT/out/"
nm -gU "$ROOT/out/libvulkan_freedreno.dylib" | grep -q " T _vkGetInstanceProcAddr"

# ---- metal2vulkan bridge (Rust) -------------------------------------------
git clone https://github.com/steelbrain/metal2vulkan.git "$W/metal2vulkan" >/dev/null 2>&1
git -C "$W/metal2vulkan" checkout -q 720ef1ce
for p in "$ROOT"/phone/metal2/bridge/patches/*.patch; do
	echo "apply $(basename "$p")"
	patch -p1 -d "$W/metal2vulkan" -s < "$p"
done
llvm-as -o "$W/runtime_examples.air" "$W/metal2vulkan/crates/metal2vulkan-validation/fixtures/public/examples/runtime_examples.ll"
llvm-as -o "$W/function_constant.air" "$W/metal2vulkan/crates/metal2vulkan-validation/fixtures/public/kernel_function_constant_gate_fold.ll"
cat > "$W/Cargo.toml" <<EOF
[package]
name = "native-metal-bridge"
version = "0.1.0"
edition = "2024"
rust-version = "1.85"
[workspace]
[lib]
crate-type = ["staticlib"]
path = "$ROOT/phone/metal2/bridge/NativeMetalBridge.rs"
[dependencies]
metal2vulkan = { path = "$W/metal2vulkan/crates/metal2vulkan", features = ["ash"] }
metal2vulkan-runtime = { path = "$W/metal2vulkan/crates/metal2vulkan-runtime" }
libc = "0.2"
sha2 = { version = "0.10", features = ["asm"] }
[profile.release]
panic = "unwind"
debug = 1
EOF
rustup target add aarch64-apple-ios >/dev/null 2>&1 || true
NMB_FIXTURE_AIR="$W/runtime_examples.air" NMB_FC_AIR="$W/function_constant.air" \
IPHONEOS_DEPLOYMENT_TARGET=16.0 MACOSX_DEPLOYMENT_TARGET=14.0 \
	cargo build --release --manifest-path "$W/Cargo.toml" --target aarch64-apple-ios \
	--target-dir "$W/m2v-target" > "$W/m2v.log" 2>&1 || {
		grep -E "^(error|warning: unused)" -A6 "$W/m2v.log" | head -60; exit 1; }
mkdir -p "$W/m2v-ios"
cp "$W/m2v-target/aarch64-apple-ios/release/libnative_metal_bridge.a" "$W/m2v-ios/"

# ---- SweetMetal2.bundle ---------------------------------------------------
B="$ROOT/out/SweetMetal2.bundle"
mkdir -p "$B"
xcrun --sdk iphoneos clang++ -x objective-c++ -std=c++17 -fobjc-arc -O2 -g -Wall \
	-Wno-deprecated-declarations -Wno-unused-function -bundle \
	-target arm64-apple-ios16.0 -isysroot "$SDK" \
	-o "$B/SweetMetal2" "$ROOT/phone/metal2/SweetMetal2.mm" "$ROOT/phone/metal2/NativeBridgeMetalFrontend.mm" \
	-x none "$W/m2v-ios/libnative_metal_bridge.a" -Wl,-dead_strip -lc++ \
	-framework Foundation -framework Metal -framework IOSurface -framework IOKit -framework CoreFoundation
cp "$ROOT/phone/metal2/Info.plist" "$B/"
cp "$ROOT/out/libvulkan_freedreno.dylib" "$B/"
strip -x "$B/SweetMetal2" "$B/libvulkan_freedreno.dylib" 2>/dev/null || true
codesign -f -s - "$B/libvulkan_freedreno.dylib" 2>/dev/null || true
codesign -f -s - "$B" 2>/dev/null || true

# ---- v2test (NativeAdreno ABI) --------------------------------------------
xcrun --sdk iphoneos clang++ -target arm64-apple-ios16.0 -isysroot "$SDK" -O2 -Wall \
	-I "$ROOT/phone/turnip" -o "$ROOT/out/v2test" "$ROOT/phone/turnip/v2test.cpp" \
	-framework IOKit -framework CoreFoundation
codesign -f -s - "$ROOT/out/v2test" 2>/dev/null || true

ls -la "$ROOT/out" "$B"
