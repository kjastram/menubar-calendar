import AlmanacKit
@preconcurrency import AppAuth
import AppKit
import Foundation

/// Google sign-in for several accounts, with one archived `OIDAuthState` per account in the Keychain.
///
/// AppAuth objects are not Sendable. They are created and used only inside this actor (or only on the
/// main actor during the browser step), and cross between the two only as archived `Data`.
public actor AuthService: TokenProvider {
    static let scopes = [
        "https://www.googleapis.com/auth/calendar.events",
        "https://www.googleapis.com/auth/calendar.readonly",
    ]
    static let authorizationEndpoint = URL(string: "https://accounts.google.com/o/oauth2/v2/auth")!
    static let tokenEndpoint = URL(string: "https://oauth2.googleapis.com/token")!
    static let revokeEndpoint = URL(string: "https://oauth2.googleapis.com/revoke")!
    static let primaryCalendarURL = URL(string: "https://www.googleapis.com/calendar/v3/calendars/primary")!
    /// Refresh this long before Google's expiry time, so a token doesn't run out mid-request.
    static let expiryMargin: TimeInterval = 60

    private let config: OAuthClientConfig
    private let keychain: KeychainStore
    private let session: URLSession
    private var states: [String: OIDAuthState] = [:]
    private var needsSignIn: Set<String> = []
    /// Access tokens Google rejected (401) though they haven't expired yet, by email.
    private var rejectedTokens: [String: String] = [:]
    private let refreshes = RefreshCoalescer()

    public init(config: OAuthClientConfig, keychain: KeychainStore = KeychainStore()) {
        self.config = config
        self.keychain = keychain
        self.session = URLSession(configuration: .ephemeral)
    }

    /// Opens the browser for Google sign-in (loopback redirect on 127.0.0.1, random port, PKCE),
    /// reads the account email from the primary calendar's id, saves the auth state in the Keychain
    /// under that email and returns the email. Cancelling the calling task stops waiting for the browser.
    public func signIn() async throws -> String {
        let archived = try await BrowserSignIn.run(config: config)
        let state = try Self.unarchiveState(archived)
        guard let token = state.lastTokenResponse?.accessToken else {
            throw AuthError.noAccessToken
        }
        let email = try await fetchEmail(accessToken: token)
        try keychain.save(try Self.archive(state), account: email)
        states[email] = state
        needsSignIn.remove(email)
        rejectedTokens[email] = nil
        return email
    }

    /// Revokes the grant on Google's side (best effort) and removes the account.
    public func signOut(_ email: String) async {
        let state = try? loadState(email)
        states[email] = nil
        needsSignIn.remove(email)
        rejectedTokens[email] = nil
        try? keychain.delete(account: email)
        if let token = state?.refreshToken ?? state?.lastTokenResponse?.accessToken {
            await revoke(token)
        }
    }

    public func signedInEmails() async -> [String] {
        (try? keychain.allAccounts()) ?? []
    }

    public func accessToken(for email: String) async throws -> String {
        let state = try loadState(email)
        if let token = Self.usableAccessToken(state.lastTokenResponse, rejected: rejectedTokens[email], now: Date()) {
            return token
        }
        return try await refreshes.run(email) { [self] in try await refresh(email) }
    }

    /// Marks the cached access token as rejected, so the next `accessToken(for:)` refreshes it.
    /// Call after Google answers 401 with it. With `token`, does nothing if that token was
    /// already replaced (another request refreshed in the meantime).
    public func invalidateAccessToken(for email: String, token: String? = nil) {
        guard let current = states[email]?.lastTokenResponse?.accessToken else { return }
        if let token, token != current { return }
        rejectedTokens[email] = current
    }

    /// Refreshes even if the cached access token hasn't expired yet, and returns the new one.
    public func forceRefresh(for email: String) async throws -> String {
        _ = try loadState(email)
        invalidateAccessToken(for: email)
        return try await accessToken(for: email)
    }

    /// Emails whose last refresh failed with invalid_grant (cleared on successful signIn).
    public func emailsNeedingSignIn() async -> Set<String> {
        needsSignIn
    }

    // MARK: - Refresh

    private func refresh(_ email: String) async throws -> String {
        let state = try loadState(email)
        // Another caller may have refreshed while this one waited.
        if let token = Self.usableAccessToken(state.lastTokenResponse, rejected: rejectedTokens[email], now: Date()) {
            return token
        }
        guard let request = state.tokenRefreshRequest() else {
            needsSignIn.insert(email)
            throw AlmanacError.needsSignIn(email: email)
        }
        let archivedResponse: Data
        do {
            archivedResponse = try await Self.perform(request)
        } catch {
            if Self.isInvalidGrant(error) {
                needsSignIn.insert(email)
                throw AlmanacError.needsSignIn(email: email)
            }
            throw error
        }
        // Signed out or signed in again while the request was running: don't write the old state back.
        // After a new sign-in, start over with the new state (usually its token is fresh). After a
        // sign-out, loadState finds no saved state and throws needsSignIn.
        guard states[email] === state else {
            return try await refresh(email)
        }
        let response = try Self.unarchive(OIDTokenResponse.self, from: archivedResponse)
        state.update(with: response, error: nil)
        try keychain.save(try Self.archive(state), account: email)
        needsSignIn.remove(email)
        rejectedTokens[email] = nil
        guard let token = response.accessToken else { throw AuthError.noAccessToken }
        return token
    }

    /// Sends the token request and returns the archived response. The callback is `@Sendable` so it
    /// isn't treated as isolated to this actor (AppAuth calls it on the main queue), and it only hands
    /// back Sendable values.
    private static func perform(_ request: OIDTokenRequest) async throws -> Data {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Data, any Error>) in
            OIDAuthorizationService.perform(request) { @Sendable response, error in
                if let response {
                    continuation.resume(with: Result { try archive(response) })
                } else {
                    continuation.resume(throwing: error ?? AuthError.noAccessToken)
                }
            }
        }
    }

    // MARK: - Helpers

    private func loadState(_ email: String) throws -> OIDAuthState {
        if let state = states[email] { return state }
        guard let data = try keychain.load(account: email) else {
            throw AlmanacError.needsSignIn(email: email)
        }
        guard let state = try? Self.unarchiveState(data) else {
            needsSignIn.insert(email)
            throw AlmanacError.needsSignIn(email: email)
        }
        states[email] = state
        return state
    }

    private func fetchEmail(accessToken: String) async throws -> String {
        var request = URLRequest(url: Self.primaryCalendarURL)
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        let (data, response) = try await session.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard (200..<300).contains(status) else {
            throw AlmanacError.api(status: status, message: Self.googleErrorMessage(data))
        }
        guard let id = (try? JSONSerialization.jsonObject(with: data) as? [String: Any])?["id"] as? String,
              !id.isEmpty else {
            throw AlmanacError.api(status: status, message: "The primary calendar has no id.")
        }
        return id
    }

    private func revoke(_ token: String) async {
        var request = URLRequest(url: Self.revokeEndpoint, timeoutInterval: 10)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        var form = URLComponents()
        form.queryItems = [URLQueryItem(name: "token", value: token)]
        request.httpBody = form.percentEncodedQuery?.data(using: .utf8)
        _ = try? await session.data(for: request)
    }

    static func freshAccessToken(_ response: OIDTokenResponse?, now: Date) -> String? {
        guard let token = response?.accessToken, let expiry = response?.accessTokenExpirationDate,
              expiry.timeIntervalSince(now) > expiryMargin else { return nil }
        return token
    }

    /// The cached token if it is fresh and Google hasn't rejected it.
    static func usableAccessToken(_ response: OIDTokenResponse?, rejected: String?, now: Date) -> String? {
        guard let token = freshAccessToken(response, now: now), token != rejected else { return nil }
        return token
    }

    static func isInvalidGrant(_ error: any Error) -> Bool {
        let error = error as NSError
        return error.domain == OIDOAuthTokenErrorDomain && error.code == OIDErrorCodeOAuth.invalidGrant.rawValue
    }

    static func googleErrorMessage(_ data: Data) -> String {
        let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        return (json?["error"] as? [String: Any])?["message"] as? String ?? ""
    }

    static func archive(_ object: NSObject & NSSecureCoding) throws -> Data {
        try NSKeyedArchiver.archivedData(withRootObject: object, requiringSecureCoding: true)
    }

    static func unarchive<T: NSObject & NSSecureCoding>(_ type: T.Type, from data: Data) throws -> T {
        guard let object = try NSKeyedUnarchiver.unarchivedObject(ofClass: type, from: data) else {
            throw AuthError.corruptState
        }
        return object
    }

    static func unarchiveState(_ data: Data) throws -> OIDAuthState {
        try unarchive(OIDAuthState.self, from: data)
    }
}

