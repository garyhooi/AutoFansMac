//
//  GitHubReleases.swift
//  AutoFansMac
//
//  The one network request this app makes: "what is the latest release?" against GitHub's
//  public API. No token, no query string, no body — the request carries nothing about the
//  machine it comes from beyond the address it is sent from.
//

import Foundation

/// A published release, reduced to what the app shows and links to.
struct ReleaseInfo: Equatable, Sendable {

    /// The tag without its leading "v", e.g. "1.0.1".
    let version: String
    /// The release page on GitHub.
    let pageURL: URL
    /// A `.dmg` attached to the release, when it has one.
    let downloadURL: URL?

    /// True when this release is newer than `current`.
    ///
    /// A tag with no readable numbers is treated as new as soon as it differs: telling
    /// someone about a release they may already have is better than silently ignoring a
    /// numbering scheme this parser does not know.
    func isNewer(than current: String) -> Bool {
        guard let running = SemanticVersion(current), let latest = SemanticVersion(version) else {
            return version != current
        }
        return latest > running
    }
}

enum GitHubReleasesError: LocalizedError, Equatable {
    /// GitHub asked the client to slow down (60 requests an hour without a token).
    case rateLimited
    /// 404 for the *repository*: private, renamed, or never pushed. An anonymous client
    /// cannot tell those apart — GitHub hides private repositories behind the same answer.
    case repositoryNotVisible
    case http(Int)
    case malformed

    var errorDescription: String? {
        switch self {
        case .rateLimited: return "GitHub rate limit reached — try again later"
        case .repositoryNotVisible: return "No public repository at \(Self.repositorySlug)"
        case .http(let code): return "GitHub answered HTTP \(code)"
        case .malformed: return "Unexpected answer from GitHub"
        }
    }

    static let repositorySlug = "garyhooi/AutoFansMac"
}

/// Reads the latest release of the project's repository.
struct GitHubReleases {

    /// The repository itself — asked only to tell "no releases" apart from "not visible".
    static let repositoryURL = URL(string: "https://api.github.com/repos/\(GitHubReleasesError.repositorySlug)")!
    /// `GET /repos/{owner}/{repo}/releases/latest` — the newest non-draft, non-prerelease.
    static let latestReleaseURL = URL(string: "https://api.github.com/repos/\(GitHubReleasesError.repositorySlug)/releases/latest")!
    /// The same release, for a human.
    static let releasesPageURL = AppLinks.releases

    var session: URLSession = .shared

    /// - Returns: the latest release, or nil when the repository has no releases yet.
    ///   GitHub answers 404 for that, which is an answer rather than a failure.
    func latest() async throws -> ReleaseInfo? {
        var request = URLRequest(url: Self.latestReleaseURL, timeoutInterval: 15)
        // GitHub rejects a request with no User-Agent, and asks clients to pin the API
        // version so a change to the API is announced rather than sprung on the app.
        request.setValue("AutoFansMac/\(Bundle.main.shortVersion)", forHTTPHeaderField: "User-Agent")
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("2022-11-28", forHTTPHeaderField: "X-GitHub-Api-Version")

        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw GitHubReleasesError.malformed }

        switch http.statusCode {
        case 200: return try Self.decode(data)
        case 404:
            // GitHub answers 404 both for "this repository has no releases yet" and for a
            // repository the client may not see at all. Ask the repository endpoint which
            // one it is, so the app can tell the user something true either way.
            guard await repositoryIsVisible() else { throw GitHubReleasesError.repositoryNotVisible }
            return nil
        case 403, 429: throw GitHubReleasesError.rateLimited
        default: throw GitHubReleasesError.http(http.statusCode)
        }
    }

    /// True unless GitHub says the repository itself is not there.
    ///
    /// A failed probe (offline, timeout) is reported as visible on purpose: the honest
    /// answer to "is this a private repository?" is then unknown, and "no releases yet" is
    /// the less alarming of the two things the app could claim.
    private func repositoryIsVisible() async -> Bool {
        var request = URLRequest(url: Self.repositoryURL, timeoutInterval: 10)
        request.setValue("AutoFansMac/\(Bundle.main.shortVersion)", forHTTPHeaderField: "User-Agent")
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("2022-11-28", forHTTPHeaderField: "X-GitHub-Api-Version")

        guard let (_, response) = try? await session.data(for: request),
              let http = response as? HTTPURLResponse else { return true }
        return http.statusCode != 404
    }

    /// Decodes the subset of the release payload the app uses.
    static func decode(_ data: Data) throws -> ReleaseInfo {
        struct Payload: Decodable {
            struct Asset: Decodable {
                let name: String
                let browser_download_url: String
            }
            let tag_name: String
            let html_url: String
            let assets: [Asset]?
        }

        let payload: Payload
        do {
            payload = try JSONDecoder().decode(Payload.self, from: data)
        } catch {
            throw GitHubReleasesError.malformed
        }

        guard let page = URL(string: payload.html_url) else { throw GitHubReleasesError.malformed }

        // Prefer an attached disk image — that is what this project ships, and it saves the
        // user a click through the release page.
        let image = payload.assets?.first { $0.name.lowercased().hasSuffix(".dmg") }

        return ReleaseInfo(
            version: normalise(tag: payload.tag_name),
            pageURL: page,
            downloadURL: image.flatMap { URL(string: $0.browser_download_url) }
        )
    }

    /// "v1.0.1" and "1.0.1" are the same release; the tag is only a label.
    static func normalise(tag: String) -> String {
        var text = tag.trimmingCharacters(in: .whitespacesAndNewlines)
        if text.hasPrefix("v") || text.hasPrefix("V") { text.removeFirst() }
        return text
    }
}
