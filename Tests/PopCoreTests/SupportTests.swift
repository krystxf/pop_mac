import Foundation
import Testing
@testable import PopCore

@Suite struct SupportTests {
    @Test func focusPicksNearestWindowInDirection() {
        let focused = Rect(0, 0, 800, 1000)
        let windows = [
            WindowCandidate(id: 2, rect: Rect(800, 0, 800, 500)),
            WindowCandidate(id: 3, rect: Rect(800, 500, 800, 500)),
        ]
        #expect(FocusSelector.select(.right, from: focused, among: windows) == 2)
        #expect(FocusSelector.select(.left, from: focused, among: windows) == nil)
        #expect(FocusSelector.select(.down, from: windows[0].rect, among: windows) == 3)
    }

    @Test func monitorLocatorFindsNeighbor() {
        let a = MonitorCandidate(id: 1, workArea: Rect(0, 0, 1600, 1000))
        let b = MonitorCandidate(id: 2, workArea: Rect(1600, 0, 1000, 800))
        #expect(MonitorLocator.locate(.right, from: a, among: [a, b])?.id == 2)
        #expect(MonitorLocator.locate(.left, from: a, among: [a, b]) == nil)
    }

    @Test func parsesKeyCombos() {
        let combo = KeyCombo.parse("<Super><Shift>Left", superModifiers: [.control, .option], primaryModifiers: [.command])
        #expect(combo == KeyCombo(key: "Left", modifiers: [.control, .option, .shift]))
        #expect(combo?.description == "⌃⌥⇧←")
        #expect(KeyCombo.parse("<Bogus>x", superModifiers: [], primaryModifiers: []) == nil)
        #expect(KeyCombo.parse("Escape", superModifiers: [], primaryModifiers: [])?.modifiers.isEmpty == true)
    }

    @Test func floatRulesMatch() {
        #expect(!FloatRules.windowShallFloat(appName: "Calculator", bundleID: "com.apple.calculator", title: "Calculator", userRules: []))
        // Keka floats by default, and a disabled user rule makes it tile.
        #expect(FloatRules.windowShallFloat(appName: "Keka", bundleID: "com.aone.keka", title: "Keka", userRules: []))
        #expect(!FloatRules.windowShallFloat(appName: "Keka", bundleID: "com.aone.keka", title: "Keka", userRules: [FloatRule(app: "Keka", disabled: true)]))
        let byApp = [FloatRule(app: "Terminal")]
        #expect(FloatRules.windowShallFloat(appName: "Terminal", bundleID: "com.apple.Terminal", title: "zsh", userRules: byApp))
        let byBundle = [FloatRule(app: "^com\\.apple\\.calculator$")]
        #expect(FloatRules.windowShallFloat(appName: "Calculator", bundleID: "com.apple.calculator", title: "", userRules: byBundle))
        let byTitle = [FloatRule(app: "Slack", title: "huddle")]
        #expect(FloatRules.windowShallFloat(appName: "Slack", bundleID: "com.tinyspeck.slackmacgap", title: "Huddle with Ana", userRules: byTitle))
        #expect(!FloatRules.windowShallFloat(appName: "Slack", bundleID: "com.tinyspeck.slackmacgap", title: "general", userRules: byTitle))
        // An earlier disabled rule wins over a later matching rule.
        let override = [FloatRule(app: "Finder", title: "Applications", disabled: true), FloatRule(app: "Finder")]
        #expect(!FloatRules.windowShallFloat(appName: "Finder", bundleID: "com.apple.finder", title: "Applications", userRules: override))
        #expect(FloatRules.windowShallFloat(appName: "Finder", bundleID: "com.apple.finder", title: "Downloads", userRules: override))
    }

    @Test func settingsDecodeFloatRules() throws {
        let json = #"{"floatRules": [{"app": "Calculator"}, {"title": "Picture in Picture", "disabled": false}]}"#
        let settings = try JSONDecoder().decode(Settings.self, from: Data(json.utf8))
        #expect(settings.floatRules == [FloatRule(app: "Calculator"), FloatRule(title: "Picture in Picture", disabled: false)])
    }

    @Test func settingsDecodeWithDefaults() throws {
        let json = #"{"gapInner": 4, "keybindings": {"focus-left": ["<Super>a"]}}"#
        let settings = try JSONDecoder().decode(Settings.self, from: Data(json.utf8))
        #expect(settings.gapInner == 4)
        #expect(settings.gapOuter == 8)
        #expect(settings.bindings(for: .focusLeft) == ["<Super>a"])
        #expect(settings.bindings(for: .focusRight) == ["<Super>Right", "<Super>l"])
    }

    @Test func gridChangeSnapsToCells() {
        let monitor = Rect(0, 0, 1280, 768)
        let cell = Grid.cell(monitor: monitor, columnSize: 64, rowSize: 64)
        #expect(cell.width == 64)
        let moved = Grid.change(Rect(0, 0, 640, 384), cell: cell, dx: 1, dy: 0, dw: 0, dh: 0, monitors: [monitor])
        #expect(moved == Rect(64, 0, 640, 384))
        let blocked = Grid.change(Rect(0, 0, 640, 384), cell: cell, dx: -1, dy: 0, dw: 0, dh: 0, monitors: [monitor])
        #expect(blocked == Rect(0, 0, 640, 384))
    }

    @Test func movementCalculation() {
        let from = Rect(0, 0, 100, 100)
        #expect(Movement.calculate(from: from, change: Rect(0, 0, 150, 100)) == [.grow, .right])
        #expect(Movement.calculate(from: from, change: Rect(0, 0, 100, 100)) == .none)
        #expect(Movement.calculate(from: from, change: Rect(10, 0, 90, 100)) == [.shrink, .right])
        #expect(Movement.calculate(from: from, change: Rect(5, 5, 100, 100)) == .moved)
    }
}
