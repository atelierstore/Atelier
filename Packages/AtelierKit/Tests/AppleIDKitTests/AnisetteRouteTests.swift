import Foundation
import XCTest
@testable import AppleIDKit

final class AnisetteRouteTests: XCTestCase {
	/// iloader's four, as the worker lists them, then two of SideStore's.
	private let list = AnisetteList(
		updated: "2026-11-02",
		tries: 4,
		clientInfo: nil,
		servers: [
			server("mac-ani", kind: "mac"),
			server("iloader"),
			server("new-sidestore", kind: "mac"),
			server("stikstore"),
			server("sidestore", kind: "other"),
			server("windows", kind: "windows"),
		]
	)

	private static func server(_ name: String, kind: String? = nil) -> AnisetteList.Server {
		AnisetteList.Server(url: URL(string: "https://\(name).example")!, name: name, kind: kind)
	}

	/// The servers a sign-in goes through when each one fails with the
	/// next of `failures`, the same one included when it's tried again.
	private func walk(_ route: inout AnisetteRoute, _ failures: [AnisetteRoute.Failure]) -> [String] {
		var visited: [String] = []
		var server = route.start()
		var failures = failures[...]
		while let current = server {
			visited.append(current.name)
			guard let failure = failures.popFirst() else { break }
			server = route.next(after: failure)
		}
		return visited
	}

	func testStartsWithTheFirstServer() {
		var route = AnisetteRoute(list: list, lastWorked: nil)
		XCTAssertEqual(route.start()?.name, "mac-ani")
		XCTAssertEqual(route.tried.map(\.name), ["mac-ani"])
		XCTAssertFalse(route.isCustom)
	}

	func testStartsWithTheServerThatWorkedLast() {
		var route = AnisetteRoute(list: list, lastWorked: URL(string: "https://STIKSTORE.example"))
		XCTAssertEqual(walk(&route, [.server, .server]), ["stikstore", "mac-ani", "iloader"])
	}

	func testStartsWithTheInstallersServer() {
		// One the list has, before the one that worked last.
		var route = AnisetteRoute(list: list, lastWorked: URL(string: "https://stikstore.example"), first: URL(string: "https://iloader.example"))
		XCTAssertEqual(walk(&route, [.server, .server, .server]), ["iloader", "stikstore", "mac-ani", "new-sidestore"])
		// One it doesn't, as one more.
		route = AnisetteRoute(list: list, lastWorked: nil, first: URL(string: "https://ani.installer.example"))
		XCTAssertEqual(walk(&route, Array(repeating: .server, count: 10)), ["ani.installer.example", "mac-ani", "iloader", "new-sidestore", "stikstore"])
	}

	func testKeepsEachServersStateWhereTheBridgeLooks() {
		// As appleid.rs's anisette_folder, tested with the same two.
		let storage = URL(fileURLWithPath: "/AppleID")
		XCTAssertEqual(AnisetteList.Server(url: URL(string: "https://ani.sidestore.io")!, name: "SideStore").stateFile(in: storage).path, "/AppleID/anisette/ani.sidestore.io/anisette_state")
		XCTAssertEqual(AnisetteList.Server(url: URL(string: "http://192.168.1.20:6969")!, name: "Mine").stateFile(in: storage).path, "/AppleID/anisette/192.168.1.20_6969/anisette_state")
	}

	func testTriesTheListsTriesAtMost() {
		var route = AnisetteRoute(list: list, lastWorked: nil)
		XCTAssertEqual(walk(&route, Array(repeating: .server, count: 10)), ["mac-ani", "iloader", "new-sidestore", "stikstore"])
		XCTAssertEqual(route.tried.count, 4)
		XCTAssertNil(route.next(after: .server))
	}

	func testStopsAtWhatNoServerChanges() {
		var route = AnisetteRoute(list: list, lastWorked: nil)
		XCTAssertEqual(walk(&route, [.final]), ["mac-ani"])
		XCTAssertEqual(route.lastFailure, .final)
	}

	func testTriesTheSameServerOnceMoreAfterTryAgain() {
		var route = AnisetteRoute(list: list, lastWorked: nil)
		XCTAssertEqual(walk(&route, [.tryAgain, .tryAgain, .tryAgain, .server]), ["mac-ani", "mac-ani", "iloader", "iloader", "new-sidestore"])
		// Tried again, a server still counts once.
		XCTAssertEqual(route.tried.map(\.name), ["mac-ani", "iloader", "new-sidestore"])
	}

	func testARefusalGetsTwoMoreServersOfAnotherKind() {
		var route = AnisetteRoute(list: list, lastWorked: nil)
		// Refused through a Mac's: new-sidestore, a Mac's too, is skipped.
		XCTAssertEqual(walk(&route, [.refused, .refused, .refused]), ["mac-ani", "iloader", "stikstore"])
		XCTAssertEqual(route.refusals, 3)
		XCTAssertNil(route.next(after: .refused))
	}

