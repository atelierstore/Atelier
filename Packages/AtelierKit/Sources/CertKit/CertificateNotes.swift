import Foundation
import InstallKit

/// What Atelier tells the user about a certificate: what it can't sign,
/// and what the device needs before apps signed with it will open.
public struct CertificateNote: Equatable, Sendable {
	public enum Severity: Int, Comparable, Sendable {
		/// Something Atelier checked and found fine.
		case ok, info, warning, problem

		public static func < (a: Self, b: Self) -> Bool { a.rawValue < b.rawValue }
	}

	public enum Kind: Equatable, Sendable {
		case revoked
		case certificateExpired
		case profileExpired
		case expiringSoon
		case appStoreProfile
		case deviceNotInProfile
		case deviceUnknown
		case deviceInProfile
		case developerModeNeeded
		case developerModeOn
		case developerModeOff
	}

	public var kind: Kind
	public var severity: Severity
	public var message: String
}

extension StoredCertificate {
	/// Notes in order of severity, problems first. `deviceUDID` and
	/// `developerModeOn` come from route A (#9) once it has read them, nil
	/// otherwise; without a UDID, a confirmed install (`deviceConfirmedAt`)
	/// is what shows this device is in the profile (#45). `device` names it
	/// in the messages: "iPhone" or "iPad" (#61).
	public func notes(now: Date = .now, deviceUDID: String? = nil, developerModeOn: Bool? = nil, device: String = ThisDevice.name) -> [CertificateNote] {
		var notes: [CertificateNote] = []
		func add(_ kind: CertificateNote.Kind, _ severity: CertificateNote.Severity, _ message: String) {
			notes.append(CertificateNote(kind: kind, severity: severity, message: message))
		}

		if case .revoked(let date) = revocation?.status {
			let when = date.map { " on \($0.formatted(date: .abbreviated, time: .omitted))" } ?? ""
			add(.revoked, .problem, "Apple revoked this certificate\(when). Apps signed with it won't open. Re-sign them with another certificate in the Library.")
		}
		// The certificate or its profile, said once: people think of them
		// as one, and the details list both dates.
		if certificate.notAfter <= now {
			add(.certificateExpired, .problem, "This certificate has expired. Apps signed with it won't open.")
		} else if profile.expirationDate <= now {
			add(.profileExpired, .problem, "This certificate has expired. Apps signed with it won't open.")
		}
		let expiry = self.expiry
		if !expiry.isExpired(now: now), expiry.warning(now: now) != nil {
			let left = expiry.daysLeft(now: now)
			let days = left == 1 ? "within a day" : "in \(left) days"
			add(.expiringSoon, .warning, "This certificate expires \(days), on \(expiry.date.formatted(date: .abbreviated, time: .omitted)). Apps signed with it stop opening then.")
		}

		switch profile.check(deviceUDID: deviceUDID) {
		case .noDevices:
			add(.appStoreProfile, .problem, "This certificate can only sign apps for the App Store and TestFlight, not for this \(device).")
		case .notIncluded:
			add(.deviceNotInProfile, .problem, "This certificate isn't registered for this \(device), so apps signed with it won't install here.")
		case .included:
			add(.deviceInProfile, .ok, "Registered for this \(device).")
		case .unknown:
			if deviceConfirmedAt != nil {
				add(.deviceInProfile, .ok, "Registered for this \(device).")
				break
			}
			// iOS doesn't let apps read the device ID; the setup can (#9).
			add(.deviceUnknown, .info, "Atelier can't check yet whether this certificate is registered for this \(device). If it isn't, installs will fail. Finishing the setup lets it check.")
		case .anyDevice:
			break
		}

		switch profile.kind {
		// Development: Apple's rule. Ad hoc: seen on iOS 27.0.1, where apps signed
		// with a Signulous distribution profile wouldn't open with Developer
		// Mode off (2026-10-18). Enterprise apps don't need it (Apple, WWDC22).
		case .development, .adHoc:
			switch developerModeOn {
			case true?:
				add(.developerModeOn, .ok, "Developer Mode is on, as apps signed with this certificate need.")
			case false?:
				add(.developerModeOff, .problem, "Developer Mode is off, so apps signed with this certificate won't open. Turn it on in Settings › Privacy & Security › Developer Mode.")
			case nil:
				add(.developerModeNeeded, .info, "Apps signed with this certificate only open with Developer Mode on (Settings › Privacy & Security › Developer Mode).")
			}
		case .enterprise, .appStore:
			break
		}

		return notes.sorted { $0.severity > $1.severity }
	}
}
