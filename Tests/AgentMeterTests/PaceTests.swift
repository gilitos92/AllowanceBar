import XCTest
@testable import AgentMeter

final class PaceTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)
    private let week: TimeInterval = 7 * 86_400

    private func window(used: Double, left: TimeInterval, duration: TimeInterval?) -> UsageWindow {
        UsageWindow(label: "Weekly limit", usedPercent: used, resetsAt: now.addingTimeInterval(left), duration: duration)
    }

    func testElapsedFraction() throws {
        let w = window(used: 24, left: 2.5 * 86_400, duration: week)
        XCTAssertEqual(try XCTUnwrap(w.elapsedFraction(now: now)), 4.5 / 7, accuracy: 0.0001)
    }

    func testElapsedFractionNeedsDurationAndAFutureResetInsideTheWindow() {
        XCTAssertNil(window(used: 10, left: 3600, duration: nil).elapsedFraction(now: now))
        XCTAssertNil(window(used: 10, left: -60, duration: week).elapsedFraction(now: now))
        XCTAssertNil(window(used: 10, left: week + 3600, duration: week).elapsedFraction(now: now))
        XCTAssertNil(UsageWindow(label: "x", usedPercent: 1, resetsAt: nil, duration: week).elapsedFraction(now: now))
    }

    func testPaceVerdicts() {
        // Half the window gone.
        XCTAssertEqual(window(used: 56, left: week / 2, duration: week).pace(now: now), .ahead)
        XCTAssertEqual(window(used: 55, left: week / 2, duration: week).pace(now: now), .on)
        XCTAssertEqual(window(used: 45, left: week / 2, duration: week).pace(now: now), .on)
        XCTAssertEqual(window(used: 44, left: week / 2, duration: week).pace(now: now), .under)
        XCTAssertNil(window(used: 44, left: week / 2, duration: nil).pace(now: now))
    }

    func testMarkerFollowsCountDirection() throws {
        let w = window(used: 10, left: week / 4, duration: week)
        XCTAssertEqual(try XCTUnwrap(CountDirection.used.paceMarkerPercent(for: w, now: now)), 75, accuracy: 0.0001)
        XCTAssertEqual(try XCTUnwrap(CountDirection.remaining.paceMarkerPercent(for: w, now: now)), 25, accuracy: 0.0001)
    }

    func testProvidersReportWindowLength() {
        let claude = ClaudeProvider.usage(
            from: .init(
                fiveHour: .init(utilization: 10, resetsAt: "2027-01-01T00:00:00Z"),
                sevenDay: .init(utilization: 20, resetsAt: "2027-01-05T00:00:00Z"),
                sevenDayOpus: nil
            ),
            plan: nil,
            now: now
        )
        XCTAssertEqual(claude.windows.map(\.duration), [5 * 3600, week])

        XCTAssertEqual(CodexUsageReader.windowDuration(minutes: 300), 18_000)
        XCTAssertNil(CodexUsageReader.windowDuration(minutes: 0))
    }

    func testCursorCycleLengthComesFromBillingCycleStart() throws {
        var summary = CursorUsageFetcher.UsageSummary()
        summary.billingCycleStart = "2026-10-15T00:00:00.000Z"
        summary.billingCycleEnd = "2026-11-15T00:00:00.000Z"
        summary.individualUsage = .init(plan: .init(totalPercentUsed: 40))
        let usage = CursorUsageFetcher.usage(from: summary, now: now)
        XCTAssertEqual(try XCTUnwrap(usage.windows.first?.duration), 31 * 86_400, accuracy: 1)

        summary.billingCycleStart = nil
        XCTAssertNil(CursorUsageFetcher.usage(from: summary, now: now).windows.first?.duration)
    }

    func testPaceAlertFiresOncePerWindow() throws {
        let defaults = try XCTUnwrap(UserDefaults(suiteName: "PaceTests-\(UUID())"))
        var tracker = PaceTracker(defaults: defaults)
        // 40% used, 20% of the week gone: 20 points ahead.
        let ahead = window(used: 40, left: week * 0.8, duration: week)
        let usage = ProviderUsage(planName: nil, windows: [ahead], asOf: now)

        XCTAssertEqual(tracker.alerts(providerID: "claude", usage: usage, now: now).count, 1)
        XCTAssertEqual(tracker.alerts(providerID: "claude", usage: usage, now: now).count, 0)

        // State survives a restart.
        var reloaded = PaceTracker(defaults: defaults)
        XCTAssertEqual(reloaded.alerts(providerID: "claude", usage: usage, now: now).count, 0)

        // The next window re-arms after the reset passes.
        let later = now.addingTimeInterval(week)
        let next = UsageWindow(label: "Weekly limit", usedPercent: 40, resetsAt: later.addingTimeInterval(week * 0.8), duration: week)
        XCTAssertEqual(
            reloaded.alerts(providerID: "claude", usage: ProviderUsage(planName: nil, windows: [next], asOf: later), now: later).count,
            1
        )
    }

    func testPaceAlertSkipsSmallGapsEarlyWindowsAndUsedUpLimits() throws {
        let defaults = try XCTUnwrap(UserDefaults(suiteName: "PaceTests-\(UUID())"))
        var tracker = PaceTracker(defaults: defaults)
        let windows = [
            window(used: 30, left: week * 0.8, duration: week),   // 10 points ahead
            window(used: 30, left: week * 0.95, duration: week),  // only 5% gone
            window(used: 100, left: week * 0.5, duration: week),  // already used up
            window(used: 90, left: week * 0.5, duration: nil),    // length unknown
        ]
        for w in windows {
            let usage = ProviderUsage(planName: nil, windows: [w], asOf: now)
            XCTAssertTrue(tracker.alerts(providerID: "p", usage: usage, now: now).isEmpty)
        }
    }

    func testProjectedRunOut() throws {
        // 50% used in the first day of a week: 1 more day at that rate.
        let w = window(used: 50, left: week - 86_400, duration: week)
        let runOut = try XCTUnwrap(PaceTracker.projectedRunOut(for: w, now: now))
        XCTAssertEqual(runOut.timeIntervalSince(now), 86_400, accuracy: 1)

        XCTAssertNil(PaceTracker.projectedRunOut(for: window(used: 10, left: week / 2, duration: week), now: now))
    }

    @MainActor func testShowsPaceDefaultsOnAndPaceAlertsOff() throws {
        let defaults = try XCTUnwrap(UserDefaults(suiteName: "PaceTests-\(UUID())"))
        let settings = SettingsStore(defaults: defaults)
        XCTAssertTrue(settings.showsPace)
        XCTAssertFalse(settings.paceNotificationsEnabled)
        settings.showsPace = false
        XCTAssertFalse(SettingsStore(defaults: defaults).showsPace)
    }

    func testNanoSummaryAddsPaceArrows() {
        let usage = ProviderUsage(
            planName: nil,
            windows: [
                UsageWindow(label: "5h limit", usedPercent: 38, resetsAt: now.addingTimeInterval(4 * 3600), duration: 5 * 3600),
                window(used: 24, left: week / 2, duration: week),
                UsageWindow(label: "Other", usedPercent: 10, resetsAt: nil),
            ],
            asOf: now
        )
        // 38% used, 20% gone: ahead. 24% used, 50% gone: under. No length: no arrow.
        XCTAssertEqual(usage.menuSummary(direction: .used, allWindows: true, showsPace: true, now: now), "38%↗ (24%↘, 10%)")
        XCTAssertEqual(usage.menuSummary(direction: .used, allWindows: true, now: now), "38% (24%, 10%)")
        XCTAssertEqual(usage.menuSummary(direction: .used, showsPace: true, now: now), "38%↗")
    }

    func testNanoSpokenSummaryIncludesPace() {
        let usage = ProviderUsage(
            planName: nil,
            windows: [window(used: 24, left: week / 2, duration: week)],
            asOf: now
        )
        let input = MenuBarAccessibilitySummary.ProviderInput(displayName: "Claude", state: .ready(usage))
        let spoken = MenuBarAccessibilitySummary.build(
            providers: [input], countDirection: .used, balanceThreshold: 5, includesPace: true, now: now
        )
        XCTAssertTrue(spoken.hasSuffix(UsagePace.under.phrase), spoken)
        let plain = MenuBarAccessibilitySummary.build(providers: [input], countDirection: .used, balanceThreshold: 5, now: now)
        XCTAssertFalse(plain.contains(UsagePace.under.phrase))
    }

    @MainActor func testNanoShowsPaceDefaultsOn() throws {
        let defaults = try XCTUnwrap(UserDefaults(suiteName: "PaceTests-\(UUID())"))
        XCTAssertTrue(SettingsStore(defaults: defaults).nanoShowsPace)
    }

    @MainActor func testNanoShowsPaceFollowsShowPaceUntilSet() throws {
        let defaults = try XCTUnwrap(UserDefaults(suiteName: "PaceTests-\(UUID())"))
        defaults.set(false, forKey: "showsPace")
        XCTAssertFalse(SettingsStore(defaults: defaults).nanoShowsPace)
        defaults.set(true, forKey: "nanoShowsPace")
        XCTAssertTrue(SettingsStore(defaults: defaults).nanoShowsPace)
    }
}
