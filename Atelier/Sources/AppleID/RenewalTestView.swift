import AtelierCore
import CertKit
import InstallKit
import SwiftData
import SwiftUI

/// Settings › Test Actions › End an App's Profile (#49): renewing an app
/// without waiting a week. End Profile takes the app's profile off this
/// iPhone, so it stops opening as it does once its profile ended, and
/// Atelier then renews it by itself as it comes back to the front, as it
/// would an app whose profile ended. Renew Now renews one at once.
struct RenewalTestView: View {
	@Environment(CertificatesModel.self) private var certificates
	@Query(sort: \InstallRecord.name) private var installs: [InstallRecord]
	@State private var renewals = ProfileRenewals.shared
	@State private var ending: InstallRecord?
	@State private var busy: String?
	@State private var result: String?

	/// The apps installed with an Apple ID that are on this iPhone.
	private var apps: [(install: InstallRecord, profile: AppProfile)] {
		installs.compactMap { install in
			guard let profile = certificates.appleID(install.certificateID)?.profile(for: install.bundleID),
			      InstallModel.presence(of: install) != .deleted
			else { return nil }
			return (install, profile)
		}
	}

	var body: some View {
		Form {
			Section {
				ForEach(apps, id: \.install.bundleID) { app in
					row(app.install, app.profile)
				}
				if apps.isEmpty {
					Text("No app installed with an Apple ID is on this \(ThisDevice.name).")
						.foregroundStyle(.secondary)
				}
			} footer: {
				Text("End Profile takes the app’s profile off this \(ThisDevice.name), so it stops opening as once its profile ended, and the Library has it under Renew, saying Profile ended. Come back to Atelier with LocalDevVPN connected, and Atelier should renew it by itself within a few seconds. Renew Now renews it at once, connecting LocalDevVPN and asking for Apple’s code if Apple wants it. The Apple ID’s page › Apple ID Log says what each did.")
			}
			if let result {
				Section("Last") {
					Text(result)
				}
			}
		}
		.navigationTitle("End an App’s Profile")
		.navigationBarTitleDisplayMode(.inline)
		.confirmationDialog(
			ending.map { "End \($0.name)’s Profile?" } ?? "",
			isPresented: Binding(get: { ending != nil }, set: { if !$0 { ending = nil } }),
			titleVisibility: .visible,
			presenting: ending
		) { install in
			Button("End Profile", role: .destructive) { end(install) }
		} message: { install in
			Text("\(install.name) stops opening until Atelier renews it, which takes none of your App IDs while its own lasts.")
		}
	}

	private func row(_ install: InstallRecord, _ profile: AppProfile) -> some View {
		HStack(spacing: 12) {
			VStack(alignment: .leading, spacing: 2) {
				Text(install.name)
				Text(status(install, profile))
					.font(.footnote)
					.foregroundStyle(.secondary)
			}
			Spacer(minLength: 8)
			if busy == install.bundleID || renewals.isRenewing(install.bundleID) {
				ProgressView()
			} else {
				Button("End Profile") { ending = install }
					.buttonStyle(.borderless)
					.tint(.red)
				Button("Renew Now") { renew(install) }
					.buttonStyle(.borderless)
			}
		}
		.disabled(busy != nil)
	}

	private func status(_ install: InstallRecord, _ profile: AppProfile) -> String {
		var lines = [profile.expires <= .now ? "Profile ended" : "Profile ends on \(AppProfileDays.describe(profile.expires))"]
		if let renewed = profile.renewedAt { lines.append("Last renewed on \(AppProfileDays.describe(renewed))") }
		if let problem = renewals.problems[install.bundleID] { lines.append(problem.message) }
		return lines.joined(separator: ". ")
	}

	private func end(_ install: InstallRecord) {
		let name = install.name
		let bundleID = install.bundleID
		busy = bundleID
		Task {
			let failure = await renewals.endProfileForTest(bundleID)
			busy = nil
			result = failure.map { "Couldn’t end \(name)’s profile: \($0)" }
				?? "\(name)’s profile is off. Open \(name) from the Home Screen: it shouldn’t open. Then come back to Atelier with LocalDevVPN connected, and it should renew."
		}
	}

	private func renew(_ install: InstallRecord) {
		let name = install.name
		let bundleID = install.bundleID
		busy = bundleID
		Task {
			await renewals.renew([bundleID])
			busy = nil
			if let problem = renewals.problems[bundleID] {
				result = "\(name) wasn’t renewed: \(problem.message)"
			} else if let profile = certificates.appleID(install.certificateID)?.profile(for: bundleID), let renewed = profile.renewedAt, Date.now.timeIntervalSince(renewed) < 120 {
				result = "\(name) renewed: its profile ends on \(AppProfileDays.describe(profile.expires))."
			} else {
				result = "\(name) wasn’t renewed. The log says why."
			}
		}
	}
}
