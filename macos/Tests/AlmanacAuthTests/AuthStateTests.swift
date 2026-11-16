import AppAuth
import Foundation
import Testing
@testable import AlmanacAuth

/// Builds an OIDAuthState the way a finished Google sign-in would, without the network.
private func makeAuthState(expiresIn seconds: Int) -> OIDAuthState {
    let configuration = OIDServiceConfiguration(
        authorizationEndpoint: AuthService.authorizationEndpoint, tokenEndpoint: AuthService.tokenEndpoint)
    let authRequest = OIDAuthorizationRequest(
        configuration: configuration, clientId: "client-id", clientSecret: "client-secret",
        scopes: AuthService.scopes, redirectURL: URL(string: "http://127.0.0.1:51234/")!,
        responseType: OIDResponseTypeCode, additionalParameters: nil)
    let authResponse = OIDAuthorizationResponse(
        request: authRequest, parameters: ["code": "auth-code" as NSString, "state": authRequest.state! as NSString])
    let tokenRequest = authResponse.tokenExchangeRequest()!
    let tokenResponse = OIDTokenResponse(request: tokenRequest, parameters: [
        "access_token": "access-1" as NSString,
        "refresh_token": "refresh-1" as NSString,
        "expires_in": NSNumber(value: seconds),
        "token_type": "Bearer" as NSString,
    ])
    return OIDAuthState(authorizationResponse: authResponse, tokenResponse: tokenResponse)
}

@Suite struct AuthStateTests {
    @Test func archiveRoundTripKeepsRefreshTokenAndClientSecret() throws {
        let data = try AuthService.archive(makeAuthState(expiresIn: 3600))
        let state = try AuthService.unarchiveState(data)
        #expect(state.refreshToken == "refresh-1")
        #expect(state.lastTokenResponse?.accessToken == "access-1")
        let refresh = try #require(state.tokenRefreshRequest())
        #expect(refresh.refreshToken == "refresh-1")
        #expect(refresh.clientSecret == "client-secret")
        #expect(refresh.configuration.tokenEndpoint == AuthService.tokenEndpoint)
    }

    @Test func requestedScopes() {
        #expect(makeAuthState(expiresIn: 3600).lastAuthorizationResponse.request.scope
            == "https://www.googleapis.com/auth/calendar.events https://www.googleapis.com/auth/calendar.readonly")
    }

    @Test func garbageIsNotAState() {
        #expect(throws: (any Error).self) { try AuthService.unarchiveState(Data("nope".utf8)) }
    }

    @Test func freshTokenIsUsedAsIs() {
        let state = makeAuthState(expiresIn: 3600)
        #expect(AuthService.freshAccessToken(state.lastTokenResponse, now: Date()) == "access-1")
    }

    @Test func tokenCloseToExpiryNeedsRefresh() {
        let state = makeAuthState(expiresIn: 30)
        #expect(AuthService.freshAccessToken(state.lastTokenResponse, now: Date()) == nil)
        let later = makeAuthState(expiresIn: 3600)
        #expect(AuthService.freshAccessToken(later.lastTokenResponse, now: Date().addingTimeInterval(3590)) == nil)
    }

    @Test func rejectedTokenNeedsRefreshEvenIfFresh() {
        let state = makeAuthState(expiresIn: 3600)
        #expect(AuthService.usableAccessToken(state.lastTokenResponse, rejected: "access-1", now: Date()) == nil)
    }

    @Test func tokenOtherThanTheRejectedOneIsUsed() {
        let state = makeAuthState(expiresIn: 3600)
        #expect(AuthService.usableAccessToken(state.lastTokenResponse, rejected: "access-0", now: Date()) == "access-1")
        #expect(AuthService.usableAccessToken(state.lastTokenResponse, rejected: nil, now: Date()) == "access-1")
    }

    @Test func expiredTokenIsNotUsableEvenIfNotRejected() {
        let state = makeAuthState(expiresIn: 30)
        #expect(AuthService.usableAccessToken(state.lastTokenResponse, rejected: nil, now: Date()) == nil)
    }

    @Test func missingResponseNeedsRefresh() {
        #expect(AuthService.freshAccessToken(nil, now: Date()) == nil)
    }

    @Test func invalidGrantIsRecognized() {
        let invalidGrant = NSError(domain: OIDOAuthTokenErrorDomain, code: OIDErrorCodeOAuth.invalidGrant.rawValue)
        #expect(AuthService.isInvalidGrant(invalidGrant))
        let otherOAuth = NSError(domain: OIDOAuthTokenErrorDomain, code: OIDErrorCodeOAuth.invalidClient.rawValue)
        #expect(!AuthService.isInvalidGrant(otherOAuth))
        let network = NSError(domain: NSURLErrorDomain, code: NSURLErrorNotConnectedToInternet)
        #expect(!AuthService.isInvalidGrant(network))
    }

    @Test func googleErrorMessageIsExtracted() {
        let body = #"{"error":{"code":403,"message":"Request had insufficient authentication scopes."}}"#
        #expect(AuthService.googleErrorMessage(Data(body.utf8)) == "Request had insufficient authentication scopes.")
        #expect(AuthService.googleErrorMessage(Data("x".utf8)) == "")
    }
}
