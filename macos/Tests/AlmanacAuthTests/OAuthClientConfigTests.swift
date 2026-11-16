import Foundation
import Testing
@testable import AlmanacAuth

@Suite struct OAuthClientConfigParseTests {
    @Test func parsesInstalledClient() throws {
        let json = """
        {"installed":{"client_id":"123.apps.googleusercontent.com","project_id":"p",
        "auth_uri":"https://accounts.google.com/o/oauth2/auth","token_uri":"https://oauth2.googleapis.com/token",
        "client_secret":"GOCSPX-secret","redirect_uris":["http://localhost"]}}
        """
        let config = try OAuthClientConfig.parse(Data(json.utf8))
        #expect(config == OAuthClientConfig(clientID: "123.apps.googleusercontent.com", clientSecret: "GOCSPX-secret"))
    }

    @Test func secretIsOptional() throws {
        let config = try OAuthClientConfig.parse(Data(#"{"installed":{"client_id":"abc"}}"#.utf8))
        #expect(config.clientID == "abc")
        #expect(config.clientSecret == nil)
    }

    @Test func emptySecretBecomesNil() throws {
        let config = try OAuthClientConfig.parse(Data(#"{"installed":{"client_id":"abc","client_secret":""}}"#.utf8))
        #expect(config.clientSecret == nil)
    }

    @Test(arguments: [
        #"{"installed":{"client_secret":"s"}}"#,
        #"{"installed":{"client_id":"","client_secret":"s"}}"#,
        #"{"installed":{"client_id":42}}"#,
    ])
    func missingClientIDFails(json: String) {
        #expect(throws: OAuthClientConfigError.invalid("Missing \"client_id\" in the \"installed\" section.")) {
            try OAuthClientConfig.parse(Data(json.utf8))
        }
    }

    @Test(arguments: [
        #"{"web":{"client_id":"abc","client_secret":"s"}}"#,
        #"{"client_id":"abc"}"#,
        #"[]"#,
    ])
    func missingInstalledSectionFails(json: String) {
        #expect {
            try OAuthClientConfig.parse(Data(json.utf8))
        } throws: { error in
            guard case .invalid(let reason) = error as? OAuthClientConfigError else { return false }
            return reason.contains("installed")
        }
    }

    @Test func invalidJSONFails() {
        #expect(throws: OAuthClientConfigError.invalid("The file is not valid JSON.")) {
            try OAuthClientConfig.parse(Data("not json".utf8))
        }
    }
}

@Suite struct OAuthClientConfigLookupTests {
    let home: URL

    init() throws {
        home = FileManager.default.temporaryDirectory.appending(path: "almanac-auth-tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
    }

    private func write(_ json: String, to relativePath: String) throws {
        let url = home.appending(path: relativePath)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(json.utf8).write(to: url)
    }

    private func client(_ id: String) -> String {
        #"{"installed":{"client_id":"\#(id)","client_secret":"secret-\#(id)"}}"#
    }

    @Test func defaultPathsAppSupportThenPlugin() {
        let paths = OAuthClientConfig.searchPaths(home: home, environment: [:]).map(\.path)
        #expect(paths == [
            home.appending(path: "Library/Application Support/Almanac/client.json").path,
            home.appending(path: ".config/menubar-calendar/credentials.json").path,
        ])
    }

    @Test func pluginDirFromEnvironment() {
        let paths = OAuthClientConfig.searchPaths(home: home, environment: ["MENUBAR_CAL_DIR": "/tmp/calcfg"])
        #expect(paths.map(\.path) == [
            home.appending(path: "Library/Application Support/Almanac/client.json").path,
            "/tmp/calcfg/credentials.json",
        ])
    }

    @Test func emptyEnvironmentValueIsIgnored() {
        let paths = OAuthClientConfig.searchPaths(home: home, environment: ["MENUBAR_CAL_DIR": ""])
        #expect(paths.last?.path == home.appending(path: ".config/menubar-calendar/credentials.json").path)
    }

    @Test func appSupportFileWins() throws {
        try write(client("app"), to: "Library/Application Support/Almanac/client.json")
        try write(client("plugin"), to: ".config/menubar-calendar/credentials.json")
        let config = try OAuthClientConfig.load(from: OAuthClientConfig.searchPaths(home: home, environment: [:]))
        #expect(config == OAuthClientConfig(clientID: "app", clientSecret: "secret-app"))
    }

    @Test func fallsBackToPluginFile() throws {
        try write(client("plugin"), to: ".config/menubar-calendar/credentials.json")
        let config = try OAuthClientConfig.load(from: OAuthClientConfig.searchPaths(home: home, environment: [:]))
        #expect(config.clientID == "plugin")
    }

    @Test func usesPluginDirFromEnvironment() throws {
        try write(client("plugin"), to: ".config/menubar-calendar/credentials.json")
        try write(client("custom"), to: "custom/credentials.json")
        let env = ["MENUBAR_CAL_DIR": home.appending(path: "custom").path]
        let config = try OAuthClientConfig.load(from: OAuthClientConfig.searchPaths(home: home, environment: env))
        #expect(config.clientID == "custom")
    }

    @Test func neitherFileExists() {
        let paths = OAuthClientConfig.searchPaths(home: home, environment: [:])
        #expect(throws: OAuthClientConfigError.notFound(searched: paths.map(\.path))) {
            try OAuthClientConfig.load(from: paths)
        }
    }

    @Test func brokenFirstFileIsReportedNotSkipped() throws {
        try write(#"{"web":{}}"#, to: "Library/Application Support/Almanac/client.json")
        try write(client("plugin"), to: ".config/menubar-calendar/credentials.json")
        let paths = OAuthClientConfig.searchPaths(home: home, environment: [:])
        #expect {
            try OAuthClientConfig.load(from: paths)
        } throws: { error in
            guard case .invalidFile(let path, _) = error as? OAuthClientConfigError else { return false }
            return path == paths[0].path
        }
    }
}
