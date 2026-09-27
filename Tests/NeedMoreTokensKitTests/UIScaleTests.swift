import CoreGraphics
import Foundation
import Testing
@testable import NeedMoreTokensKit

@Suite("UI size scaling")
struct UIScaleTests {

    @Test func clampsStepToRange() {
        #expect(UISize.clampedStep(-5) == UISize.minStep)
        #expect(UISize.clampedStep(99) == UISize.maxStep)
        #expect(UISize.clampedStep(3) == 3)
    }

    @Test func oddStepsSitHalfwayBetweenTheirNeighbors() {
        for step in (UISize.minStep + 1)..<UISize.maxStep where step % 2 == 1 {
            let mid = UISize.scale(for: step)
            let below = UISize.scale(for: step - 1)
            let above = UISize.scale(for: step + 1)
            #expect(abs(mid - (below + above) / 2) < 0.0001)
        }
        #expect(abs(UISize.scale(for: UISize.defaultStep) - 1.15) < 0.0001)
    }

    @Test func halfStepMigrationDoublesAnOldStepOnce() {
        let name = "nmt-ui-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        defer { defaults.removePersistentDomain(forName: name) }
        defaults.set(3, forKey: UISize.defaultsKey)
        UISize.migrateToHalfSteps(in: defaults)
        #expect(defaults.integer(forKey: UISize.defaultsKey) == 6)
        defaults.set(5, forKey: UISize.defaultsKey)
        UISize.migrateToHalfSteps(in: defaults)
        #expect(defaults.integer(forKey: UISize.defaultsKey) == 5)
    }

    @Test func halfStepMigrationUsesTheOldDefaultWhenNothingWasStored() {
        let name = "nmt-ui-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        defer { defaults.removePersistentDomain(forName: name) }
        UISize.migrateToHalfSteps(in: defaults)
        #expect(defaults.integer(forKey: UISize.defaultsKey) == UISize.defaultStep)
    }

    @Test func scaleIsStrictlyIncreasingAcrossSteps() {
        let scales = (UISize.minStep...UISize.maxStep).map { UISize.scale(for: $0) }
        for (smaller, larger) in zip(scales, scales.dropFirst()) {
            #expect(larger > smaller)
        }
    }

    @Test func defaultOpensBiggerThanBaselineAndAcompactOptionExists() {
        // The whole point of the fix: the default must read bigger than the cramped
        // macOS baseline, and there must be a sub-1.0 compact step below it.
        #expect(UISize.scale(for: UISize.defaultStep) > 1.0)
        #expect(UISize.scale(for: UISize.minStep) < 1.0)
    }

    @Test func outOfRangeStepsStillResolveToAnEndScale() {
        #expect(UISize.scale(for: -1) == UISize.scale(for: UISize.minStep))
        #expect(UISize.scale(for: 100) == UISize.scale(for: UISize.maxStep))
    }

    @Test func metricFloorsHairlinesAtOneAndKeepsZero() {
        #expect(UISize.metric(0, scale: 2) == 0)        // an intentional zero stays zero
        #expect(UISize.metric(1, scale: 0.9) == 1)      // a 1pt hairline never rounds away
        #expect(UISize.metric(10, scale: 1.5) == 15)
    }

    @Test func panelSizesScaleWithTheStep() {
        let small = UISize.panelDefaultSize(for: UISize.scale(for: UISize.minStep))
        let big = UISize.panelDefaultSize(for: UISize.scale(for: UISize.maxStep))
        #expect(big.width > small.width)
        #expect(big.height > small.height)
        #expect(UISize.panelMinSize(for: 1.0) == CGSize(width: 300, height: 220))
        // The min must never exceed the default at the same scale.
        let s = UISize.scale(for: UISize.maxStep)
        #expect(UISize.panelMinSize(for: s).width <= UISize.panelDefaultSize(for: s).width)
    }

    @Test func textRolesAreTitleAndBody() {
        #expect(TextRole.title.basePointSize == 13)
        #expect(TextRole.body.basePointSize == 11)
    }
}
