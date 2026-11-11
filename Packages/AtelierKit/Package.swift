// swift-tools-version: 5.9
import PackageDescription

// Atelier's code outside the app target, one module per concern, so each can
// be unit-tested with `swift test` without building the app. Everything but
// AtelierCore (SwiftData), LoopbackServer (Network) and zsign itself also
// builds on Linux.
let package = Package(
	name: "AtelierKit",
	platforms: [
		.iOS(.v17),
		.macOS(.v14),
	],
	products: [
		.library(name: "SourceKit", targets: ["SourceKit"]),
		.library(name: "CertKit", targets: ["CertKit"]),
		.library(name: "SigningKit", targets: ["SigningKit"]),
		.library(name: "InstallKit", targets: ["InstallKit"]),
		.library(name: "DownloadKit", targets: ["DownloadKit"]),
		.library(name: "GitHubKit", targets: ["GitHubKit"]),
		.library(name: "AppleIDKit", targets: ["AppleIDKit"]),
		.library(name: "AtelierCore", targets: ["AtelierCore"]),
	],
	dependencies: [
		// zsign's Swift package: our fork of the branch Feather builds from
		// (khcrysalis/Zsign-Package, package branch), with fixes so signed
		// apps keep their embedded.mobileprovision and macOS's codesign
		// accepts the signature (atelier branch). Pinned
		// to a revision because the package uses unsafe compiler flags, which
		// SwiftPM only allows in dependencies that aren't pinned to a version.
		.package(url: "https://github.com/atelierstore/Zsign-Package", revision: "75918072c9660f37ac911627ef8332f92ba08eb3"),
		// Unpacking and repacking IPAs, streamed through files rather than memory.
		.package(url: "https://github.com/weichsel/ZIPFoundation", exact: "0.9.20"),
	],
	targets: [
		// Source JSON models, parsing, links and fetching, and update comparison
		// (#12, #13, #18).
		.target(name: "SourceKit"),
		// Certificate and provisioning profile parsing and storage (#4, #5).
		// Uses InstallKit's ZIP reader for certificate ZIPs.
		.target(name: "CertKit", dependencies: ["InstallKit"]),
		// On-device signing through zsign (#6, #7, #8). Uses InstallKit's
		// Info.plist reader for the signed app's details.
		// zsign is Objective-C++ on Apple's OpenSSL build, so it only links on
		// Apple platforms; elsewhere signing throws `.unsupportedPlatform`.
		.target(
			name: "SigningKit",
			dependencies: [
				"CertKit",
				"InstallKit",
				.product(name: "ZIPFoundation", package: "ZIPFoundation"),
				.product(name: "Zsign", package: "Zsign-Package", condition: .when(platforms: [.iOS, .macOS])),
			]
		),
		// Install routes behind one protocol (#9, #10, #11). Holds the IPA
		// reader, loopback server and route B links from the install spike.
		.target(name: "InstallKit"),
		// IPA downloads through a background URLSession, checked against what
		// the source says (#15). Uses InstallKit's ZIP reader to check a
		// download is an app.
		.target(name: "DownloadKit", dependencies: ["SourceKit", "InstallKit"]),
		// GitHub repositories as sources (#30): releases with .ipa assets
		// turned into an AltStore source, reading each IPA's Info.plist and
		// icon with range requests through InstallKit's inflater.
		.target(name: "GitHubKit", dependencies: ["SourceKit", "InstallKit"]),
		// Signing with an Apple ID (#49): the anisette servers to sign in
		// through, from Atelier's worker with a copy built in, the order a
		// sign-in tries them in and when it stops, and the user's own server.
		.target(name: "AppleIDKit", resources: [.copy("anisette.json")]),
		// Persistence (SwiftData), the user's sources (#13) and the download,
		// sign and install pipeline (#16).
		.target(name: "AtelierCore", dependencies: ["SourceKit", "CertKit", "SigningKit", "InstallKit", "GitHubKit"]),

		.testTarget(name: "SourceKitTests", dependencies: ["SourceKit"], resources: [.copy("Fixtures")]),
		.testTarget(
			name: "CertKitTests",
			dependencies: ["CertKit"],
			exclude: ["make-fixtures.sh", "make-ocsp-fixtures.sh"],
			resources: [.copy("Fixtures")]
		),
		.testTarget(
			name: "SigningKitTests",
			dependencies: ["SigningKit", .product(name: "ZIPFoundation", package: "ZIPFoundation")],
			exclude: ["make-fixtures.sh"],
			resources: [.copy("Fixtures")]
		),
		.testTarget(name: "InstallKitTests", dependencies: ["InstallKit"]),
		.testTarget(name: "DownloadKitTests", dependencies: ["DownloadKit", "SourceKit"]),
		.testTarget(name: "GitHubKitTests", dependencies: ["GitHubKit", "SourceKit"]),
		.testTarget(name: "AppleIDKitTests", dependencies: ["AppleIDKit"]),
		.testTarget(name: "AtelierCoreTests", dependencies: ["AtelierCore", "GitHubKit", "SigningKit"]),
	]
)
