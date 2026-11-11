#!/bin/sh
# Regenerates the OCSP test fixtures in ./Fixtures/ocsp: two throwaway CAs
# shaped like Apple's WWDR intermediates (RSA, and ECDSA P-384 like G6), leaf
# certificates that point at an OCSP responder the way Apple's do, and that
# responder's answers. Nothing here is a real Apple certificate.
#
# For each CA (rsa, ec):
#   <ca>-ca.der                the CA, trusted by the tests
#   <ca>-good.der, -revoked.der, -unknown.der   leaf certificates
#   <ca>-good.ocsp, ...        the responder's answer about each, signed by a
#                              delegated responder certificate (OCSP Signing)
#   <ca>-direct.ocsp           the answer about -good, signed by the CA itself
# And:
#   rsa-forged.ocsp            the answer about rsa-good, signed by a responder
#                              from another CA
#   rsa-ca-only-responder.ocsp the answer about rsa-good, signed by a cert the
#                              CA issued without OCSP Signing
#   rsa-good.req               openssl's request about rsa-good, which
#                              Atelier's must match byte for byte
#
# Responses are valid for 7 days from when this script ran; the tests check
# them at their own thisUpdate, so they don't go stale.
set -eu
cd "$(dirname "$0")"
out=Fixtures/ocsp
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
rm -rf "$out"
mkdir -p "$out"

cat > "$work/ext.cnf" <<-CNF
[ca]
basicConstraints = critical, CA:true
keyUsage = critical, keyCertSign, cRLSign
subjectKeyIdentifier = hash
[leaf]
basicConstraints = critical, CA:false
keyUsage = critical, digitalSignature
extendedKeyUsage = codeSigning
subjectKeyIdentifier = hash
authorityKeyIdentifier = keyid
authorityInfoAccess = OCSP;URI:http://ocsp.ownstore.test/ocsp03-test, caIssuers;URI:http://certs.ownstore.test/test.der
[responder]
basicConstraints = critical, CA:false
keyUsage = critical, digitalSignature
extendedKeyUsage = OCSPSigning
subjectKeyIdentifier = hash
authorityKeyIdentifier = keyid
[plain]
basicConstraints = critical, CA:false
keyUsage = critical, digitalSignature
subjectKeyIdentifier = hash
authorityKeyIdentifier = keyid
CNF

key() { # file kind
	if [ "$2" = ec ]; then
		openssl ecparam -name secp384r1 -genkey -noout -out "$1"
	else
		openssl genrsa -out "$1" 2048 2>/dev/null
	fi
}

cert() { # ca name subject extensions
	key "$work/$1-$2.key" "$1"
	openssl req -new -key "$work/$1-$2.key" -subj "$3" -out "$work/$1-$2.csr"
	openssl x509 -req -in "$work/$1-$2.csr" -CA "$work/$1-ca.pem" -CAkey "$work/$1-ca.key" \
		-set_serial "0x$(openssl rand -hex 16)" -days 3650 -sha256 \
		-extfile "$work/ext.cnf" -extensions "$4" -out "$work/$1-$2.pem" 2>/dev/null
}

respond() { # ca leaf signer output
	openssl ocsp -issuer "$work/$1-ca.pem" -cert "$work/$1-$2.pem" -no_nonce -reqout "$work/req.der" >/dev/null
	openssl ocsp -index "$work/$1-index.txt" -CA "$work/$1-ca.pem" \
		-rsigner "$work/$3.pem" -rkey "$work/$3.key" -rmd sha256 \
		-reqin "$work/req.der" -respout "$out/$4.ocsp" -ndays 7 >/dev/null 2>&1
}

index_line() { # status ca leaf [revoked-at]
	serial=$(openssl x509 -in "$work/$2-$3.pem" -noout -serial | cut -d= -f2)
	subject=$(openssl x509 -in "$work/$2-$3.pem" -noout -subject -nameopt compat | cut -d= -f2-)
	expiry=$(date -u -d "+3650 days" +%y%m%d%H%M%SZ)
	printf '%s\t%s\t%s\t%s\tunknown\t%s\n' "$1" "$expiry" "${4:-}" "$serial" "$subject"
}

for ca in rsa ec; do
	key "$work/$ca-ca.key" "$ca"
	openssl req -x509 -new -key "$work/$ca-ca.key" -days 3650 -sha256 \
		-subj "/CN=OwnStore Test Developer Relations CA/OU=$ca/O=OwnStore Tests/C=US" \
		-extensions ca -config "$work/ext.cnf" -out "$work/$ca-ca.pem" 2>/dev/null || \
	openssl req -x509 -new -key "$work/$ca-ca.key" -days 3650 -sha256 \
		-subj "/CN=OwnStore Test Developer Relations CA/OU=$ca/O=OwnStore Tests/C=US" \
		-addext "basicConstraints=critical,CA:true" -addext "keyUsage=critical,keyCertSign,cRLSign" \
		-addext "subjectKeyIdentifier=hash" -out "$work/$ca-ca.pem"
	for leaf in good revoked unknown; do
		cert "$ca" "$leaf" "/UID=TESTTEAM01/CN=iPhone Distribution: OwnStore Test $leaf (TESTTEAM01)/OU=TESTTEAM01/O=OwnStore Test/C=US" leaf
	done
	cert "$ca" responder "/CN=OwnStore Test OCSP Responder/O=OwnStore Tests/C=US" responder
	{
		index_line V "$ca" good
		index_line R "$ca" revoked "$(date -u -d '-2 days' +%y%m%d%H%M%SZ),keyCompromise"
	} > "$work/$ca-index.txt"
	for leaf in good revoked unknown; do
		respond "$ca" "$leaf" "$ca-responder" "$ca-$leaf"
	done
	respond "$ca" good "$ca-ca" "$ca-direct"
	for name in ca good revoked unknown; do
		openssl x509 -in "$work/$ca-$name.pem" -outform DER -out "$out/$ca-$name.der"
	done
done

openssl ocsp -issuer "$work/rsa-ca.pem" -cert "$work/rsa-good.pem" -no_nonce -reqout "$out/rsa-good.req" >/dev/null

# A responder from the ec CA answering about an rsa certificate.
respond rsa good ec-responder rsa-forged
# A certificate from the right CA, but not allowed to sign OCSP responses.
cert rsa plain "/CN=OwnStore Test Not A Responder/O=OwnStore Tests/C=US" plain
respond rsa good rsa-plain rsa-ca-only-responder

for file in "$out"/*.ocsp; do
	printf '%s: ' "$(basename "$file")"
	openssl ocsp -respin "$file" -resp_text -noverify 2>/dev/null | grep -m1 'Cert Status' | sed 's/^ *//'
done
