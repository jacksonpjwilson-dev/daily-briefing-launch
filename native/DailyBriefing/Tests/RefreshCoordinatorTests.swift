import XCTest
@testable import BriefingCore

final class RefreshCoordinatorTests: XCTestCase {
    @MainActor func testDisabledJobsNeverExecuteIncludingSummary() async {
        var requested: [SectionKind] = [], saved: [SectionKind] = []
        let jobs = SectionKind.allCases.map { kind in RefreshJob(kind: kind) {
            requested.append(kind); return BriefingSection(kind: kind, state: .ready)
        } }
        let result = await RefreshCoordinator.run(jobs: jobs, enabled: [.news], budget: 1) { saved.append($0.kind) }
        XCTAssertEqual(result, .complete); XCTAssertEqual(requested, [.news]); XCTAssertEqual(saved, [.news])
    }
    @MainActor func testDeadlineDoesNotWaitForNonCooperativeProviderOrCommitLateResult() async throws {
        var saved: [BriefingSection] = []
        let began = ContinuousClock.now
        let result = await RefreshCoordinator.run(jobs: [.init(kind: .news, timeout: 0.01) {
            // A deliberately non-cooperative fixture returns after cancellation.
            let end = ContinuousClock.now.advanced(by: .milliseconds(200))
            while ContinuousClock.now < end { try? await Task.sleep(nanoseconds: 10_000_000) }
            return BriefingSection(kind: .news, state: .ready, items: [.init(title: "Late fixture", source: "Test")])
        }], enabled: [.news], budget: 1) { saved.append($0) }
        XCTAssertEqual(result, .complete); XCTAssertEqual(saved.map(\.state), [.timedOut])
        XCTAssertLessThan(began.duration(to: .now), .milliseconds(180))
        try await Task.sleep(nanoseconds: 250_000_000)
        XCTAssertEqual(saved.count, 1); XCTAssertTrue(saved[0].items.isEmpty)
    }
    @MainActor func testInterruptedRefreshPreservesCheckpointAndCanResume() async throws {
        let checkpoint = expectation(description: "Fast source persisted")
        var persisted: [BriefingSection] = []
        var rescheduled = 0
        let task = Task { @MainActor in
            await RefreshCoordinator.run(jobs: [
                .init(kind: .schedule) { .init(kind: .schedule, state: .ready) },
                .init(kind: .news) { try await Task.sleep(nanoseconds: 1_000_000_000); return .init(kind: .news, state: .ready) }
            ], enabled: [.schedule, .news], budget: 2, reschedule: { rescheduled += 1 }) { section in
                persisted.append(section); if section.kind == .schedule { checkpoint.fulfill() }
            }
        }
        await fulfillment(of: [checkpoint], timeout: 1)
        task.cancel()
        let outcome = await task.value
        XCTAssertEqual(rescheduled, 2, "The background chain is renewed even when the parent is canceled")
        XCTAssertEqual(outcome, .interrupted); XCTAssertEqual(persisted.map(\.kind), [.schedule])
        let resumed = await RefreshCoordinator.run(jobs: [.init(kind: .news) { .init(kind: .news, state: .ready) }], enabled: [.news], budget: 1) { persisted.append($0) }
        XCTAssertEqual(resumed, .complete); XCTAssertEqual(Set(persisted.map(\.kind)), [.schedule, .news])
    }
    @MainActor func testLockedCredentialsAreAnAccessProblemAndDoNotRunNetworkStage() async {
        var networkRequests = 0
        var results: [BriefingSection] = []
        let outcome = await RefreshCoordinator.run(jobs: [.init(kind: .summary) {
            let readToken: () throws -> String = { throw ProviderAccessError(state: .permissionDenied, message: "Fixture credential is locked") }
            _ = try readToken()
            networkRequests += 1
            return .init(kind: .summary, state: .ready)
        }], enabled: [.summary], budget: 1) { results.append($0) }
        XCTAssertEqual(outcome, .complete); XCTAssertEqual(networkRequests, 0)
        XCTAssertEqual(results.first?.state, .permissionDenied)
    }
    @MainActor func testProviderFailureIsIsolatedAndCheckpointFailureStopsFurtherCommits() async {
        var saved: [BriefingSection] = []
        let result = await RefreshCoordinator.run(jobs: [
            .init(kind: .news) { throw NSError(domain: NSURLErrorDomain, code: NSURLErrorNotConnectedToInternet) },
            .init(kind: .schedule) { .init(kind: .schedule, state: .ready) }
        ], enabled: [.news, .schedule], budget: 1) { saved.append($0) }
        XCTAssertEqual(result, .complete)
        XCTAssertEqual(saved.first { $0.kind == .news }?.state, .offline)
        XCTAssertEqual(saved.first { $0.kind == .schedule }?.state, .ready)
        var commits = 0
        let failure = await RefreshCoordinator.run(jobs: [
            .init(kind: .news) { .init(kind: .news, state: .ready) },
            .init(kind: .weather) { try await Task.sleep(nanoseconds: 100_000_000); return .init(kind: .weather, state: .ready) }
        ], enabled: [.news, .weather], budget: 1) { _ in commits += 1; throw CocoaError(.fileWriteOutOfSpace) }
        XCTAssertEqual(failure, .persistenceFailed); XCTAssertEqual(commits, 1)
    }
}
