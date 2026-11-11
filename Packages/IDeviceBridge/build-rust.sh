#!/bin/sh
# Builds idevice's C API plus Atelier's pairing host, device helpers and Apple
# ID calls into IDevice.xcframework for iOS devices (#9, #49). idevice (MIT) is
# fetched by fetch-idevice.sh; its ffi crate is built with our modules
# (src/pairing.rs, src/device.rs, src/appleid.rs) added, so one idevice serves
# the install path (route A), on-phone pairing and isideload, with no
# duplicate symbols. isideload (MIT, https://github.com/nab138/isideload) signs
# in to Apple and makes the developer calls for free Apple ID signing (#49).
# It turns on idevice's `ring` backend, which idevice then prefers to
# `rustcrypto`; ring's C code builds with Xcode's clang.
#
# idevice.Cargo.lock pins every crate of the build, isideload's included. After
# changing idevice's release or the crates added here, run `--check` and copy
# vendor/idevice/Cargo.lock back to it.
#
# Codemagic runs it before `xcodegen generate`; on a Mac it needs rustup and
# Xcode. `--host` instead builds idevice-ffi for this machine, without the
# xcframework, and `--check` only checks it compiles; both work on Linux too.
set -eu

cd "$(dirname "$0")"
ROOT=$(pwd)
./fetch-idevice.sh

FFI="$ROOT/vendor/idevice/ffi"
# Add our modules to idevice-ffi (idempotent). cbindgen, run by idevice-ffi's
# build.rs, picks them up and emits them into the generated idevice.h.
cp src/pairing.rs "$FFI/src/atelier_pairing.rs"
cp src/device.rs "$FFI/src/atelier_device.rs"
cp src/appleid.rs "$FFI/src/atelier_appleid.rs"
for module in atelier_pairing atelier_device atelier_appleid; do
	grep -q "pub mod $module;" "$FFI/src/lib.rs" \
		|| printf '\npub mod %s;\n' "$module" >> "$FFI/src/lib.rs"
done

# And what src/appleid.rs uses (idempotent): isideload, on idevice-ffi's own
# idevice rather than a second copy from crates.io, and the crates whose types
# it shares with isideload.
grep -q '^\[dependencies.isideload\]' "$FFI/Cargo.toml" || cat >> "$FFI/Cargo.toml" <<'TOML'

# Added by Atelier's build-rust.sh for src/appleid.rs (#49).
[dependencies.isideload]
version = "=0.5.2"
default-features = false
features = ["install", "tokio-mt", "fs-storage"]

[dependencies.rustls]
version = "0.23"
default-features = false
features = ["ring"]

[dependencies.rootcause]
version = "0.12"
TOML
grep -q '^\[patch.crates-io\]' "$ROOT/vendor/idevice/Cargo.toml" || cat >> "$ROOT/vendor/idevice/Cargo.toml" <<'TOML'

[patch.crates-io]
idevice = { path = "idevice" }
TOML
cp "$ROOT/idevice.Cargo.lock" "$ROOT/vendor/idevice/Cargo.lock"

FEATURES="full rustcrypto"
case "${1:-}" in
--host)
	( cd "$FFI" && cargo build --release --no-default-features --features "$FEATURES" )
	echo "Built idevice-ffi with Atelier's modules for this machine"
	exit 0
	;;
--check)
	( cd "$FFI" && cargo check --no-default-features --features "$FEATURES" )
	echo "idevice-ffi with Atelier's modules compiles"
	exit 0
	;;
esac

rustup target add aarch64-apple-ios >/dev/null 2>&1 || true

# Lets any bindgen in the dependency tree find the iOS SDK headers (mirrors
# idevice's own apple build).
BINDGEN_EXTRA_CLANG_ARGS="--sysroot=$(xcrun --sdk iphoneos --show-sdk-path)"
export BINDGEN_EXTRA_CLANG_ARGS
( cd "$FFI" && cargo build --release --target aarch64-apple-ios \
	--no-default-features --features "$FEATURES" )

LIB="$ROOT/vendor/idevice/target/aarch64-apple-ios/release/libidevice_ffi.a"
HDR="$ROOT/build/headers"
rm -rf "$HDR" "$ROOT/IDevice.xcframework"
mkdir -p "$HDR"
cp "$FFI/idevice.h" "$HDR/idevice.h"
# Module name IDevice, as the install spike and IDeviceKit use.
cat > "$HDR/module.modulemap" <<'MM'
module IDevice {
    header "idevice.h"
    export *
}
MM

xcodebuild -create-xcframework \
	-library "$LIB" -headers "$HDR" \
	-output "$ROOT/IDevice.xcframework"
echo "Built $ROOT/IDevice.xcframework"
