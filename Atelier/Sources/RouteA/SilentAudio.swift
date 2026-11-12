import AVFoundation
import Foundation

/// Keeps Atelier running in the background while pairing waits in Settings
/// (#54), while direct installs go on after the user leaves (#72) and while
/// Find Open Spaces Automatically looks at the Home Screen, by
/// looping a second of silence under the audio background mode, mixed with
/// whatever else is playing.
///
/// For pairing it stands in for the BGContinuedProcessingTask, whose system
/// bar fights Atelier's own Live Activity for the Dynamic Island: with both,
/// iOS shrinks them to icons and picks one. Installs keep the system's bar to
/// show their progress, and the silence keeps them going once iOS ends it
/// early, as it did on the locked test iPhone (25 Oct 2026). In the install
/// spike on iOS 27.0.1, silence alone kept the app running in the background
/// for over 2 minutes, logging every 10 s, until the maintainer came back (verified);
/// the full 10 minutes of a pairing attempt weren't tested.
@MainActor
final class SilentAudio {
	static let shared = SilentAudio()

	/// What needs Atelier running: it plays while either does.
	enum Holder {
		case pairing
		case installs
		/// Find Open Spaces Automatically, while Atelier is on the Home
		/// Screen for a moment (11 Nov 2026).
		case openSpaces
	}

	private var engine: AVAudioEngine?
	private var interruptionObserver: NSObjectProtocol?
	private var holders: Set<Holder> = []

	var isPlaying: Bool { engine != nil }

	/// Must be called while Atelier is in front.
	func start(for holder: Holder) throws {
		if engine == nil { try play() }
		holders.insert(holder)
	}

	func stop(for holder: Holder) {
		holders.remove(holder)
		if holders.isEmpty { silence() }
	}

	private func play() throws {
		let session = AVAudioSession.sharedInstance()
		try session.setCategory(.playback, mode: .default, options: [.mixWithOthers])
		try session.setActive(true)
		let engine = AVAudioEngine()
		let player = AVAudioPlayerNode()
		let format = engine.mainMixerNode.outputFormat(forBus: 0)
		guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(format.sampleRate)) else {
			throw CocoaError(.featureUnsupported)
		}
		// A new buffer is zeroed: one second of silence.
		buffer.frameLength = buffer.frameCapacity
		engine.attach(player)
		engine.connect(player, to: engine.mainMixerNode, format: format)
		try engine.start()
		player.scheduleBuffer(buffer, at: nil, options: .loops)
		player.play()
		self.engine = engine
		// A call or another app's audio stops the engine; start it again after.
		interruptionObserver = NotificationCenter.default.addObserver(forName: AVAudioSession.interruptionNotification, object: nil, queue: .main) { note in
			let type = (note.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt).flatMap(AVAudioSession.InterruptionType.init)
			guard type == .ended else { return }
			MainActor.assumeIsolated {
				let audio = SilentAudio.shared
				guard audio.isPlaying else { return }
				audio.silence()
				do {
					try audio.play()
				} catch {
					if audio.holders.contains(.pairing) {
						PhonePairing.shared.note("silent audio didn't restart after an interruption: \(error)")
					}
				}
			}
		}
	}

	private func silence() {
		if let interruptionObserver {
			NotificationCenter.default.removeObserver(interruptionObserver)
			self.interruptionObserver = nil
		}
		guard let engine else { return }
		engine.stop()
		self.engine = nil
		try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
	}
}
