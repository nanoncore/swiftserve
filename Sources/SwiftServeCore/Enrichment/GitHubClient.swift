import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// Thin async wrapper over the GitHub REST API. Uses `URLSession.shared` (no
/// extra dependency) with a per-request timeout. Every call throws on failure so
/// the enrichment layer can swallow errors per-repo and degrade to neutral.
struct GitHubClient: Sendable {
    let token: String?
    let timeout: TimeInterval

    init(token: String?, timeout: TimeInterval = 10) {
        self.token = token
        self.timeout = timeout
    }

    enum GitHubError: Error { case badURL, notHTTP, status(Int) }

    private func makeRequest(_ urlString: String) throws -> URLRequest {
        guard let url = URL(string: urlString) else { throw GitHubError.badURL }
        var req = URLRequest(url: url)
        req.timeoutInterval = timeout
        req.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        req.setValue("SwiftServe", forHTTPHeaderField: "User-Agent")  // GitHub requires a UA
        if let token, !token.isEmpty {
            req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }
        return req
    }

    private func send(_ urlString: String) async throws -> (Data, HTTPURLResponse) {
        let (data, resp) = try await URLSession.shared.data(for: makeRequest(urlString))
        guard let http = resp as? HTTPURLResponse else { throw GitHubError.notHTTP }
        guard (200..<300).contains(http.statusCode) else { throw GitHubError.status(http.statusCode) }
        return (data, http)
    }

    private static let decoder: JSONDecoder = {
        let d = JSONDecoder()
        d.keyDecodingStrategy = .convertFromSnakeCase
        d.dateDecodingStrategy = .iso8601
        return d
    }()

    /// `GET /repos/{owner}/{repo}` — archived flag, last push, license.
    func repo(owner: String, name: String) async throws -> GitHubRepo {
        let (data, _) = try await send("https://api.github.com/repos/\(owner)/\(name)")
        return try Self.decoder.decode(GitHubRepo.self, from: data)
    }

    /// `GET /repos/{owner}/{repo}/tags` — newest 100 tags; we pick the max semver.
    func latestTag(owner: String, name: String) async throws -> String? {
        let (data, _) = try await send("https://api.github.com/repos/\(owner)/\(name)/tags?per_page=100")
        let tags = try Self.decoder.decode([GitHubTag].self, from: data)
        return GitHubParsing.maxSemverTag(tags.map(\.name))
    }

    /// Contributor count via the cheap `per_page=1` + `Link: rel="last"` trick.
    func contributorCount(owner: String, name: String) async throws -> Int {
        let (data, http) = try await send(
            "https://api.github.com/repos/\(owner)/\(name)/contributors?per_page=1&anon=true")
        if let link = http.value(forHTTPHeaderField: "Link"),
           let last = GitHubParsing.lastPage(fromLinkHeader: link) {
            return last
        }
        // No "last" link → 0 or 1 contributors; fall back to counting returned items.
        let items = (try? Self.decoder.decode([AnyItem].self, from: data))?.count ?? 0
        return items
    }

    /// Decodes any JSON array element — used only to count items.
    private struct AnyItem: Decodable {}
}

struct GitHubRepo: Decodable {
    let archived: Bool?
    let pushedAt: Date?
    let license: LicenseField?

    struct LicenseField: Decodable {
        let spdxId: String?
    }
}

struct GitHubTag: Decodable {
    let name: String
}

/// Pure, network-free parsing helpers — unit-tested directly. The identity
/// logic now lives in `RepoIdentity` (promoted for the capability pipeline);
/// these wrappers keep enrichment call sites untouched.
enum GitHubParsing {
    static func ownerRepo(from location: String) -> (owner: String, repo: String)? {
        RepoIdentity.ownerRepo(from: location)
    }

    /// The highest semantic version among raw tag strings (ignores non-semver).
    static func maxSemverTag(_ tags: [String]) -> String? {
        tags
            .compactMap { tag -> (SemVer, String)? in SemVer(tag).map { ($0, tag) } }
            .max { $0.0 < $1.0 }?
            .1
    }

    /// Parse the page number of the `rel="last"` entry from a GitHub `Link` header.
    static func lastPage(fromLinkHeader header: String) -> Int? {
        for part in header.split(separator: ",") {
            guard part.contains("rel=\"last\"") else { continue }
            guard let lt = part.firstIndex(of: "<"), let gt = part.firstIndex(of: ">") else { continue }
            let urlStr = String(part[part.index(after: lt)..<gt])
            if let comps = URLComponents(string: urlStr),
               let page = comps.queryItems?.first(where: { $0.name == "page" })?.value {
                return Int(page)
            }
        }
        return nil
    }

    /// Map a GitHub SPDX id to a license awareness bucket.
    static func license(fromSPDX spdx: String?) -> License {
        guard let id = spdx, !id.isEmpty, id != "NOASSERTION" else { return .unknown }
        let permissive: Set<String> = [
            "MIT", "Apache-2.0", "BSD-2-Clause", "BSD-3-Clause", "ISC",
            "0BSD", "Unlicense", "Zlib", "BSL-1.0", "MIT-0",
        ]
        let copyleft: Set<String> = [
            "GPL-2.0", "GPL-3.0", "GPL-2.0-only", "GPL-3.0-only", "GPL-3.0-or-later",
            "LGPL-2.1", "LGPL-3.0", "LGPL-3.0-only", "AGPL-3.0", "MPL-2.0", "EPL-2.0",
        ]
        if permissive.contains(id) { return .permissive }
        if copyleft.contains(id) { return .copyleft }
        return .unknown
    }
}
