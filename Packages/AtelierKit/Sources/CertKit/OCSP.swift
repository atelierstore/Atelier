import Foundation
import InstallKit
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
#if canImport(Security)
import Security
#endif

/// What Apple's OCSP responder says about a certificate (#5).
public enum RevocationStatus: Codable, Equatable, Sendable {
	/// Not revoked, as of the responder's answer.
	case good
	/// Revoked: every app signed with it stops opening.
	case revoked(at: Date?)
	/// The responder doesn't know the certificate.
	case unknown
}

public enum RevocationCheckError: Swift.Error, Equatable, Sendable, CustomStringConvertible {
	/// The certificate doesn't say where to ask.
	case noResponder
	/// Not issued by one of Apple's developer CAs, so there's nothing to
	/// check the answer against.
	case unknownIssuer(String)
	/// The responder answered with an error status (RFC 6960 OCSPResponseStatus).
	case responderError(Int)
	case httpStatus(Int)
	case network(String)
	case malformedResponse
	/// The answer isn't signed by the issuer or a responder it authorized.
	case badSignature
	/// The answer is about another certificate.
	case notAboutThisCertificate
	/// The answer is out of date, or from the future: often the device's clock.
	case stale
	/// Checking signatures needs Apple's Security framework.
	case unsupportedPlatform

	public var description: String {
		switch self {
		case .noResponder: "Apple can't be asked about this certificate."
		case .unknownIssuer: "This certificate wasn't issued by Apple, so Atelier can't check it."
		case .responderError, .httpStatus: "Apple didn't answer. Atelier asks again later."
		case .network(let message): "Couldn't reach Apple: \(message)"
		case .malformedResponse: "Apple's answer couldn't be read."
		case .badSignature: "The answer wasn't signed by Apple, so Atelier ignored it."
		case .notAboutThisCertificate: "The answer was about another certificate."
		case .stale: "The answer is out of date. Check the \(ThisDevice.name)'s date and time."
		case .unsupportedPlatform: "Revocation checks need iOS or macOS."
		}
	}
}

/// Asks a certificate's OCSP responder whether it's revoked, and checks the
/// answer is signed by the certificate's issuer, or by a responder the
/// issuer authorized. Apple's responders only answer over plain HTTP, so the
/// signature is what makes the answer trustworthy.
public struct RevocationChecker: Sendable {
	/// Sends the request and returns the body and HTTP status.
	public typealias Transport = @Sendable (URLRequest) async throws -> (Data, Int)

	/// DER certificates of the CAs whose certificates can be checked.
	public let trustedIssuers: [Data]
	private let transport: Transport

	public init(trustedIssuers: [Data] = AppleDeveloperCAs.certificates, transport: Transport? = nil) {
		self.trustedIssuers = trustedIssuers
		self.transport = transport ?? { request in
			let (data, response) = try await URLSession.shared.data(for: request)
			return (data, (response as? HTTPURLResponse)?.statusCode ?? 0)
		}
	}

	public func check(_ certificate: SigningCertificate, now: Date = .now) async throws -> RevocationStatus {
		guard let leaf = try? X509Certificate(der: certificate.der) else { throw RevocationCheckError.malformedResponse }
		let issuer = try issuer(of: leaf)
		guard let url = leaf.ocspURL else { throw RevocationCheckError.noResponder }

		var request = URLRequest(url: url, timeoutInterval: 30)
		request.httpMethod = "POST"
		request.setValue("application/ocsp-request", forHTTPHeaderField: "Content-Type")
		request.setValue("application/ocsp-response", forHTTPHeaderField: "Accept")
		request.httpBody = Data(try OCSPRequest.body(for: leaf, issuer: issuer))

		let data: Data, status: Int
		do {
			(data, status) = try await transport(request)
		} catch is CancellationError {
			throw CancellationError()
		} catch {
			throw RevocationCheckError.network(error.localizedDescription)
		}
		guard status == 200 else { throw RevocationCheckError.httpStatus(status) }
		return try OCSPResponse(der: data).status(of: leaf, issuer: issuer, now: now)
	}

	/// The trusted CA that issued `leaf`, by its key ID or else its name.
	func issuer(of leaf: X509Certificate) throws -> X509Certificate {
		let issuers = trustedIssuers.compactMap { try? X509Certificate(der: $0) }
		if let keyID = leaf.authorityKeyIdentifier,
		   let issuer = issuers.first(where: { ($0.subjectKeyIdentifier ?? $0.publicKeyHash) == keyID }) {
			return issuer
		}
		if let issuer = issuers.first(where: { $0.subject.encoded.elementsEqual(leaf.issuer.encoded) }) {
			return issuer
		}
		throw RevocationCheckError.unknownIssuer(X509Certificate.attributes(of: leaf.issuer)["2.5.4.3"] ?? "unnamed")
	}
}

/// An OCSP request about one certificate (RFC 6960 4.1), without a nonce:
/// Apple's responders send cached answers and ignore nonces.
enum OCSPRequest {
	static let sha1OID = "1.3.14.3.2.26"

