import Foundation

/// The parts of an X.509 certificate that reading it (#4) and checking its
/// revocation (#5) use, from its DER encoding.
struct X509Certificate {
	/// The signed part, as encoded: what the issuer's signature covers.
	let tbs: ASN1Node
	/// The serial number's INTEGER contents, leading zero kept.
	let serial: [UInt8]
	let issuer: ASN1Node
	let subject: ASN1Node
	let notBefore: Date
	let notAfter: Date
	/// SubjectPublicKeyInfo.
	let publicKeyInfo: ASN1Node
	/// Extension values (the OCTET STRING's contents) by OID.
	let extensions: [String: [UInt8]]
	let signatureAlgorithm: String
	let signature: [UInt8]

	enum Error: Swift.Error, Equatable {
		case invalid
	}

	init(der: Data) throws {
		try self.init(node: ASN1Node.parse(der))
	}

	init(node certificate: ASN1Node) throws {
		// Certificate ::= SEQUENCE { tbsCertificate, signatureAlgorithm, signature }
		guard
			certificate.tag == ASN1Node.sequence,
			let tbs = certificate[0], tbs.tag == ASN1Node.sequence,
			let algorithm = certificate[1]?[0]?.objectIdentifier,
			let signature = certificate[2]?.bits
		else { throw Error.invalid }

		// TBSCertificate ::= SEQUENCE { [0] version OPTIONAL, serialNumber,
		//   signature, issuer, validity, subject, subjectPublicKeyInfo,
		//   [1] issuerUniqueID OPTIONAL, [2] subjectUniqueID OPTIONAL,
		//   [3] extensions OPTIONAL }
		var fields = tbs.children[...]
		if fields.first?.tag == ASN1Node.contextSpecific(0) { fields = fields.dropFirst() }
		let parts = Array(fields)
		guard
			parts.count >= 6,
			parts[0].tag == ASN1Node.integer,
			parts[2].tag == ASN1Node.sequence,
			parts[3].tag == ASN1Node.sequence,
			let notBefore = parts[3][0]?.date,
			let notAfter = parts[3][1]?.date,
			parts[4].tag == ASN1Node.sequence,
			parts[5].tag == ASN1Node.sequence
		else { throw Error.invalid }

		var extensions: [String: [UInt8]] = [:]
		if let list = parts.first(where: { $0.tag == ASN1Node.contextSpecific(3) })?[0] {
			// Extension ::= SEQUENCE { extnID, critical BOOLEAN DEFAULT FALSE, extnValue OCTET STRING }
			for item in list.children {
				guard let oid = item[0]?.objectIdentifier, let value = item.children.last, value.tag == ASN1Node.octetString else { continue }
				extensions[oid] = value.content
			}
		}

		self.tbs = tbs
		self.serial = parts[0].content
		self.issuer = parts[2]
		self.subject = parts[4]
		self.notBefore = notBefore
		self.notAfter = notAfter
		self.publicKeyInfo = parts[5]
		self.extensions = extensions
		self.signatureAlgorithm = algorithm
		self.signature = signature
	}

	/// A Name's attributes by OID; the first value wins.
	static func attributes(of name: ASN1Node) -> [String: String] {
		var result: [String: String] = [:]
		for rdn in name.children {
			for attribute in rdn.children {
				guard let oid = attribute[0]?.objectIdentifier, let value = attribute[1]?.string else { continue }
				if result[oid] == nil { result[oid] = value }
			}
		}
		return result
	}

	// MARK: Extensions

	static let subjectKeyIdentifierOID = "2.5.29.14"
	static let authorityKeyIdentifierOID = "2.5.29.35"
	static let extendedKeyUsageOID = "2.5.29.37"
	static let authorityInfoAccessOID = "1.3.6.1.5.5.7.1.1"
	static let ocspAccessMethodOID = "1.3.6.1.5.5.7.48.1"
	static let ocspSigningOID = "1.3.6.1.5.5.7.3.9"

	/// The key ID of the CA that issued it. Apple's CAs make theirs the SHA-1
	/// of their key, which is what OCSP's issuerKeyHash is.
	var authorityKeyIdentifier: [UInt8]? {
		// AuthorityKeyIdentifier ::= SEQUENCE { keyIdentifier [0] IMPLICIT OCTET STRING OPTIONAL, ... }
		guard let value = extensions[Self.authorityKeyIdentifierOID], let node = try? ASN1Node.parse(value) else { return nil }
		return node.children.first { $0.tag == 0x80 }?.content
	}

	var subjectKeyIdentifier: [UInt8]? {
		guard let value = extensions[Self.subjectKeyIdentifierOID], let node = try? ASN1Node.parse(value), node.tag == ASN1Node.octetString else { return nil }
		return node.content
	}

	/// The SHA-1 of the subject public key, as RFC 5280 defines key IDs.
	var publicKeyHash: [UInt8]? {
		publicKeyInfo[1]?.bits.map { SHA1.hash($0) }
	}

	/// Where its issuer answers OCSP requests about it.
	var ocspURL: URL? {
		// AuthorityInfoAccessSyntax ::= SEQUENCE OF AccessDescription
		// AccessDescription ::= SEQUENCE { accessMethod OID, accessLocation GeneralName }
		guard let value = extensions[Self.authorityInfoAccessOID], let node = try? ASN1Node.parse(value) else { return nil }
		for description in node.children where description[0]?.objectIdentifier == Self.ocspAccessMethodOID {
			// uniformResourceIdentifier [6] IMPLICIT IA5String
			guard let location = description[1], location.tag == 0x86 else { continue }
			if let url = URL(string: String(decoding: location.content, as: UTF8.self)) { return url }
		}
		return nil
	}

	var extendedKeyUsages: [String] {
		guard let value = extensions[Self.extendedKeyUsageOID], let node = try? ASN1Node.parse(value) else { return [] }
		return node.children.compactMap(\.objectIdentifier)
	}
}
