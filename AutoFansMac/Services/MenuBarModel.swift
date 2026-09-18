//
//  MenuBarModel.swift
//  AutoFansMac
//
//  The menu-bar dropdown's own, deliberately quiet, observable state.
//
//  `MenuBarView` must NOT observe `AppEnvironment` directly. The environment re-emits every
//  child service's changes, and the sensor and fan services publish every poll tick — so a
//  view holding the environment re-renders once a second. For `MenuBarExtra` with the `.menu`
//  style the content *is* an `NSMenu`: re-evaluating it rebuilds the menu, which closes any
//  open submenu. The symptom was "the sub-menu keeps flashing, so I cannot switch the selected
//  fan to another mode" — the user could never complete a click.
//
//  This model publishes only what the menu actually *shows and acts on* — fan rows, the profile
//  list, the active profile, the thermal override, helper availability — and each value is
//  compared before assignment, so a poll tick that changes nothing structural publishes nothing.
//
//  Live values (RPM, temperatures) deliberately do not appear here. They belong in the menu-bar
//  *label*, which is a status-item view and updates freely without disturbing a menu, and in the
//  main window.
//

import Foundation
import Combine

/// One fan row in the dropdown. Carries no live readings, on purpose.
struct MenuBarFanRow: Identifiable, Equatable {
    let id: Int
    let name: String
    let mode: FanControlMode

    /// Stable for as long as the mode does — see the type comment.
    var title: String {
        name.isEmpty ? "Fan \(id)" : "\(name) — \(mode.displayName)"
    }
}

@MainActor
final class MenuBarModel: ObservableObject {

    @Published private(set) var fanRows: [MenuBarFanRow] = []
    @Published private(set) var profiles: [Profile] = []
    @Published private(set) var activeProfileID: String = ""
    @Published private(set) var safetyOverride = false
    @Published private(set) var helperSummary: String = ""

    private weak var environment: AppEnvironment?
    private var childObserver: AnyCancellable?

    init(environment: AppEnvironment) {
        self.environment = environment

        // `objectWillChange` fires *before* the value is stored, so the recomputation is hopped
        // to the next run-loop turn — otherwise every refresh would read the previous values and
        // the menu would lag one tick behind reality.
        childObserver = environment.objectWillChange
            .receive(on: DispatchQueue.main)
            .sink { [weak self] in self?.refresh() }

        refresh()
    }

    /// Recomputes the menu's structural state. Safe to call as often as you like: it only
    /// publishes the parts that actually changed.
    func refresh() {
        guard let environment else { return }

        let rows = environment.fans.states.map {
            MenuBarFanRow(id: $0.index, name: $0.name, mode: $0.setting.mode)
        }
        if rows != fanRows { fanRows = rows }

        let profileList = environment.profiles.profiles
        if profileList != profiles { profiles = profileList }

        let active = environment.profiles.document.activeProfileID
        if active != activeProfileID { activeProfileID = active }

        let overriding = environment.safety.state.isOverriding
        if overriding != safetyOverride { safetyOverride = overriding }

        let summary = environment.helper.installationState.isUsable
            ? "Helper running"
            : environment.helper.installationState.displayName
        if summary != helperSummary { helperSummary = summary }
    }
}
