import XCTest
@testable import AgentMeter

final class CompactUsageTests: XCTestCase {
    @MainActor
    func testCompactEntriesListEveryVisibleProviderRegardlessOfMenuBarStyle() async throws {
        let suite = "CompactUsageTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let settings = SettingsStore(defaults: defaults)
        settings.menuBarStyle = .icon
        let store = UsageStore(settings: settings, providers: [
            CompactProvider(id: "compact-a", usedPercent: 20),
            CompactProvider(id: "compact-b", usedPercent: 70),
        ])

        let deadline = Date().addingTimeInterval(3)
        while store.compactEntries.contains(where: { $0.summary == "…" }) {
            guard Date() < deadline else { return XCTFail("providers did not finish loading") }
            try await Task.sleep(nanoseconds: 1_000_000)
        }

        XCTAssertTrue(store.menuBarEntries.isEmpty)
        let entries = store.compactEntries
        XCTAssertEqual(entries.map(\.id), ["compact-a", "compact-b"])
        XCTAssertEqual(entries.map(\.summary), ["20%", "70%"])
        XCTAssertEqual(entries.map(\.severity), [.normal, .warning])
        XCTAssertTrue(entries[1].accessibilityLabel.contains("Compact provider"))
    }

    @MainActor
    func testNanoEntriesMirrorMenuBarAndListEveryProviderForIconStyle() async throws {
        let suite = "CompactUsageTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let settings = SettingsStore(defaults: defaults)
        settings.menuBarStyle = .compact
        let store = UsageStore(settings: settings, providers: [
            CompactProvider(id: "compact-a", usedPercent: 20),
            CompactProvider(id: "compact-b", usedPercent: 70),
        ])

        let deadline = Date().addingTimeInterval(3)
        while store.compactEntries.contains(where: { $0.summary == "…" }) {
            guard Date() < deadline else { return XCTFail("providers did not finish loading") }
            try await Task.sleep(nanoseconds: 1_000_000)
        }

        XCTAssertEqual(store.nanoEntries.map(\.text), store.menuBarEntries.map(\.text))
        XCTAssertEqual(store.nanoEntries.count, 1)
        settings.menuBarStyle = .icon
        XCTAssertTrue(store.menuBarEntries.isEmpty)
        XCTAssertEqual(store.nanoEntries.map(\.severity), [.normal, .warning])
    }

    @MainActor
    func testNanoMeterEntriesCarryTheSameFactsAsTheNanoText() async throws {
        let suite = "CompactUsageTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let settings = SettingsStore(defaults: defaults)
        settings.menuBarStyle = .full
        settings.nanoShowsPace = false
        let store = UsageStore(settings: settings, providers: [
            CompactProvider(id: "compact-a", usedPercent: 20),
            CompactProvider(id: "compact-b", usedPercent: 70, secondPercent: 30),
        ])

        let deadline = Date().addingTimeInterval(3)
        while store.compactEntries.contains(where: { $0.summary == "…" }) {
            guard Date() < deadline else { return XCTFail("providers did not finish loading") }
            try await Task.sleep(nanoseconds: 1_000_000)
        }

        settings.nanoShowsAllLimits = false
        var meters = store.nanoMeterEntries
        XCTAssertEqual(meters.map(\.providerID), store.nanoEntries.map(\.providerID))
        XCTAssertEqual(meters.map(\.severity), store.nanoEntries.map(\.severity))
        XCTAssertEqual(meters.map(\.value), ["20%", "70%"])
        XCTAssertEqual(meters.map { $0.windows.map(\.usedPercent) }, [[20], [70]])

        // With every limit, one meter per limit in the text's order.
        settings.nanoShowsAllLimits = true
        meters = store.nanoMeterEntries
        XCTAssertEqual(store.nanoEntries.map(\.text)[1], "C 30% (70%)")
        XCTAssertEqual(meters[1].windows.map(\.usedPercent), [30, 70])
        XCTAssertEqual(meters[1].value, "30%")
        for (meter, entry) in zip(meters, store.nanoEntries) {
            XCTAssertTrue(entry.text.hasPrefix("\(meter.code) \(meter.value)"), entry.text)
        }
    }

    @MainActor
    func testNanoSettingDefaultsOffAndPersists() {
        let suite = "CompactUsageTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }

        let settings = SettingsStore(defaults: defaults)
        XCTAssertFalse(settings.usageDetailsNano)
        XCTAssertFalse(settings.usageDetailsChromeless)
        settings.usageDetailsNano = true
        let reloaded = SettingsStore(defaults: defaults)
        XCTAssertTrue(reloaded.usageDetailsNano)
        XCTAssertTrue(reloaded.usageDetailsChromeless)
    }

    @MainActor
    func testCompactSettingDefaultsOffAndPersists() {
        let suite = "CompactUsageTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }

        let settings = SettingsStore(defaults: defaults)
        XCTAssertFalse(settings.usageDetailsCompact)
        settings.usageDetailsCompact = true
        XCTAssertTrue(SettingsStore(defaults: defaults).usageDetailsCompact)
    }

    @MainActor
    func testBackgroundOpacityDefaultsOpaqueAndPersistsClamped() {
        let suite = "CompactUsageTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }

        let settings = SettingsStore(defaults: defaults)
        XCTAssertEqual(settings.usageDetailsBackgroundOpacity, 1)
        settings.usageDetailsBackgroundOpacity = 0.35
        XCTAssertEqual(SettingsStore(defaults: defaults).usageDetailsBackgroundOpacity, 0.35, accuracy: 0.0001)

        defaults.set(4.0, forKey: "usageDetailsBackgroundOpacity")
        XCTAssertEqual(SettingsStore(defaults: defaults).usageDetailsBackgroundOpacity, 1)
    }

    @MainActor
    func testClearGlassDefaultsOffAndPersists() {
        let suite = "CompactUsageTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }

        let settings = SettingsStore(defaults: defaults)
        XCTAssertFalse(settings.usageDetailsClearGlass)
        settings.usageDetailsClearGlass = true
        XCTAssertTrue(SettingsStore(defaults: defaults).usageDetailsClearGlass)
    }
}

private struct CompactProvider: UsageProvider {
    let id: String
    let usedPercent: Double
    /// A shorter limit listed before the weekly one.
    var secondPercent: Double?
    var displayName: String { "Compact provider" }
    var shortCode: String { "C" }
    var isDetected: Bool { true }
    func fetch() async throws -> ProviderUsage {
        let weekly = UsageWindow(label: "Weekly limit", usedPercent: usedPercent,
                                 resetsAt: Date().addingTimeInterval(86400))
        let windows = secondPercent.map {
            [UsageWindow(label: "5h limit", usedPercent: $0, resetsAt: Date().addingTimeInterval(3600)), weekly]
        } ?? [weekly]
        return ProviderUsage(planName: "Test", windows: windows, asOf: Date())
    }
}
