#!/bin/sh
# Fetches idevice (MIT, https://github.com/jkcoxson/idevice) at the pinned
# release into vendor/idevice. The pairing host's tests build against it, and
# build-rust.sh compiles it into IDevice.xcframework with Atelier's modules
# added. The same release the install spike installed and paired with on
# iOS 27.0.1, without the spike's round 7 responder fork.
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
