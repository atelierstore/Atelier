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
# CI runs it before `xcodegen generate` (.github/workflows/build.yml), unless
# its cache has the xcframework already; on a Mac it needs rustup and
# Xcode. `--host` instead builds idevice-ffi for this machine, without the
# xcframework, and `--check` only checks it compiles; both work on Linux too.
set -eu

cd "$(dirname "$0")"
ROOT=$(pwd)
./fetch-idevice.sh

FFI="$ROOT/vendor/idevice/ffi"
# From idevice's own files each time, so a vendor folder from before a change
# to what's added below gets the change too.
git -C vendor/idevice checkout --quiet -- Cargo.toml ffi/Cargo.toml ffi/src/lib.rs
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

# isideload's AnisetteProvider is an async_trait: Atelier's own wraps its
# anisette server's calls in a time limit (#42).
[dependencies.async-trait]
version = "0.1"

# isideload's HTTP errors, which tell whether Apple refused a kept sign-in's
# token (HTTP 401 or 403) or didn't answer (#182).
[dependencies.reqwest]
version = "0.13"
default-features = false

# The versions isideload uses, for the certificate whose key another tool
# handed over (#152): its key, the certificate, and where isideload keeps it.
[dependencies.rsa]
version = "0.9.10"
default-features = false

[dependencies.x509-cert]
version = "0.2.5"
default-features = false

[dependencies.sha2]
version = "0.11"
default-features = false

[dependencies.hex]
version = "0.4.3"
default-features = false
features = ["alloc"]
TOML
# isideload as published, with patches/isideload-one-text.patch, the change
# atelier-install makes so an account that takes its codes by text gets one
# text, not two (#54). Unpacked from the crate each time, so a change to the
# patch is picked up. The crate is checked against crates.io's checksum.
ISIDELOAD=isideload-0.5.2
ISIDELOAD_SHA256=7cab6348bffd8f32c9358b80c8723bc1da45ad97b0c1f30a1533ade22d4d9496
CRATE="$ROOT/vendor/$ISIDELOAD.crate"
published() { echo "$ISIDELOAD_SHA256  $CRATE" | shasum -a 256 -c - >/dev/null 2>&1; }
if ! { [ -f "$CRATE" ] && published; }; then
	curl -fsSL --retry 3 -o "$CRATE" "https://static.crates.io/crates/isideload/$ISIDELOAD.crate"
	if ! published; then
		echo "$ISIDELOAD.crate isn't the one published on crates.io" >&2
		exit 1
	fi
fi
rm -rf "$ROOT/vendor/isideload"
mkdir -p "$ROOT/vendor/isideload"
tar -xzf "$CRATE" -C "$ROOT/vendor/isideload" --strip-components 1
( cd "$ROOT/vendor/isideload" && patch -p1 --quiet < "$ROOT/patches/isideload-one-text.patch" )

grep -q '^\[patch.crates-io\]' "$ROOT/vendor/idevice/Cargo.toml" || cat >> "$ROOT/vendor/idevice/Cargo.toml" <<'TOML'

[patch.crates-io]
idevice = { path = "idevice" }
isideload = { path = "../isideload" }
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
