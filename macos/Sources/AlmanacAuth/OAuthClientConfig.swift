import Foundation

/// The OAuth "Desktop app" client from Google Cloud.
public struct OAuthClientConfig: Sendable, Equatable {
    public var clientID: String
    public var clientSecret: String?

    public init(clientID: String, clientSecret: String? = nil) {
        self.clientID = clientID
        self.clientSecret = clientSecret
    }

    /// Looks in ~/Library/Application Support/Almanac/client.json first, then the SwiftBar plugin's
    /// ~/.config/menubar-calendar/credentials.json (or $MENUBAR_CAL_DIR/credentials.json). Both use Google's
    /// downloaded "installed" client JSON format: {"installed": {"client_id", "client_secret", ...}}.
    public static func load() throws -> OAuthClientConfig {
        try load(from: searchPaths(home: URL.homeDirectory, environment: ProcessInfo.processInfo.environment))
    }

    public static func parse(_ data: Data) throws -> OAuthClientConfig {
        let root: Any
        do {
            root = try JSONSerialization.jsonObject(with: data)
        } catch {
            throw OAuthClientConfigError.invalid("The file is not valid JSON.")
        }
        guard let installed = (root as? [String: Any])?["installed"] as? [String: Any] else {
            throw OAuthClientConfigError.invalid(
                "Missing the \"installed\" section. Download the client JSON of a Google \"Desktop app\" OAuth client.")
        }
        guard let clientID = installed["client_id"] as? String, !clientID.isEmpty else {
            throw OAuthClientConfigError.invalid("Missing \"client_id\" in the \"installed\" section.")
        }
        let secret = installed["client_secret"] as? String
        return OAuthClientConfig(clientID: clientID, clientSecret: (secret?.isEmpty ?? true) ? nil : secret)
    }

    /// Files checked by `load()`, in order.
    static func searchPaths(home: URL, environment: [String: String]) -> [URL] {
        let pluginDir: URL
        if let dir = environment["MENUBAR_CAL_DIR"], !dir.isEmpty {
            pluginDir = URL(fileURLWithPath: (dir as NSString).expandingTildeInPath, isDirectory: true)
        } else {
            pluginDir = home.appending(path: ".config/menubar-calendar", directoryHint: .isDirectory)
        }
        return [
            home.appending(path: "Library/Application Support/Almanac/client.json"),
            pluginDir.appending(path: "credentials.json"),
        ]
    }

    /// Parses the first file in `paths` that exists. A file that exists but can't be parsed is an error
    /// (it is not skipped), so a broken file is reported instead of silently using another one.
    static func load(from paths: [URL]) throws -> OAuthClientConfig {
        for url in paths where FileManager.default.fileExists(atPath: url.path) {
            let data: Data
            do {
                data = try Data(contentsOf: url)
            } catch {
                throw OAuthClientConfigError.unreadable(path: url.path, reason: error.localizedDescription)
            }
            do {
                return try parse(data)
            } catch OAuthClientConfigError.invalid(let reason) {
                throw OAuthClientConfigError.invalidFile(path: url.path, reason: reason)
            }
        }
        throw OAuthClientConfigError.notFound(searched: paths.map(\.path))
    }
}

public enum OAuthClientConfigError: Error, Equatable, Sendable, LocalizedError {
    /// None of the files exist.
    case notFound(searched: [String])
    case unreadable(path: String, reason: String)
    /// The JSON given to `parse` is not a Google "installed" client.
    case invalid(String)
    /// Like `invalid`, for a file found by `load()`.
    case invalidFile(path: String, reason: String)

    public var errorDescription: String? {
        switch self {
        case .notFound(let searched):
            "No Google OAuth client found. Create a \"Desktop app\" OAuth client in Google Cloud, download its JSON "
                + "and save it as \(searched.first ?? "client.json")."
        case .unreadable(let path, let reason): "Can't read \(path): \(reason)"
        case .invalid(let reason): reason
        case .invalidFile(let path, let reason): "\(path): \(reason)"
        }
    }
}
