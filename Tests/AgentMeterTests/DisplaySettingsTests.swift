import XCTest
@testable import AgentMeter

final class DisplaySettingsTests: XCTestCase {
    func testShortRemainingDescriptionDropsPrefix() {
        let now = Date(timeIntervalSince1970: 1_790_000_000)
        func short(_ seconds: TimeInterval) -> String? {
            UsageWindow(label: "Weekly", usedPercent: 50, resetsAt: now.addingTimeInterval(seconds))
                .shortRemainingDescription(now: now)
        }
        XCTAssertEqual(short(4 * 86400 + 23 * 3600 + 60), "4d 23h")
        XCTAssertEqual(short(3 * 3600 + 32 * 60 + 5), "3h 32m")
        XCTAssertEqual(short(12 * 60 + 30), "12m")
        XCTAssertEqual(short(-5), "soon")
        XCTAssertNil(UsageWindow(label: "Key", usedPercent: 5, resetsAt: nil).shortRemainingDescription(now: now))
    }

    @MainActor
    func testUsageDetailsAlwaysOnTopDefaultsOffAndPersists() {
        let suite = "DisplaySettingsTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }

        let settings = SettingsStore(defaults: defaults)
        XCTAssertFalse(settings.usageDetailsAlwaysOnTop)
        XCTAssertFalse(settings.usageDetailsOnAllSpaces)
        settings.usageDetailsAlwaysOnTop = true
        settings.usageDetailsOnAllSpaces = true
        let reloaded = SettingsStore(defaults: defaults)
        XCTAssertTrue(reloaded.usageDetailsAlwaysOnTop)
        XCTAssertTrue(reloaded.usageDetailsOnAllSpaces)
    }