enum AuthError: Error, LocalizedError {
    case noAccessToken
    case corruptState

    var errorDescription: String? {
        switch self {
        case .noAccessToken: "Google didn't return an access token."
        case .corruptState: "The saved sign-in could not be read."
        }
    }
}

// MARK: - Browser step

/// The browser part of sign-in. Runs on the main actor because AppAuth's loopback server and
/// browser launch expect the main run loop.
@MainActor
final class BrowserSignIn {
    private let redirectHandler = OIDRedirectHTTPHandler(successURL: nil)

    /// Returns the archived `OIDAuthState` after the code exchange.
    static func run(config: OAuthClientConfig) async throws -> Data {
        let flow = BrowserSignIn()
        return try await withTaskCancellationHandler {
            try await flow.start(config: config)
        } onCancel: {
            Task { @MainActor in flow.cancel() }
        }
    }

    private func start(config: OAuthClientConfig) async throws -> Data {
        try Task.checkCancellation()
        var listenerError: NSError?
        let redirectURL = redirectHandler.startHTTPListener(&listenerError)
        if let listenerError { throw listenerError }
        // Closes the loopback listener on every exit (success, error, cancel). Once the flow has
        // finished, this does nothing else: AppAuth only calls the completion block once.
        defer { redirectHandler.cancelHTTPListener() }
        let request = OIDAuthorizationRequest(
            configuration: OIDServiceConfiguration(
                authorizationEndpoint: AuthService.authorizationEndpoint,
                tokenEndpoint: AuthService.tokenEndpoint),
            clientId: config.clientID,
            clientSecret: config.clientSecret,
            scopes: AuthService.scopes,
            redirectURL: redirectURL,
            responseType: OIDResponseTypeCode,
            additionalParameters: ["prompt": "select_account consent", "access_type": "offline"])
        do {
            return try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Data, any Error>) in
                // @Sendable: the callback must not be tied to the main actor's isolation checks, and it only
                // hands back Sendable values (archived Data or an error).
                redirectHandler.currentAuthorizationFlow = OIDAuthState.authState(
                    byPresenting: request, externalUserAgent: DefaultBrowserUserAgent()
                ) { @Sendable authState, error in
                    if let authState {
                        continuation.resume(with: Result { try AuthService.archive(authState) })
                    } else {
                        continuation.resume(throwing: error ?? AuthError.noAccessToken)
                    }
                }
            }
        } catch let error as NSError
            where error.domain == OIDGeneralErrorDomain
            && error.code == OIDErrorCode.programCanceledAuthorizationFlow.rawValue {
            throw CancellationError()
        }
    }

    private func cancel() {
        redirectHandler.cancelHTTPListener()
    }
}

/// Opens the request in the default browser (like the SwiftBar plugin), not in an
/// ASWebAuthenticationSession sheet. The loopback server receives the redirect.
private final class DefaultBrowserUserAgent: NSObject, OIDExternalUserAgent {
    func present(_ request: any OIDExternalUserAgentRequest, session: any OIDExternalUserAgentSession) -> Bool {
        let opened = NSWorkspace.shared.open(request.externalUserAgentRequestURL())
        if !opened {
            session.failExternalUserAgentFlowWithError(
                OIDErrorUtilities.error(with: .browserOpenError, underlyingError: nil,
                                        description: "Unable to open the browser."))
        }
        return opened
    }

    func dismiss(animated: Bool, completion: @escaping () -> Void) {
        completion()
    }
}
