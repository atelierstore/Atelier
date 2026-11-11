import Foundation

/// Runs installs one at a time, in the order they were asked for (#11). iOS
/// shows one install alert at a time, and signing needs the disk space of
/// one app at a time.
@MainActor
public final class InstallQueue<Job: Identifiable> {
	/// The job running now.
	public private(set) var current: Job?
	/// The jobs waiting, next first.
	public private(set) var pending: [Job] = []
	/// Called whenever `current` or `pending` changes.
	public var onChange: (() -> Void)?
	/// Whether a job waits behind every other, also those queued after it:
	/// Atelier's own update or re-sign, which closes Atelier (#24).
	public var runsLast: ((Job) -> Bool)?

	private let perform: @MainActor (Job) async -> Void
	private var drain: Task<Void, Never>?
	private var running: Task<Void, Never>?
	/// The running job goes back in the queue once it returns.
	private var requeuesCurrent = false

	/// `perform` runs one job; the queue moves on when it returns. A cancelled
	/// job's task is cancelled, and `perform` should return soon after.
	public init(perform: @escaping @MainActor (Job) async -> Void) {
		self.perform = perform
	}

	public var isEmpty: Bool { current == nil && pending.isEmpty }

	/// Adds a job at the end, though before the jobs that run last unless it
	/// runs last too. Returns false, and adds nothing, when a job with the
	/// same id is already waiting or running.
	@discardableResult
	public func enqueue(_ job: Job) -> Bool {
		guard current?.id != job.id, !pending.contains(where: { $0.id == job.id }) else { return false }
		insert(job)
		onChange?()
		if drain == nil {
			drain = Task { await self.run() }
		}
		return true
	}

	/// Adds a job to run next, ahead of the jobs waiting: what the running
	/// job turns into, such as when the user answers a question it asked
	/// (#99), so it may have the running job's id. Returns false, and adds
	/// nothing, when a job with the same id is already waiting.
	@discardableResult
	public func enqueueNext(_ job: Job) -> Bool {
		guard !pending.contains(where: { $0.id == job.id }) else { return false }
		pending.insert(job, at: 0)
		onChange?()
		if drain == nil {
			drain = Task { await self.run() }
		}
		return true
	}

	private func insert(_ job: Job) {
		if let runsLast, !runsLast(job), let last = pending.firstIndex(where: runsLast) {
			pending.insert(job, at: last)
		} else {
			pending.append(job)
		}
	}

	/// Puts the running job back in the queue once it returns, behind the
	/// jobs queued meanwhile: Atelier's own install, which waits for them
	/// rather than close Atelier while they still have to run (#24).
	public func requeueCurrent() {
		guard current != nil else { return }
		requeuesCurrent = true
	}

	/// Takes a waiting job off the queue.
	public func remove(_ id: Job.ID) {
		pending.removeAll { $0.id == id }
		onChange?()
	}

	/// Cancels the running job. The queue moves on to the next.
	public func cancelCurrent() {
		running?.cancel()
	}

	/// Drops every waiting job and cancels the running one.
	public func cancelAll() {
		pending.removeAll()
		onChange?()
		running?.cancel()
	}

	/// Returns once the queue has nothing left to run.
	public func waitUntilEmpty() async {
		await drain?.value
	}

	private func run() async {
		while !pending.isEmpty {
			let job = pending.removeFirst()
			current = job
			requeuesCurrent = false
			onChange?()
			let task = Task { await perform(job) }
			running = task
			await task.value
			running = nil
			current = nil
			if requeuesCurrent {
				requeuesCurrent = false
				insert(job)
			}
			onChange?()
		}
		drain = nil
	}
}