	static func body(for leaf: X509Certificate, issuer: X509Certificate) throws -> [UInt8] {
		guard let keyHash = issuer.publicKeyHash else { throw RevocationCheckError.malformedResponse }
		// CertID ::= SEQUENCE { hashAlgorithm, issuerNameHash, issuerKeyHash, serialNumber }
		let certID = DER.sequence(
			DER.sequence(DER.objectIdentifier(sha1OID), DER.null),
			DER.octetString(SHA1.hash(leaf.issuer.encoded)),
			DER.octetString(keyHash),
			DER.integer(leaf.serial)
		)
		// OCSPRequest ::= SEQUENCE { tbsRequest SEQUENCE { requestList SEQUENCE OF Request SEQUENCE { reqCert } } }
		return DER.sequence(DER.sequence(DER.sequence(DER.sequence(certID))))
	}
}

/// A responder's answer (RFC 6960 4.2), as far as checking one certificate
/// needs.
struct OCSPResponse {
	struct Single {
		var issuerNameHash: [UInt8]
		var issuerKeyHash: [UInt8]
		var serial: [UInt8]
		var status: RevocationStatus
		var thisUpdate: Date
		var nextUpdate: Date?
	}

	/// ResponseData, as encoded: what the signature covers.
	let responseData: ASN1Node
	let singles: [Single]
	let signatureAlgorithm: String
	let signature: [UInt8]
	/// Certificates sent with the answer: usually the responder's.
	let certificates: [X509Certificate]

	static let basicResponseOID = "1.3.6.1.5.5.7.48.1.1"

	init(der: Data) throws {
		// OCSPResponse ::= SEQUENCE { responseStatus ENUMERATED,
		//   responseBytes [0] EXPLICIT SEQUENCE { responseType OID, response OCTET STRING } OPTIONAL }
		guard
			let response = try? ASN1Node.parse(der), response.tag == ASN1Node.sequence,
			let status = response[0], status.tag == ASN1Node.enumerated, status.content.count == 1
		else { throw RevocationCheckError.malformedResponse }
		guard status.content[0] == 0 else { throw RevocationCheckError.responderError(Int(status.content[0])) }
		guard
			let bytes = response[1]?[0],
			bytes[0]?.objectIdentifier == Self.basicResponseOID,
			let inner = bytes[1], inner.tag == ASN1Node.octetString,
			let basic = try? ASN1Node.parse(inner.content), basic.tag == ASN1Node.sequence,
			// BasicOCSPResponse ::= SEQUENCE { tbsResponseData, signatureAlgorithm,
			//   signature BIT STRING, certs [0] EXPLICIT SEQUENCE OF Certificate OPTIONAL }
			let data = basic[0], data.tag == ASN1Node.sequence,
			let algorithm = basic[1]?[0]?.objectIdentifier,
			let signature = basic[2]?.bits
		else { throw RevocationCheckError.malformedResponse }

		// ResponseData ::= SEQUENCE { version [0] EXPLICIT DEFAULT v1, responderID,
		//   producedAt, responses SEQUENCE OF SingleResponse, responseExtensions [1] OPTIONAL }
		var fields = data.children[...]
		if fields.first?.tag == ASN1Node.contextSpecific(0) { fields = fields.dropFirst() }
		let parts = Array(fields)
		guard parts.count >= 3, parts[2].tag == ASN1Node.sequence else { throw RevocationCheckError.malformedResponse }

		self.responseData = data
		self.singles = try parts[2].children.map(Self.single)
		self.signatureAlgorithm = algorithm
		self.signature = signature
		if let certs = basic.children.first(where: { $0.tag == ASN1Node.contextSpecific(0) })?[0] {
			self.certificates = certs.children.compactMap { try? X509Certificate(node: $0) }
		} else {
			self.certificates = []
		}
	}

	private static func single(_ node: ASN1Node) throws -> Single {
		// SingleResponse ::= SEQUENCE { certID, certStatus, thisUpdate GeneralizedTime,
		//   nextUpdate [0] EXPLICIT GeneralizedTime OPTIONAL, singleExtensions [1] OPTIONAL }
		// CertStatus ::= CHOICE { good [0] IMPLICIT NULL,
		//   revoked [1] IMPLICIT SEQUENCE { revocationTime, revocationReason [0] OPTIONAL },
		//   unknown [2] IMPLICIT NULL }
		guard
			let certID = node[0], certID.children.count == 4,
			let nameHash = certID[1]?.content, let keyHash = certID[2]?.content, let serial = certID[3]?.content,
			let certStatus = node[1],
			let thisUpdate = node[2]?.date
		else { throw RevocationCheckError.malformedResponse }

		let status: RevocationStatus
		switch certStatus.tag {
		case 0x80: status = .good
		case 0xA1: status = .revoked(at: certStatus[0]?.date)
		case 0x82: status = .unknown
		default: throw RevocationCheckError.malformedResponse
		}
		let nextUpdate = node.children.first { $0.tag == ASN1Node.contextSpecific(0) }?[0]?.date
		return Single(issuerNameHash: nameHash, issuerKeyHash: keyHash, serial: serial, status: status, thisUpdate: thisUpdate, nextUpdate: nextUpdate)
	}

