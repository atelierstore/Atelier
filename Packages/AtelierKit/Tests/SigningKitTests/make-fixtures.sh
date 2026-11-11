#!/bin/sh
# Regenerates the SigningKit test fixtures in ./Fixtures: a throwaway signing
# certificate (signing.p12, password "ownstore") and a development profile
# that lists it. Nothing here is a real Apple certificate.
#
# zsign only builds a CMS signature for certificates whose issuer name is one
# of Apple's developer CAs, and otherwise leaves the code unsigned. So the
# certificate is issued by a throwaway CA that copies the name of Apple's
# WWDR G3 CA (not its key). zsign then puts Apple's real G3 certificate in
# the signature, and codesign calls it invalid, so ZsignSigningTests only
# asks codesign's verdict when CI provides a real certificate.
set -eu
cd "$(dirname "$0")"
out=Fixtures
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
mkdir -p "$out"

openssl req -x509 -newkey rsa:2048 -nodes -days 7300 \
	-subj "/CN=Apple Worldwide Developer Relations Certification Authority/OU=G3/O=Apple Inc./C=US" \
	-keyout "$work/ca.key" -out "$work/ca.pem" 2>/dev/null
# The name hash zsign looks for (Apple WWDR G3).
test "$(openssl x509 -in "$work/ca.pem" -noout -subject_hash)" = 9b16b75c

openssl req -newkey rsa:2048 -nodes \
	-subj "/UID=TESTTEAM01/CN=iPhone Distribution: OwnStore Test (TESTTEAM01)/OU=TESTTEAM01/O=OwnStore Test/C=US" \
	-keyout "$work/signing.key" -out "$work/signing.csr" 2>/dev/null
cat > "$work/ext.cnf" <<-EOF2
	keyUsage = critical, digitalSignature
	extendedKeyUsage = critical, codeSigning
	EOF2
openssl x509 -req -in "$work/signing.csr" -CA "$work/ca.pem" -CAkey "$work/ca.key" \
	-set_serial "0x$(openssl rand -hex 8)" -days 3650 -extfile "$work/ext.cnf" \
	-out "$work/signing.pem" 2>/dev/null
openssl x509 -in "$work/signing.pem" -outform DER -out "$work/signing.der"
# -legacy: 3DES and a SHA-1 MAC, the way Keychain Access exports.
openssl pkcs12 -export -legacy -inkey "$work/signing.key" -in "$work/signing.pem" \
	-name signing -passout pass:ownstore -out "$out/signing.p12"

cert=$(base64 -w0 "$work/signing.der")
cat > "$work/profile.plist" <<-EOF2
	<?xml version="1.0" encoding="UTF-8"?>
	<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
	<plist version="1.0">
	<dict>
		<key>AppIDName</key><string>OwnStore Test development</string>
		<key>ApplicationIdentifierPrefix</key><array><string>TESTTEAM01</string></array>
		<key>CreationDate</key><date>2026-01-01T00:00:00Z</date>
		<key>Platform</key><array><string>iOS</string></array>
		<key>DeveloperCertificates</key><array><data>$cert</data></array>
		<key>Entitlements</key>
		<dict>
			<key>application-identifier</key><string>TESTTEAM01.*</string>
			<key>com.apple.developer.team-identifier</key><string>TESTTEAM01</string>
			<key>get-task-allow</key><true/>
			<key>keychain-access-groups</key><array><string>TESTTEAM01.*</string></array>
		</dict>
		<key>ExpirationDate</key><date>2036-01-01T00:00:00Z</date>
		<key>Name</key><string>OwnStore Test development</string>
		<key>ProvisionedDevices</key><array><string>00008110-000A1B2C3D4E5F60</string></array>
		<key>TeamIdentifier</key><array><string>TESTTEAM01</string></array>
		<key>TeamName</key><string>OwnStore Test</string>
		<key>TimeToLive</key><integer>3650</integer>
		<key>UUID</key><string>$(python3 -c 'import uuid; print(str(uuid.uuid4()).upper())')</string>
		<key>Version</key><integer>1</integer>
	</dict>
	</plist>
	EOF2
openssl cms -sign -nodetach -binary -outform DER -md sha256 \
	-signer "$work/ca.pem" -inkey "$work/ca.key" \
	-in "$work/profile.plist" -out "$out/development.mobileprovision"