	func testAServerThatWorksAfterARefusal() {
		var route = AnisetteRoute(list: list, lastWorked: nil)
		XCTAssertEqual(walk(&route, [.refused]), ["mac-ani", "iloader"])
		XCTAssertEqual(route.current?.name, "iloader")
		XCTAssertEqual(route.refusals, 1)
	}

	func testOnlyTheUsersOwnServer() {
		var route = AnisetteRoute(custom: URL(string: "http://192.168.1.20:6969")!)
		XCTAssertTrue(route.isCustom)
		XCTAssertEqual(walk(&route, [.tryAgain, .server]), ["192.168.1.20", "192.168.1.20"])
		XCTAssertEqual(route.tried.map(\.url.absoluteString), ["http://192.168.1.20:6969"])
	}

	func testANewListWithOneServer() {
		let one = AnisetteList(updated: "", tries: 4, clientInfo: nil, servers: [Self.server("only")])
		var route = AnisetteRoute(list: one, lastWorked: nil)
		XCTAssertEqual(walk(&route, [.server]), ["only"])
	}

	// MARK: What the user is told

	private func explain(_ error: AppleIDError, after failures: [AnisetteRoute.Failure], custom: Bool = false, appleIDIsSet: Bool = false) -> String? {
		var route = custom ? AnisetteRoute(custom: URL(string: "https://ani.example.com")!) : AnisetteRoute(list: list, lastWorked: nil)
		_ = walk(&route, failures)
		return route.explanation(of: error, appleIDIsSet: appleIDIsSet)
	}

	/// As the bridge words Apple's sign-in refusing a password.
	private static let wrongPassword = AppleIDError(kind: .signIn, appleCode: -22406, message: "Failed to log in to Apple ID: GrandSlam error during proof login request: Auth error -22406: Enter the correct password for this Apple Account.")

	func testExplainsWhyItStopped() {
		XCTAssertEqual(explain(AppleIDError(kind: .signIn, appleCode: -20101, message: ""), after: [.final]), "The Apple ID or password isn’t right. Check both, then sign in again.")
		XCTAssertEqual(explain(Self.wrongPassword, after: [.final]), "The Apple ID or password isn’t right. Check both, then sign in again.")
		XCTAssertEqual(explain(Self.wrongPassword, after: [.final], appleIDIsSet: true), "That isn’t the password for this Apple ID. Type it again.", "Sign In Again only asks for the password")
		XCTAssertNil(explain(AppleIDError(kind: .cancelled, message: ""), after: [.final]))
		XCTAssertEqual(
			explain(AppleIDError(kind: .signIn, appleCode: -80045, message: ""), after: [.refused, .refused, .refused]),
			"Apple isn’t letting apps like Atelier sign in right now. Try again later."
		)
		XCTAssertEqual(
			explain(AppleIDError(kind: .signIn, appleCode: -20283, message: "Failed to log in to Apple ID: GrandSlam error during initial login request: Auth error -20283: Your account can’t be used here."), after: [.server, .server, .server, .server]),
			"Apple didn’t let Atelier sign in. Apple says: “Your account can’t be used here.”",
			"Apple's own sentence, without its code or Atelier's steps"
		)
		XCTAssertEqual(explain(AppleIDError(kind: .signIn, appleCode: -20283, message: ""), after: [.server, .server, .server, .server]), "Apple didn’t let Atelier sign in.")
		XCTAssertEqual(
			explain(AppleIDError(kind: .developer, appleCode: 1100, message: "Failed to list teams: Developer error 1100: Your session has expired."), after: [.final]),
			"Apple’s developer services didn’t accept this Apple ID. Apple says: “Your session has expired.”"
		)
		XCTAssertEqual(
			explain(AppleIDError(kind: .other, message: "timed out"), after: [.server, .server, .server, .server]),
			"Atelier couldn't reach the servers it signs in through. Check your connection, then try again."
		)
		XCTAssertEqual(
			explain(AppleIDError(kind: .other, message: "timed out"), after: [.server], custom: true),
			"Your own sign-in server, ani.example.com, didn't answer. Check that it's running, or turn it off in Settings › Installs › Advanced."
		)
		XCTAssertEqual(
			explain(AppleIDError(kind: .signIn, appleCode: -20283, message: "Auth error -20283: Not here."), after: [.server], custom: true),
			"Apple refused the sign-in through your own sign-in server, ani.example.com. Apple says: “Not here.” Check that it's running, or turn it off in Settings › Installs › Advanced."
		)
		XCTAssertTrue(explain(AppleIDError(kind: .noTeam, message: ""), after: [.final])?.hasPrefix("This Apple ID isn't in a developer team yet.") == true)
	}

	// MARK: Each step with Apple

	func testSaysWhatAppleSaidWithoutItsCode() {
		let refused = AppleIDError(kind: .developer, appleCode: 35, message: "Failed to add development device: Developer error 35: Your development team has reached the maximum number of registered iPhone devices.")
		XCTAssertEqual(refused.applesWords, "Your development team has reached the maximum number of registered iPhone devices.")
		XCTAssertEqual(refused.explained("Apple didn’t register this iPhone"), "Apple didn’t register this iPhone. Apple says: “Your development team has reached the maximum number of registered iPhone devices.”")
		XCTAssertEqual(Self.wrongPassword.applesWords, "Enter the correct password for this Apple Account.")
		XCTAssertNil(AppleIDError(kind: .developer, appleCode: 35, message: "Failed to add development device").applesWords)
		XCTAssertNil(AppleIDError(kind: .developer, appleCode: 35, message: "Developer error 35: ").applesWords)
	}

