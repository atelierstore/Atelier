#!/bin/sh
# Fetches idevice (MIT, https://github.com/jkcoxson/idevice) at the pinned
# release into vendor/idevice. The pairing host's tests build against it, and
# build-rust.sh compiles it into IDevice.xcframework with Atelier's modules
# added. The same release the install spike installed and paired with on
# iOS 27.0.1, without the spike's round 7 responder fork, and with Atelier's
# change to jktcp, its TCP stack (below).
set -eu

IDEVICE_TAG=v0.1.68
IDEVICE_COMMIT=d32c8189c51c2789496b0768039419c3705498c3

cd "$(dirname "$0")"
if ! { [ -d vendor/idevice/.git ] && [ "$(git -C vendor/idevice rev-parse HEAD)" = "$IDEVICE_COMMIT" ]; }; then
	rm -rf vendor/idevice
	git -c advice.detachedHead=false clone --quiet --depth 1 --branch "$IDEVICE_TAG" https://github.com/jkcoxson/idevice.git vendor/idevice
	actual=$(git -C vendor/idevice rev-parse HEAD)
	if [ "$actual" != "$IDEVICE_COMMIT" ]; then
		echo "idevice $IDEVICE_TAG is $actual, expected $IDEVICE_COMMIT" >&2
		exit 1
	fi
fi

# jktcp (MIT, https://github.com/jkcoxson/jktcp), idevice's TCP stack for the
# tunnel, at a release idevice's own requirement takes, with Atelier's change
# to how it receives: it advertised a 16 MiB window and dropped any segment
# that came after a gap, so one lost segment had the iPhone send all the rest
# again, and a long transfer crawled, at a fraction of its speed, for hours
# (10 Nov 2026). It now advertises 1 MiB and holds those segments until the
# gap is filled: a test backup through the tunnel reached 90 % in 58 minutes
# instead of 4¾ hours. Installs and Find Open Spaces Automatically use the
# same tunnel. build-rust.sh points idevice at it. Idempotent: fetched and
# patched again only when the release or the patch changes.
JKTCP_VERSION=0.1.8
JKTCP_SHA256=f67259b6408391e66f7d7fd3dbef41ef3bc65e1d67f4c8d5512f2e59835f7844
sha256() {
	if command -v sha256sum >/dev/null 2>&1; then sha256sum "$1"; else shasum -a 256 "$1"; fi | cut -d ' ' -f 1
}
JKTCP_PATCH="$(pwd)/src/jktcp-receive-window.patch"
JKTCP_STAMP="$JKTCP_VERSION $(sha256 "$JKTCP_PATCH")"
if [ "$(cat vendor/jktcp/.atelier 2>/dev/null || true)" != "$JKTCP_STAMP" ]; then
	rm -rf vendor/jktcp vendor/jktcp.crate
	mkdir -p vendor/jktcp
	curl -sSfL "https://static.crates.io/crates/jktcp/jktcp-$JKTCP_VERSION.crate" -o vendor/jktcp.crate
	actual=$(sha256 vendor/jktcp.crate)
	if [ "$actual" != "$JKTCP_SHA256" ]; then
		echo "jktcp $JKTCP_VERSION is $actual, expected $JKTCP_SHA256" >&2
		exit 1
	fi
	tar -xzf vendor/jktcp.crate -C vendor/jktcp --strip-components 1
	rm vendor/jktcp.crate
	( cd vendor/jktcp && patch -s -p1 < "$JKTCP_PATCH" )
	echo "$JKTCP_STAMP" > vendor/jktcp/.atelier
fi
