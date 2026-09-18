//
//  AppLinks.swift
//  AutoFansMac
//
//  The external links the app itself offers, in one place so the About tab and the
//  documentation cannot end up pointing at different places.
//

import Foundation

enum AppLinks {

    /// The project's home — the destination of the About tab's GitHub button.
    ///
    /// The literal is fixed, so the force-unwrap is safe; a wrong URL would be a compile
    /// error the moment someone edits it into nonsense.
    static let repository = URL(string: "https://github.com/garyhooi/AutoFansMac")!

    /// Where the release notes live — the page the update check links to.
    static let releases = repository.appendingPathComponent("releases")
}
