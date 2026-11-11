import Foundation

/// A certificate tested as revoked or expired from the test actions (#20).
/// It's applied where the real checks get their answers, so everything
/// after them runs as it would for a real revocation or expiry: Test Revoked
/// answers the revocation check, and Test Expired moves the certificate's
/// end date, which every expiry check reads.
struct CertificateTest: Codable, Equatable {
	enum Kind: String, Codable {
		case revoked, expired
	}

	var kind: Kind
	/// When the test started, which is when the certificate was revoked or
	/// ran out.
	var since: Date
}
