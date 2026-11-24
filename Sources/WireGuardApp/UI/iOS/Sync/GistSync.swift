// SPDX-License-Identifier: MIT

import Foundation
import Security

enum GistProvider: String {
    case gitee, github

    var title: String { self == .gitee ? "Gitee" : "GitHub" }
    var host: String { self == .gitee ? "gitee.com" : "api.github.com" }
    var path: String { self == .gitee ? "/api/v5/gists" : "/gists" }
}

enum GistSyncError: LocalizedError {
    case credentials, identifier, noTunnels, invalidBackup, incompatibleTunnel, invalidNodeFile
    case unexpectedResponse, publicGist, changedRemotely, changedLocally, keychain
    case http(Int)

    var errorDescription: String? {
        switch self {
        case .credentials: return tr("cloudSyncTokenRequired")
        case .identifier: return tr("cloudSyncIDInvalid")
        case .noTunnels: return tr("cloudSyncNoTunnels")
        case .invalidBackup: return tr("cloudSyncInvalidBackup")
        case .incompatibleTunnel: return tr("cloudSyncIncompatibleTunnel")
        case .invalidNodeFile: return tr("cloudSyncInvalidNodes")
        case .unexpectedResponse: return tr("cloudSyncUnexpectedResponse")
        case .publicGist: return tr("cloudSyncPublicGist")
        case .changedRemotely: return tr("cloudSyncRemoteChanged")
        case .changedLocally: return tr("cloudSyncLocalChanged")
        case .keychain: return tr("cloudSyncKeychain")
        case .http(let status): return tr(format: "cloudSyncHTTPError", status)
        }
    }
}

struct GistCredentials: Codable, Equatable {
    var token = ""
    var id = ""

    private static func keychainQuery(_ provider: GistProvider) -> [String: Any] {
        return [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: (Bundle.main.bundleIdentifier ?? "WG Connect") + ".gist-sync",
            kSecAttrAccount as String: provider.rawValue
        ]
    }

    static func load(for provider: GistProvider) throws -> GistCredentials {
        var query = keychainQuery(provider)
        query[kSecReturnData as String] = true
        var value: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &value)
        if status == errSecItemNotFound { return GistCredentials() }
        guard status == errSecSuccess, let data = value as? Data else { throw GistSyncError.keychain }
        return try JSONDecoder().decode(GistCredentials.self, from: data)
    }

    func save(for provider: GistProvider) throws {
        var query = Self.keychainQuery(provider)
        if token.isEmpty && id.isEmpty {
            let status = SecItemDelete(query as CFDictionary)
            guard status == errSecSuccess || status == errSecItemNotFound else { throw GistSyncError.keychain }
            return
        }
        let data = try JSONEncoder().encode(self)
        let update = [kSecValueData as String: data]
        let status = SecItemUpdate(query as CFDictionary, update as CFDictionary)
        if status == errSecSuccess { return }
        guard status == errSecItemNotFound else { throw GistSyncError.keychain }
        query[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
        query[kSecValueData as String] = data
        guard SecItemAdd(query as CFDictionary, nil) == errSecSuccess else { throw GistSyncError.keychain }
    }

    func normalized() throws -> GistCredentials {
        let trimmedToken = token.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedID = id.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmedID.isEmpty || trimmedID.range(of: "^[a-zA-Z0-9]+$", options: .regularExpression) != nil else {
            throw GistSyncError.identifier
        }
        return GistCredentials(token: trimmedToken, id: trimmedID)
    }
}

struct GistFile: Decodable {
    let content: String?
    let truncated: Bool?
    let rawURL: URL?

    enum CodingKeys: String, CodingKey {
        case content, truncated
        case rawURL = "raw_url"
    }
}

struct Gist: Decodable {
    let id: String
    let description: String?
    let isPublic: Bool
    let files: [String: GistFile]

    enum CodingKeys: String, CodingKey {
        case id, description, files
        case isPublic = "public"
    }
}

struct GistClient {
    let provider: GistProvider
    let credentials: GistCredentials
    private static let session = URLSession(configuration: .ephemeral, delegate: NoRedirects(), delegateQueue: nil)

    private struct FileContent: Encodable { let content: String }
    private struct Change: Encodable {
        let description: String?
        let files: [String: FileContent?]
        let isPublic: Bool?

        enum CodingKeys: String, CodingKey {
            case description, files
            case isPublic = "public"
        }
    }