    @MainActor
    func testWindowLevelSetterFloatsAndRestoresWindow() {
        _ = NSApplication.shared
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 100, height: 100),
                              styleMask: .titled, backing: .buffered, defer: true)
        window.isReleasedWhenClosed = false
        let probe = WindowLevelSetter.ProbeView()
        probe.alwaysOnTop = true
        window.contentView = probe
        XCTAssertEqual(window.level, .floating)
        XCTAssertFalse(window.collectionBehavior.contains(.canJoinAllSpaces))

        probe.alwaysOnTop = false
        XCTAssertEqual(window.level, .normal)
    }

    @MainActor
    func testWindowLevelSetterAllSpacesRequiresAlwaysOnTop() {
        _ = NSApplication.shared
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 100, height: 100),
                              styleMask: .titled, backing: .buffered, defer: true)
        window.isReleasedWhenClosed = false
        let probe = WindowLevelSetter.ProbeView()
        window.contentView = probe

        probe.onAllSpaces = true
        XCTAssertEqual(window.level, .normal)
        XCTAssertFalse(window.collectionBehavior.contains(.canJoinAllSpaces))

        probe.alwaysOnTop = true
        XCTAssertEqual(window.level, .floating)
        XCTAssertTrue(window.collectionBehavior.contains(.canJoinAllSpaces))
        XCTAssertTrue(window.collectionBehavior.contains(.fullScreenAuxiliary))

        probe.onAllSpaces = false
        XCTAssertEqual(window.level, .floating)
        XCTAssertFalse(window.collectionBehavior.contains(.canJoinAllSpaces))
        XCTAssertFalse(window.collectionBehavior.contains(.fullScreenAuxiliary))
    }

    func testCountDirectionDisplayPercent() {
        XCTAssertEqual(CountDirection.used.displayPercent(84), 84, accuracy: 0.001)
        XCTAssertEqual(CountDirection.remaining.displayPercent(84), 16, accuracy: 0.001)
    }

    func testCountDirectionPercentLabel() {
        XCTAssertEqual(CountDirection.used.percentLabel(84), "84%")
        XCTAssertEqual(CountDirection.used.percentLabel(84, menuBar: true), "84%")
        XCTAssertEqual(CountDirection.remaining.percentLabel(84), "16% left")
        XCTAssertEqual(CountDirection.remaining.percentLabel(84, menuBar: true), "16%")
    }

    func testResetDescriptionRelativeMatchesRemainingDescription() {
        // Stay away from a minute boundary: the two convenience calls each
        // sample the clock independently.
        let resetsAt = Date().addingTimeInterval(7230)
        let window = UsageWindow(label: "Weekly", usedPercent: 50, resetsAt: resetsAt)
        XCTAssertEqual(window.resetDescription(style: .relative), window.remainingDescription)
    }

    func testResetDescriptionAbsoluteContainsMonthDayAndTime() {
        let resetsAt = Date().addingTimeInterval(86400 * 5)
        let window = UsageWindow(label: "Weekly", usedPercent: 50, resetsAt: resetsAt)
        guard let description = window.resetDescription(style: .absolute) else {
            return XCTFail("expected absolute reset description")
        }
        XCTAssertTrue(description.hasPrefix("resets "))
        XCTAssertTrue(description.contains(":"))
    }

    func testAbsoluteResetIncludesRoundedDurationAndLocalizedUnits() {
        let now = Date(timeIntervalSince1970: 1_790_000_000)
        func duration(_ seconds: TimeInterval) -> String? {
            UsageWindow(label: "Weekly", usedPercent: 50, resetsAt: now.addingTimeInterval(seconds))
                .resetDescription(style: .absolute, now: now)?.components(separatedBy: "(").last
        }
        XCTAssertEqual(duration(6 * 86_400 + 18 * 3_600), "6 days 18 hours)")
        XCTAssertEqual(duration(2 * 86_400 + 4 * 3_600), "2 days 4 hours)")
        XCTAssertEqual(duration(4 * 3_600 + 36 * 60), "4 hours 36 minutes)")
        XCTAssertEqual(duration(36 * 60), "36 minutes)")
    }

    func testAbsoluteResetDurationRoundingAndRollover() {
        let now = Date(timeIntervalSince1970: 1_790_000_000)
        func description(_ seconds: TimeInterval) -> String? {
            UsageWindow(label: "Weekly", usedPercent: 50, resetsAt: now.addingTimeInterval(seconds))
                .resetDescription(style: .absolute, now: now)
        }
        XCTAssertTrue(description(86_400 + 1.49 * 3_600)?.hasSuffix("(1 day 1 hour)") == true)
        XCTAssertTrue(description(86_400 + 1.51 * 3_600)?.hasSuffix("(1 day 2 hours)") == true)
        XCTAssertTrue(description(86_400 + 23.6 * 3_600)?.hasSuffix("(2 days 0 hours)") == true)
        XCTAssertTrue(description(23 * 3_600 + 59.6 * 60)?.hasSuffix("(1 day 0 hours)") == true)
        XCTAssertTrue(description(59.6 * 60)?.hasSuffix("(1 hour 0 minutes)") == true)
        XCTAssertTrue(description(4 * 3_600 + 36.4 * 60)?.hasSuffix("(4 hours 36 minutes)") == true)
        XCTAssertTrue(description(4 * 3_600 + 36.6 * 60)?.hasSuffix("(4 hours 37 minutes)") == true)
        XCTAssertTrue(description(59)?.hasSuffix("(less than a minute)") == true)
        XCTAssertEqual(description(-1), "resets soon")
    }

    func testAbsoluteResetWithoutResetDateIsNil() {
        XCTAssertNil(UsageWindow(label: "Weekly", usedPercent: 50, resetsAt: nil)
            .resetDescription(style: .absolute, now: Date(timeIntervalSince1970: 0)))
    }

    func testMenuSummaryUsedMode() {
        let usage = ProviderUsage(
            planName: nil,
            windows: [UsageWindow(label: "5h", usedPercent: 84, resetsAt: nil)],
            asOf: nil
        )
        XCTAssertEqual(usage.menuSummary(direction: .used), "84%")
        XCTAssertEqual(usage.menuSummary(direction: .remaining), "16%")
    }

    func testMenuSummaryAllWindowsListsEveryWindowInOrder() {
        let usage = ProviderUsage(
            planName: nil,
            windows: [
                UsageWindow(label: "5h limit", usedPercent: 8, resetsAt: nil),
                UsageWindow(label: "Weekly limit", usedPercent: 40, resetsAt: nil),
                UsageWindow(label: "Weekly (Opus)", usedPercent: 27, resetsAt: nil),
            ],
            asOf: nil
        )
        XCTAssertEqual(usage.menuSummary(direction: .used), "40%")
        XCTAssertEqual(usage.menuSummary(direction: .used, allWindows: true), "8% (40%, 27%)")
        XCTAssertEqual(usage.menuSummary(direction: .remaining, allWindows: true), "92% (60%, 73%)")
    }

    func testMenuSummaryAllWindowsSingleWindowHasNoParentheses() {
        let usage = ProviderUsage(
            planName: nil,
            windows: [UsageWindow(label: "Key limit", usedPercent: 12, resetsAt: nil)],
            asOf: nil
        )
        XCTAssertEqual(usage.menuSummary(direction: .used, allWindows: true), "12%")
    }

    func testAccessibilitySummaryAllWindowsNamesEachLimit() {
        let usage = ProviderUsage(
            planName: nil,
            windows: [
                UsageWindow(label: "5h limit", usedPercent: 8, resetsAt: nil),
                UsageWindow(label: "Weekly limit", usedPercent: 40, resetsAt: nil),
            ],
            asOf: nil
        )
        let segment = MenuBarAccessibilitySummary.providerSegment(
            displayName: "Codex",
            state: .ready(usage),
            countDirection: .used,
            balanceThreshold: 5,
            allWindows: true
        )
        XCTAssertEqual(segment, "Codex: 5h limit, 8% used; Weekly limit, 40% used")
    }

    @MainActor
    func testMenuBarShowsAllLimitsDefaultsOffAndPersists() {
        let suite = "DisplaySettingsTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }

        let settings = SettingsStore(defaults: defaults)
        XCTAssertFalse(settings.menuBarShowsAllLimits)
        settings.menuBarShowsAllLimits = true
        XCTAssertTrue(SettingsStore(defaults: defaults).menuBarShowsAllLimits)
    }

    func testMenuSummaryBalanceProvider() {
        let usage = ProviderUsage(
            planName: nil,
            windows: [],
            asOf: nil,
            balance: BalanceInfo(remaining: 12.5, used: nil, currencySymbol: "$")
        )
        XCTAssertEqual(usage.menuSummary(direction: .used), "$12")
        XCTAssertEqual(usage.menuSummary(direction: .remaining), "$12")
    }
}