	/// How far the device's clock may be from the responder's.
	static let clockSkew: TimeInterval = 5 * 60

	/// The status of `leaf`, once the answer is shown to be current and to
	/// come from `issuer`. Currency comes first: a wrong device clock also
	/// makes the responder's certificate look invalid, and "stale" says
	/// what's wrong.
	func status(of leaf: X509Certificate, issuer: X509Certificate, now: Date) throws -> RevocationStatus {
		guard let keyHash = issuer.publicKeyHash else { throw RevocationCheckError.malformedResponse }
		let nameHash = SHA1.hash(leaf.issuer.encoded)
		guard let single = singles.first(where: {
			$0.serial == leaf.serial && $0.issuerKeyHash == keyHash && $0.issuerNameHash == nameHash
		}) else { throw RevocationCheckError.notAboutThisCertificate }
		guard single.thisUpdate <= now + Self.clockSkew else { throw RevocationCheckError.stale }
		if let next = single.nextUpdate, next < now - Self.clockSkew { throw RevocationCheckError.stale }
		try verify(issuer: issuer, now: now)
		return single.status
	}

	/// Checks the answer is signed by the issuer itself, or by a certificate
	/// the issuer signed for OCSP Signing that's valid now.
	func verify(issuer: X509Certificate, now: Date) throws {
		let message = Array(responseData.encoded)
		if try Signature.verify(signature, of: message, algorithm: signatureAlgorithm, key: issuer.publicKeyInfo) {
			return
		}
		for responder in certificates
		where responder.issuer.encoded.elementsEqual(issuer.subject.encoded)
			&& responder.extendedKeyUsages.contains(X509Certificate.ocspSigningOID)
			&& responder.notBefore <= now + Self.clockSkew && now - Self.clockSkew <= responder.notAfter {
			guard
				try Signature.verify(responder.signature, of: Array(responder.tbs.encoded), algorithm: responder.signatureAlgorithm, key: issuer.publicKeyInfo),
				try Signature.verify(signature, of: message, algorithm: signatureAlgorithm, key: responder.publicKeyInfo)
			else { continue }
			return
		}
		throw RevocationCheckError.badSignature
	}
}

/// RSA (PKCS #1 v1.5) and ECDSA signature checks through Security.
enum Signature {
	/// False for a signature that doesn't match or an algorithm Atelier
	/// doesn't know.
	static func verify(_ signature: [UInt8], of message: [UInt8], algorithm: String, key publicKeyInfo: ASN1Node) throws -> Bool {
		#if canImport(Security)
		// SubjectPublicKeyInfo ::= SEQUENCE { algorithm AlgorithmIdentifier, subjectPublicKey BIT STRING }
		guard let keyType = publicKeyInfo[0]?[0]?.objectIdentifier, let keyBytes = publicKeyInfo[1]?.bits else { return false }
		var attributes: [CFString: Any] = [kSecAttrKeyClass: kSecAttrKeyClassPublic]
		let secAlgorithm: SecKeyAlgorithm
		switch (keyType, algorithm) {
		case ("1.2.840.113549.1.1.1", "1.2.840.113549.1.1.5"): secAlgorithm = .rsaSignatureMessagePKCS1v15SHA1
		case ("1.2.840.113549.1.1.1", "1.2.840.113549.1.1.11"): secAlgorithm = .rsaSignatureMessagePKCS1v15SHA256
		case ("1.2.840.113549.1.1.1", "1.2.840.113549.1.1.12"): secAlgorithm = .rsaSignatureMessagePKCS1v15SHA384
		case ("1.2.840.113549.1.1.1", "1.2.840.113549.1.1.13"): secAlgorithm = .rsaSignatureMessagePKCS1v15SHA512
		case ("1.2.840.10045.2.1", "1.2.840.10045.4.3.2"): secAlgorithm = .ecdsaSignatureMessageX962SHA256
		case ("1.2.840.10045.2.1", "1.2.840.10045.4.3.3"): secAlgorithm = .ecdsaSignatureMessageX962SHA384
		case ("1.2.840.10045.2.1", "1.2.840.10045.4.3.4"): secAlgorithm = .ecdsaSignatureMessageX962SHA512
		default: return false
		}
		if keyType == "1.2.840.10045.2.1" {
			// An uncompressed point: 04, then x and y.
			attributes[kSecAttrKeyType] = kSecAttrKeyTypeECSECPrimeRandom
			attributes[kSecAttrKeySizeInBits] = (keyBytes.count - 1) / 2 * 8
		} else {
			attributes[kSecAttrKeyType] = kSecAttrKeyTypeRSA
		}
		guard let key = SecKeyCreateWithData(Data(keyBytes) as CFData, attributes as CFDictionary, nil) else { return false }
		return SecKeyVerifySignature(key, secAlgorithm, Data(message) as CFData, Data(signature) as CFData, nil)
		#else
		throw RevocationCheckError.unsupportedPlatform
		#endif
	}
}
