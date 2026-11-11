#!/bin/bash
# Builds the certificate page's signer (#152), public/zsign.js and
# public/zsign.wasm: zsign from the fork Atelier signs with, called through
# signer.cpp, and OpenSSL's libcrypto, compiled to WebAssembly with
# Emscripten. Both files are committed, as the site deploys without a build
# step, so run this after changing signer.cpp or anything pinned below.
#
#   infra/website/wasm/build.sh [work folder, .build by default]
#
# It needs git, curl, python3, perl and make. The same pins build the same
# files, wherever the work folder is.
set -euo pipefail

EMSDK_VERSION=4.0.15
OPENSSL_VERSION=3.6.5
OPENSSL_SHA256=a2157c2830efdec3788939b00c9b0638306d3f0bbb76dc4832ee503bb397df98
# The fork and commit Atelier signs with (Packages/AtelierKit/Package.swift).
ZSIGN_REPOSITORY=https://github.com/atelierstore/Zsign-Package
ZSIGN_COMMIT=75918072c9660f37ac911627ef8332f92ba08eb3

here=$(cd "$(dirname "$0")" && pwd)
work=${1:-$here/.build}
mkdir -p "$work"
work=$(cd "$work" && pwd)
cd "$work"

# Emscripten.
[ -d emsdk ] || git clone -q https://github.com/emscripten-core/emsdk.git
./emsdk/emsdk install "$EMSDK_VERSION" >/dev/null
./emsdk/emsdk activate "$EMSDK_VERSION" >/dev/null
# shellcheck source=/dev/null
source ./emsdk/emsdk_env.sh >/dev/null 2>&1

# OpenSSL's libcrypto: static, without assembly, threads or sockets, and
# with the legacy provider built in, for .p12 files encrypted with RC2. It's
# used from where it's built, and keeps OpenSSL's default folders, so no
# path of this machine's goes in.
openssl=$work/openssl-$OPENSSL_VERSION
if [ ! -f "$openssl/libcrypto.a" ]; then
	curl -fsSL -o openssl.tar.gz "https://github.com/openssl/openssl/releases/download/openssl-$OPENSSL_VERSION/openssl-$OPENSSL_VERSION.tar.gz"
	echo "$OPENSSL_SHA256  openssl.tar.gz" | sha256sum -c - >/dev/null
	rm -rf "$openssl"
	tar xzf openssl.tar.gz
	(
		cd "$openssl"
		emconfigure ./Configure linux-generic32 \
			no-asm no-threads no-shared no-dso no-module no-sock no-afalgeng no-engine \
			no-ui-console no-tests no-docs no-apps no-secure-memory no-async no-autoload-config \
			-Os >/dev/null
		# Emscripten's ar and ranlib, not a cross compiler's.
		sed -i 's|^CROSS_COMPILE=.*|CROSS_COMPILE=|' Makefile
		emmake make -j"$(nproc)" build_generated libcrypto.a >/dev/null
	)
fi

# zsign at that commit, with one change for Emscripten
# (zsign-emscripten.patch: its munmap writes files back through the
# descriptor they were mapped with, which zsign closes straight away).
rm -rf zsign
git init -q zsign
git -C zsign fetch -q --depth 1 "$ZSIGN_REPOSITORY" "$ZSIGN_COMMIT"
git -C zsign checkout -q FETCH_HEAD
git -C zsign apply "$here/zsign-emscripten.patch"

# DYNAMIC_EXECUTION=0: no eval, so the page's CSP needs only
# 'wasm-unsafe-eval'. Node is in ENVIRONMENT for the tests. The prefix map
# names signer.cpp as wasm/signer.cpp where OpenSSL's macros name it.
cd zsign
em++ -std=c++17 -Os -Wno-format -Wno-deprecated-declarations \
	-ffile-prefix-map="$here"=wasm \
	-Isrc -Isrc/common -I"$openssl/include" \
	src/archo.cpp src/bundle.cpp src/macho.cpp src/openssl.cpp src/signing.cpp \
	src/common/base64.cpp src/common/fs.cpp src/common/json.cpp src/common/log.cpp \
	src/common/sha.cpp src/common/timer.cpp src/common/util.cpp \
	"$here/signer.cpp" "$openssl/libcrypto.a" \
	-o "$work/zsign.js" \
	-sMODULARIZE=1 -sEXPORT_ES6=1 -sEXPORT_NAME=createSigner \
	-sENVIRONMENT=web,worker,node -sDYNAMIC_EXECUTION=0 \
	-sALLOW_MEMORY_GROWTH=1 -sMAXIMUM_MEMORY=2GB -sFORCE_FILESYSTEM=1 \
	-sEXPORTED_FUNCTIONS=_atelier_open_p12,_atelier_sign \
	-sEXPORTED_RUNTIME_METHODS=FS,ccall

install -m 644 "$work/zsign.js" "$work/zsign.wasm" "$here/../public/"
echo "Built public/zsign.js and public/zsign.wasm."