	func testSaysWhenAppleWasntReached() {
		let unreached = AppleIDError(kind: .other, message: "Failed to send developer request: error sending request for url (https://developerservices2.apple.com/services/QH65B2/ios/downloadTeamProvisioningProfile.action)")
		XCTAssertTrue(unreached.isUnreached)
		XCTAssertEqual(unreached.explained("Apple didn’t give 12min a profile"), "Apple didn’t give 12min a profile, as Atelier couldn’t reach Apple. Check your connection, then try again.")
		XCTAssertEqual(unreached.explained(AppleIDError.couldNotReachApple), "Atelier couldn’t reach Apple. Check your connection, then try again.")
		XCTAssertFalse(AppleIDError(kind: .developer, appleCode: 1, message: "network").isUnreached, "Apple answered")
	}

	func testSaysWhenAtelierCantTellWhy() {
		let unread = AppleIDError(kind: .other, message: "Failed to parse developer request plist: unexpected end of file")
		XCTAssertFalse(unread.isUnreached)
		XCTAssertEqual(unread.explained("Apple didn’t give 12min a profile"), "Apple didn’t give 12min a profile, and Atelier can’t tell why. Apple ID Log, on the Apple ID’s page, has what Apple answered.")
		XCTAssertEqual(AppleIDError(kind: .developer, appleCode: 9, message: "").explained("Apple didn’t make the certificate"), "Apple didn’t make the certificate, and Atelier can’t tell why. Apple ID Log, on the Apple ID’s page, has what Apple answered.")
	}

	func testTheCodeAlertsNoteInPlainWords() {
		XCTAssertEqual(AppleIDError.plainCodeNote("-21669 - Incorrect verification code."), "That code wasn’t right.")
		XCTAssertEqual(AppleIDError.plainCodeNote("Too Many Codes - You've asked for too many codes. Try again later."), "You've asked for too many codes. Try again later.")
		XCTAssertEqual(AppleIDError.plainCodeNote("Something Apple said"), "Something Apple said")
	}

	func testWhatEachErrorMeansForTheServers() {
		XCTAssertEqual(AppleIDError(kind: .signIn, appleCode: -20101, message: "").routeFailure, .final)
		XCTAssertEqual(AppleIDError(kind: .signIn, appleCode: -22406, message: "").routeFailure, .final, "a wrong password isn't tried through another server")
		XCTAssertEqual(AppleIDError(kind: .signIn, appleCode: -20209, message: "").routeFailure, .final)
		XCTAssertEqual(AppleIDError(kind: .cancelled, message: "").routeFailure, .final)
		XCTAssertEqual(AppleIDError(kind: .developer, appleCode: 1100, message: "").routeFailure, .final)
		XCTAssertEqual(AppleIDError(kind: .noTeam, message: "").routeFailure, .final)
		XCTAssertEqual(AppleIDError(kind: .tokenRefused, appleCode: 1100, message: "").routeFailure, .final)
		XCTAssertEqual(AppleIDError(kind: .signIn, appleCode: -22421, message: "").routeFailure, .tryAgain)
		XCTAssertEqual(AppleIDError(kind: .signIn, appleCode: -80045, message: "").routeFailure, .refused)
		XCTAssertEqual(AppleIDError(kind: .signIn, appleCode: -45061, message: "").routeFailure, .server)
		XCTAssertEqual(AppleIDError(kind: .other, message: "no network").routeFailure, .server)
	}
}

final class CustomAnisetteServerTests: XCTestCase {
	private func resolve(_ setting: String) -> Result<URL?, CustomAnisetteServer.Problem> {
		CustomAnisetteServer.resolve(setting)
	}

	func testEmptyMeansAteliersList() {
		XCTAssertEqual(try resolve("  ").get(), nil)
	}

	func testKeepsOnlyTheServersAddress() {
		XCTAssertEqual(try resolve(" https://Ani.Example.com/ ").get()?.absoluteString, "https://ani.example.com")
		XCTAssertEqual(try resolve("http://192.168.1.20:6969").get()?.absoluteString, "http://192.168.1.20:6969")
	}

	func testRefusesWhatIsntAServersAddress() {
		XCTAssertEqual(resolve("ftp://ani.example.com"), .failure(.notHTTP))
		XCTAssertEqual(resolve("ani.example.com"), .failure(.notAURL))
		XCTAssertEqual(resolve("https://"), .failure(.noHost))
		XCTAssertEqual(resolve("https://ani.example.com/v3/client_info"), .failure(.hasMore))
		XCTAssertEqual(resolve("https://user:pass@ani.example.com"), .failure(.hasMore))
	}
}
