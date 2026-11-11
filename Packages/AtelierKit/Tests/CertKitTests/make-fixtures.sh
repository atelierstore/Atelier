#!/bin/sh
# Regenerates the CertKit test fixtures in ./Fixtures: two throwaway signing
# certificates (as .p12 files), provisioning profiles of each kind that list
# them, and a ZIP holding one pair. Nothing here is a real Apple certificate.
#
# The profiles are CMS-signed plists like Apple's, signed by a throwaway CA.
# adhoc.mobileprovision is streamed (BER, indefinite lengths), the way Apple
# encodes real profiles; the rest are plain DER.
#
# Regenerating changes every key, serial and date, so CertKitTests.swift's
# expected values must be updated from this script's output afterwards.
set -eu
cd "$(dirname "$0")"
out=Fixtures
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
mkdir -p "$out"

openssl req -x509 -newkey rsa:2048 -nodes -days 7300 \
	-subj "/CN=OwnStore Test Root/O=OwnStore Tests" \
	-keyout "$work/ca.key" -out "$work/ca.pem" 2>/dev/null

leaf() { # name subject
	openssl req -newkey rsa:2048 -nodes -subj "$2" \
		-keyout "$work/$1.key" -out "$work/$1.csr" 2>/dev/null
	openssl x509 -req -in "$work/$1.csr" -CA "$work/ca.pem" -CAkey "$work/ca.key" \
		-set_serial "0x$(openssl rand -hex 8)" -days 3650 -out "$work/$1.pem" 2>/dev/null
	openssl x509 -in "$work/$1.pem" -outform DER -out "$work/$1.der"
	# -legacy: 3DES and a SHA-1 MAC, which every iOS version can import.
	openssl pkcs12 -export -legacy -inkey "$work/$1.key" -in "$work/$1.pem" \
		-name "$1" -passout pass:ownstore -out "$out/$1.p12"
}

leaf signing "/UID=TESTTEAM01/CN=iPhone Distribution: OwnStore Test (TESTTEAM01)/OU=TESTTEAM01/O=OwnStore Test/C=US"
leaf other "/UID=OTHERTEAM2/CN=Apple Development: Someone Else (OTHERTEAM2)/OU=OTHERTEAM2/O=Someone Else/C=GB"

profile() { # file cert devices-xml extra-entitlements-xml app-id stream
	cert=$(base64 -w0 "$work/$2.der")
	cat > "$work/$1.plist" <<-EOF
	<?xml version="1.0" encoding="UTF-8"?>
	<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
	<plist version="1.0">
	<dict>
		<key>AppIDName</key><string>OwnStore Test $1</string>
		<key>ApplicationIdentifierPrefix</key><array><string>TESTTEAM01</string></array>
		<key>CreationDate</key><date>2026-01-01T00:00:00Z</date>
		<key>Platform</key><array><string>iOS</string><string>xrOS</string></array>
		<key>DeveloperCertificates</key><array><data>$cert</data></array>
		<key>Entitlements</key>
		<dict>
			<key>application-identifier</key><string>TESTTEAM01.$5</string>
			<key>com.apple.developer.team-identifier</key><string>TESTTEAM01</string>
			<key>keychain-access-groups</key><array><string>TESTTEAM01.*</string><string>com.apple.token</string></array>
			$4
		</dict>
		<key>ExpirationDate</key><date>2027-01-01T00:00:00Z</date>
		<key>Name</key><string>OwnStore Test $1</string>
		$3
		<key>TeamIdentifier</key><array><string>TESTTEAM01</string></array>
		<key>TeamName</key><string>OwnStore Test</string>
		<key>TimeToLive</key><integer>365</integer>
		<key>UUID</key><string>$(python3 -c 'import uuid; print(str(uuid.uuid4()).upper())')</string>
		<key>Version</key><integer>1</integer>
	</dict>
	</plist>
	EOF
	openssl cms -sign -nodetach -binary $6 -outform DER -md sha256 \
		-signer "$work/ca.pem" -inkey "$work/ca.key" \
		-in "$work/$1.plist" -out "$out/$1.mobileprovision"
}

devices='<key>ProvisionedDevices</key><array><string>00008110-000A1B2C3D4E5F60</string><string>00008120-0011223344556677</string></array>'
profile development signing "$devices" '<key>get-task-allow</key><true/>' '*' ''
profile adhoc signing "$devices" '<key>get-task-allow</key><false/><key>aps-environment</key><string>production</string>' 'com.example.app' -stream
profile enterprise signing '<key>ProvisionsAllDevices</key><true/>' '<key>get-task-allow</key><false/>' '*' ''
profile appstore signing '' '<key>get-task-allow</key><false/>' 'com.example.app' ''
profile mismatched other "$devices" '<key>get-task-allow</key><true/>' '*' ''

rm -f "$out/pair.zip"
mkdir -p "$work/zip/Certificate/__MACOSX"
cp "$out/signing.p12" "$work/zip/Certificate/OwnStore Test.p12"
cp "$out/development.mobileprovision" "$work/zip/Certificate/OwnStore Test.mobileprovision"
printf 'junk' > "$work/zip/Certificate/__MACOSX/._OwnStore Test.p12"
(cd "$work/zip" && zip -qr - Certificate) > "$out/pair.zip"

for name in signing other; do
	echo "== $name"
	openssl x509 -in "$work/$name.pem" -noout -serial -startdate -enddate -subject
done

