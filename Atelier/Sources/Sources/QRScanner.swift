import AVFoundation
import SwiftUI
import UIKit

/// The camera, looking for a QR code. Hands back the first code it reads.
struct QRScannerSheet: View {
	let onScan: (String) -> Void
	@Environment(\.dismiss) private var dismiss
	@State private var problem: String?

	var body: some View {
		NavigationStack {
			ZStack {
				Color.black.ignoresSafeArea()
				if let problem {
					ContentUnavailableView("Can't scan", systemImage: "camera", description: Text(problem))
						.foregroundStyle(.white)
				} else {
					QRScannerView(onScan: onScan, onProblem: { problem = $0 })
						.ignoresSafeArea()
				}
			}
			.navigationTitle("Scan QR Code")
			.navigationBarTitleDisplayMode(.inline)
			.toolbarColorScheme(.dark, for: .navigationBar)
			.toolbarBackground(.visible, for: .navigationBar)
			.toolbar {
				ToolbarItem(placement: .cancellationAction) {
					Button("Cancel") { dismiss() }
				}
			}
		}
	}
}

private struct QRScannerView: UIViewControllerRepresentable {
	let onScan: (String) -> Void
	let onProblem: (String) -> Void

	func makeUIViewController(context: Context) -> QRScannerController {
		QRScannerController(onScan: onScan, onProblem: onProblem)
	}

	func updateUIViewController(_ controller: QRScannerController, context: Context) {}
}

final class QRScannerController: UIViewController, AVCaptureMetadataOutputObjectsDelegate {
	private let onScan: (String) -> Void
	private let onProblem: (String) -> Void
	private let session = AVCaptureSession()
	private var preview: AVCaptureVideoPreviewLayer?
	private var scanned = false

	init(onScan: @escaping (String) -> Void, onProblem: @escaping (String) -> Void) {
		self.onScan = onScan
		self.onProblem = onProblem
		super.init(nibName: nil, bundle: nil)
	}

	required init?(coder: NSCoder) { fatalError("Not used from storyboards") }

	override func viewDidLoad() {
		super.viewDidLoad()
		view.backgroundColor = .black
		switch AVCaptureDevice.authorizationStatus(for: .video) {
		case .authorized:
			configure()
		case .notDetermined:
			AVCaptureDevice.requestAccess(for: .video) { granted in
				DispatchQueue.main.async { [weak self] in
					if granted { self?.configure() } else { self?.deny() }
				}
			}
		default:
			deny()
		}
	}

	override func viewDidLayoutSubviews() {
		super.viewDidLayoutSubviews()
		preview?.frame = view.bounds
	}

	override func viewWillDisappear(_ animated: Bool) {
		super.viewWillDisappear(animated)
		let running = self.session
		DispatchQueue.global(qos: .userInitiated).async { running.stopRunning() }
	}

	private func deny() {
		onProblem("Atelier doesn't have access to the camera. Allow it in Settings › Atelier, or paste the source's URL instead.")
	}

	private func configure() {
		guard
			let camera = AVCaptureDevice.default(for: .video),
			let input = try? AVCaptureDeviceInput(device: camera),
			session.canAddInput(input)
		else {
			onProblem("This device's camera isn't available.")
			return
		}
		session.addInput(input)
		let output = AVCaptureMetadataOutput()
		guard session.canAddOutput(output) else {
			onProblem("This device can't scan QR codes.")
			return
		}
		session.addOutput(output)
		output.setMetadataObjectsDelegate(self, queue: .main)
		output.metadataObjectTypes = [.qr]

		let preview = AVCaptureVideoPreviewLayer(session: session)
		preview.videoGravity = .resizeAspectFill
		preview.frame = view.bounds
		view.layer.addSublayer(preview)
		self.preview = preview

		// startRunning blocks, so it stays off the main thread.
		let starting = self.session
		DispatchQueue.global(qos: .userInitiated).async { starting.startRunning() }
	}

	// The delegate queue is the main queue.
	nonisolated func metadataOutput(_ output: AVCaptureMetadataOutput, didOutput objects: [AVMetadataObject], from connection: AVCaptureConnection) {
		let code = objects.lazy.compactMap { ($0 as? AVMetadataMachineReadableCodeObject)?.stringValue }.first
		MainActor.assumeIsolated {
			guard !scanned, let code else { return }
			scanned = true
			UINotificationFeedbackGenerator().notificationOccurred(.success)
			onScan(code)
		}
	}
}
