// The certificate page's signer (#152): zsign, from the fork Atelier signs
// with, called as Atelier calls it (ZsignEngine, through the fork's zsign()
// in swift/zsign.mm), for an app in Emscripten's in-memory file system.
// build.sh compiles it to WebAssembly with zsign and OpenSSL's libcrypto.

#include <emscripten/emscripten.h>
#include <openssl/err.h>
#include <openssl/pkcs12.h>
#include <openssl/provider.h>
#include <openssl/x509.h>

#include <cstdio>
#include <string>
#include <vector>

#include "bundle.h"
#include "openssl.h"

using namespace std;

// Loaded once, before anything else uses OpenSSL: loading one provider by
// hand stops the default one loading by itself, and .p12 files made with
// -legacy (RC2) need the legacy one.
static void loadProviders() {
	static bool loaded = false;
	if (loaded) return;
	OSSL_PROVIDER_load(nullptr, "default");
	OSSL_PROVIDER_load(nullptr, "legacy");
	loaded = true;
}

extern "C" {

// What atelier_open_p12 answers.
enum {
	P12_OPENED = 0,
	P12_UNREADABLE = 1,
	P12_WRONG_PASSWORD = 2,
	P12_NO_IDENTITY = 3,
};

// Opens the .p12 at `p12` with `password` and writes its certificate's DER
// to `certificateOut`, for the page's checks before it signs anything.
EMSCRIPTEN_KEEPALIVE int atelier_open_p12(const char* p12, const char* password, const char* certificateOut) {
	loadProviders();
	BIO* in = BIO_new_file(p12, "rb");
	if (!in) return P12_UNREADABLE;
	PKCS12* pkcs12 = d2i_PKCS12_bio(in, nullptr);
	BIO_free(in);
	if (!pkcs12) return P12_UNREADABLE;

	// A .p12 without a MAC opens with any password, as iOS opens it.
	if (PKCS12_mac_present(pkcs12) && !PKCS12_verify_mac(pkcs12, password, -1)
		&& !(password[0] == '\0' && PKCS12_verify_mac(pkcs12, nullptr, 0))) {
		PKCS12_free(pkcs12);
		return P12_WRONG_PASSWORD;
	}
	EVP_PKEY* key = nullptr;
	X509* certificate = nullptr;
	bool parsed = PKCS12_parse(pkcs12, password, &key, &certificate, nullptr) == 1;
	PKCS12_free(pkcs12);
	ERR_clear_error();
	int result = P12_NO_IDENTITY;
	if (parsed && key && certificate && X509_check_private_key(certificate, key) == 1) {
		unsigned char* der = nullptr;
		int length = i2d_X509(certificate, &der);
		FILE* out = length > 0 ? fopen(certificateOut, "wb") : nullptr;
		if (out) {
			if (fwrite(der, 1, length, out) == (size_t)length) result = P12_OPENED;
			fclose(out);
		}
		OPENSSL_free(der);
	}
	EVP_PKEY_free(key);
	X509_free(certificate);
	return result;
}

// What atelier_sign answers.
enum {
	SIGNED = 0,
	CERTIFICATE_FAILED = 1,
	SIGNING_FAILED = 2,
};

// Signs the app at `app`, a folder, with the .p12 at `p12`, its password
// and the profile at `profile`, keeping the profile in the app as
// embedded.mobileprovision. It signs with the profile's entitlements, which
// is what Atelier's fitting (#7, IPASigner.fitEntitlements) comes to for
// Atelier's own release: its binaries are unsigned, so they ask for none.
EMSCRIPTEN_KEEPALIVE int atelier_sign(const char* app, const char* p12, const char* profile, const char* password) {
	loadProviders();
	ZSignAsset asset;
	if (!asset.Init("", p12, profile, "", password, false, false, false)) return CERTIFICATE_FAILED;
	ZBundle bundle;
	vector<string> noDylibs;
	bool signedApp = bundle.SignFolder(&asset, app, "", "", "", noDylibs, noDylibs, true, false, true, false);
	return signedApp ? SIGNED : SIGNING_FAILED;
}

}