    private final class NoRedirects: NSObject, URLSessionTaskDelegate {
        func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                        newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
            completionHandler(nil)
        }
    }

    func fetch() async throws -> Gist {
        guard !credentials.id.isEmpty else { throw GistSyncError.identifier }
        return try await send(method: "GET")
    }

    func write(file name: String, content: String, description: String) async throws -> Gist {
        let creating = credentials.id.isEmpty
        return try await send(method: creating ? "POST" : "PATCH",
                              change: Change(description: creating ? description : nil,
                                             files: [name: FileContent(content: content)], isPublic: creating ? false : nil))
    }

    func removeFile(named name: String) async throws -> Gist {
        guard !credentials.id.isEmpty else { throw GistSyncError.identifier }
        return try await send(method: "PATCH", change: Change(description: nil, files: [name: nil], isPublic: nil))
    }

    func read(_ file: GistFile) async throws -> String {
        if file.truncated != true, let content = file.content { return content }
        guard provider == .github, let url = file.rawURL, url.scheme == "https",
              url.host == "gist.githubusercontent.com", url.port == nil,
              url.user == nil, url.password == nil else { throw GistSyncError.unexpectedResponse }
        let data = try await Self.data(for: URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 30))
        guard let content = String(data: data, encoding: .utf8) else { throw GistSyncError.unexpectedResponse }
        return content
    }

    private func send(method: String, change: Change? = nil) async throws -> Gist {
        guard !credentials.token.isEmpty else { throw GistSyncError.credentials }
        var components = URLComponents()
        components.scheme = "https"
        components.host = provider.host
        components.path = provider.path + (credentials.id.isEmpty ? "" : "/" + credentials.id)
        guard let url = components.url else { throw GistSyncError.identifier }
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 30)
        request.httpMethod = method
        request.setValue(provider == .github ? "application/vnd.github+json" : "application/json", forHTTPHeaderField: "Accept")
        request.setValue("token " + credentials.token, forHTTPHeaderField: "Authorization")
        if let change = change {
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = try JSONEncoder().encode(change)
        }
        let data = try await Self.data(for: request)
        let gist = try JSONDecoder().decode(Gist.self, from: data)
        guard !gist.isPublic else { throw GistSyncError.publicGist }
        guard !gist.id.isEmpty, credentials.id.isEmpty || gist.id.caseInsensitiveCompare(credentials.id) == .orderedSame else {
            throw GistSyncError.unexpectedResponse
        }
        return gist
    }

    private static func data(for request: URLRequest) async throws -> Data {
        let (data, response) = try await session.data(for: request)
        guard let response = response as? HTTPURLResponse else { throw GistSyncError.unexpectedResponse }
        guard (200..<300).contains(response.statusCode) else { throw GistSyncError.http(response.statusCode) }
        return data
    }
}

struct TunnelBackup: Codable {
    struct Tunnel: Codable {
        let name: String
        let content: String
    }

    let version: Int
    let updatedAt: String
    let tunnels: [Tunnel]

    init(configurations: [TunnelConfiguration], date: Date) throws {
        guard !configurations.isEmpty else { throw GistSyncError.noTunnels }
        self.version = 1
        self.updatedAt = ISO8601DateFormatter().string(from: date)
        self.tunnels = try configurations.map {
            guard let name = $0.name, Self.isValidName(name) else { throw GistSyncError.incompatibleTunnel }
            return Tunnel(name: name, content: $0.asWgQuickConfig())
        }
    }

    static func decode(_ source: String) throws -> [TunnelConfiguration] {
        let decoder = JSONDecoder()
        decoder.allowsJSON5 = true
        guard let backup = try? decoder.decode(Self.self, from: Data(source.utf8)), backup.version == 1, !backup.tunnels.isEmpty,
              Set(backup.tunnels.map(\.name)).count == backup.tunnels.count else {
            throw GistSyncError.invalidBackup
        }
        return try backup.tunnels.map { tunnel in
            guard isValidName(tunnel.name) else { throw GistSyncError.invalidBackup }
            let content = try appleConfiguration(from: tunnel.content)
            guard let config = try? TunnelConfiguration(fromWgQuickConfig: content, called: tunnel.name) else {
                throw GistSyncError.invalidBackup
            }
            return config
        }
    }

    func encode() throws -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return String(decoding: try encoder.encode(self), as: UTF8.self) + "\n"
    }

    static func filename(date: Date, byteCount: Int) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "1.0.0"
        return "\(version)(\(formatter.string(from: date)))[\(byteCount)Byte].json5"
    }

    static func filenames(in gist: Gist) -> [String] {
        let dated = #"^\d+\.\d+\.\d+\(\d{8}-\d{6}\)(?:\[\d+Byte\])?\.json5$"#
        let versioned = #"^\d+\.\d+\.\d+\.json5$"#
        let names = gist.files.keys
        let datedNames = names.filter { $0.range(of: dated, options: .regularExpression) != nil }
        return datedNames.sorted { lhs, rhs in
            let lhsDate = lhs.split(separator: "(").last ?? ""
            let rhsDate = rhs.split(separator: "(").last ?? ""
            if lhsDate != rhsDate { return lhsDate > rhsDate }
            return lhs.compare(rhs, options: .numeric) == .orderedDescending
        } + names.filter { $0.range(of: versioned, options: .regularExpression) != nil }
            .sorted { $0.compare($1, options: .numeric) == .orderedDescending }
            + ["wireguard-harmony.json5", "wireguard-harmony.json"].filter { gist.files[$0] != nil }
            + names.filter { $0.hasPrefix("wg-") && $0.hasSuffix(".json5") }.sorted()
    }

    private static func isValidName(_ name: String) -> Bool {
        return !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && name.utf16.count <= 128
            && !name.contains("/") && !name.contains("\\") && name.rangeOfCharacter(from: .controlCharacters) == nil
    }

    private static func appleConfiguration(from content: String) throws -> String {
        let harmonyDiagnostics = ["testport", "testserverenabled", "tcpforward", "tcpforwardenabled"]
        var isInterface = false
        var lines: [Substring] = []
        for line in content.split(whereSeparator: \.isNewline) {
            let trimmed = line.prefix(while: { $0 != "#" }).trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("[") { isInterface = trimmed.lowercased() == "[interface]" }
            if isInterface, let equals = trimmed.firstIndex(of: "=") {
                let key = trimmed[..<equals].trimmingCharacters(in: .whitespaces).lowercased()
                if key == "includedapplications" || key == "excludedapplications" {
                    throw GistSyncError.incompatibleTunnel
                }
                if harmonyDiagnostics.contains(key) { continue }
            }
            lines.append(line)
        }
        return lines.joined(separator: "\n")
    }
}
