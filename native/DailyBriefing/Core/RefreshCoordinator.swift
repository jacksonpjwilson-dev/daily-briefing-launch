import Foundation

public struct ProviderDeadlineExceeded: LocalizedError, Sendable {
    public var errorDescription: String? { "This source exceeded its refresh deadline. Saved information may be outdated." }
}
private final class DeadlineRace<Value: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Value, Error>?
    private var result: Result<Value, Error>?
    private var tasks: [Task<Void, Never>] = []
    func install(_ continuation: CheckedContinuation<Value, Error>) {
        lock.lock()
        if let result { lock.unlock(); continuation.resume(with: result) }
        else { self.continuation = continuation; lock.unlock() }
    }
    func track(_ task: Task<Void, Never>) {
        lock.lock()
        if result != nil { lock.unlock(); task.cancel() }
        else { tasks.append(task); lock.unlock() }
    }
    func resolve(_ result: Result<Value, Error>) {
        lock.lock()
        guard self.result == nil else { lock.unlock(); return }
        self.result = result
        let continuation = self.continuation; self.continuation = nil
        let tasks = self.tasks; self.tasks = []
        lock.unlock()
        tasks.forEach { $0.cancel() }
        continuation?.resume(with: result)
    }
}
public enum ProviderDeadline {
    @MainActor public static func run<Value: Sendable>(seconds: Double,
        operation: @escaping @MainActor @Sendable () async throws -> Value) async throws -> Value {
        let race = DeadlineRace<Value>()
        return try await withTaskCancellationHandler(operation: {
            try Task.checkCancellation()
            return try await withCheckedThrowingContinuation { continuation in
                race.install(continuation)
                race.track(Task { @MainActor in
                    do { try Task.checkCancellation(); race.resolve(.success(try await operation())) }
                    catch { race.resolve(.failure(error)) }
                })
                race.track(Task {
                    do {
                        try await Task.sleep(nanoseconds: UInt64(max(0.001, min(3600, seconds)) * 1_000_000_000))
                        race.resolve(.failure(ProviderDeadlineExceeded()))
                    } catch { /* The winning result or parent cancellation already resumed the waiter. */ }
                })
            }
        }, onCancel: { race.resolve(.failure(CancellationError())) })
    }
}
public struct RefreshJob: Sendable {
    public let kind: SectionKind
    public let timeout: Double
    public let operation: @MainActor @Sendable () async throws -> BriefingSection
    public init(kind: SectionKind, timeout: Double = 12, operation: @escaping @MainActor @Sendable () async throws -> BriefingSection) {
        self.kind = kind; self.timeout = timeout; self.operation = operation
    }
}
public enum RefreshCompletion: Equatable, Sendable { case complete, interrupted, persistenceFailed }
/// Testable orchestration used by the application. Provider work cannot write to storage directly.
/// Even a non-cooperative provider cannot delay the caller past its deadline or commit a late result.
@MainActor public enum RefreshCoordinator {
    public static func run(jobs: [RefreshJob], enabled: Set<SectionKind>, budget: Double,
                           reschedule: @escaping @MainActor () async -> Void = {},
                           checkpoint: @escaping @MainActor (BriefingSection) throws -> Void) async -> RefreshCompletion {
        await reschedule()
        let result: RefreshCompletion = await withTaskGroup(of: BriefingSection?.self) { group in
            for job in jobs where enabled.contains(job.kind) {
                group.addTask {
                    do { return try await ProviderDeadline.run(seconds: min(job.timeout, budget), operation: job.operation) }
                    catch is CancellationError { return nil }
                    catch is ProviderDeadlineExceeded {
                        return BriefingSection(kind: job.kind, state: .timedOut, message: ProviderDeadlineExceeded().localizedDescription)
                    } catch {
                        let e = error as NSError
                        let offline = e.domain == NSURLErrorDomain && [NSURLErrorNotConnectedToInternet, NSURLErrorNetworkConnectionLost].contains(e.code)
                        return BriefingSection(kind: job.kind, state: offline ? .offline : e.code == NSURLErrorTimedOut ? .timedOut : .failed, message: error.localizedDescription)
                    }
                }
            }
            for await section in group {
                guard !Task.isCancelled else { group.cancelAll(); return .interrupted }
                guard let section else { continue }
                do { try checkpoint(section) }
                catch { group.cancelAll(); return .persistenceFailed }
            }
            return Task.isCancelled ? .interrupted : .complete
        }
        await reschedule()
        return result
    }
}
