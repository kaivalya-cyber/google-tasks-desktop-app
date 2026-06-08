import Foundation
import AuthenticationServices
import Security
import CryptoKit

// MARK: - Auth Error

enum AuthError: LocalizedError {
    case missingConfiguration
    case userCancelled
    case invalidResponse
    case tokenExchangeFailed(String)
    case keychainError(OSStatus)
    case noRefreshToken
    case refreshFailed(String)

    var errorDescription: String? {
        switch self {
        case .missingConfiguration:
            return "OAuth2 client ID is not configured. Please update AppConstants.swift with your Google Cloud Console client ID."
        case .userCancelled:
            return "Sign in was cancelled."
        case .invalidResponse:
            return "Invalid response from Google."
        case .tokenExchangeFailed(let message):
            return "Token exchange failed: \(message)"
        case .keychainError(let status):
            return "Keychain error: \(status)"
        case .noRefreshToken:
            return "No refresh token available. Please sign in again."
        case .refreshFailed(let message):
            return "Token refresh failed: \(message)"
        }
    }
}

// MARK: - Token Response

struct TokenResponse: Codable {
    let accessToken: String
    let expiresIn: Int?
    let refreshToken: String?
    let scope: String
    let tokenType: String

    enum CodingKeys: String, CodingKey {
        case accessToken = "access_token"
        case expiresIn = "expires_in"
        case refreshToken = "refresh_token"
        case scope
        case tokenType = "token_type"
    }
}

// MARK: - Auth State

enum AuthState {
    case notSignedIn
    case signingIn
    case signedIn
    case refreshing
    case error(Error)
}

// MARK: - Auth Manager

/// Manages OAuth2 authentication for Google Tasks API.
/// Uses ASWebAuthenticationSession for the browser-based OAuth2 flow
/// and macOS Keychain for secure token storage.
@MainActor
final class AuthManager: ObservableObject {
    static let shared = AuthManager()

    @Published private(set) var authState: AuthState = .notSignedIn
    @Published private(set) var isAuthenticated: Bool = false

    private var tokenExpiryDate: Date?
    private var currentSession: ASWebAuthenticationSession?
    private var refreshContinuations: [CheckedContinuation<String, Error>] = []

    private init() {
        loadTokensFromKeychain()
    }

    // MARK: - Public API

    /// Returns a valid access token, refreshing if necessary
    func getAccessToken() async throws -> String {
        switch authState {
        case .notSignedIn:
            throw AuthError.noRefreshToken
        case .signingIn:
            throw AuthError.noRefreshToken
        case .refreshing:
            // Join the existing refresh operation instead of polling
            return try await withCheckedThrowingContinuation { continuation in
                refreshContinuations.append(continuation)
            }
        case .error(let error):
            throw error
        case .signedIn:
            if let token = try KeychainHelper.read(
                service: AppConstants.Keychain.service,
                account: AppConstants.Keychain.accessTokenKey
            ) {
                if let expiryStr = try KeychainHelper.read(
                    service: AppConstants.Keychain.service,
                    account: AppConstants.Keychain.tokenExpiryKey
                ), let expiryInterval = TimeInterval(expiryStr) {
                    let expiryDate = Date(timeIntervalSince1970: expiryInterval)
                    if Date() >= expiryDate {
                        return try await refreshAccessToken()
                    }
                }
                return token
            }
            throw AuthError.noRefreshToken
        }
    }

    /// Initiates the OAuth2 sign-in flow
    func signIn() async {
        guard authState != .signingIn, authState != .refreshing else { return }

        authState = .signingIn

        do {
            let tokens = try await performOAuthFlow()
            try storeTokens(tokens)
            authState = .signedIn
            isAuthenticated = true
            NotificationCenter.default.post(name: AppConstants.Notifications.didSignIn, object: nil)
        } catch {
            authState = .error(error)
            isAuthenticated = false
        }
    }

    /// Signs out by clearing stored tokens
    func signOut() {
        try? KeychainHelper.delete(
            service: AppConstants.Keychain.service,
            account: AppConstants.Keychain.accessTokenKey
        )
        try? KeychainHelper.delete(
            service: AppConstants.Keychain.service,
            account: AppConstants.Keychain.refreshTokenKey
        )
        try? KeychainHelper.delete(
            service: AppConstants.Keychain.service,
            account: AppConstants.Keychain.tokenExpiryKey
        )

        authState = .notSignedIn
        isAuthenticated = false
        tokenExpiryDate = nil

        NotificationCenter.default.post(name: AppConstants.Notifications.didSignOut, object: nil)
    }

    // MARK: - OAuth2 Flow

    /// Builds the OAuth2 authorization URL
    private func buildAuthURL() throws -> URL {
        let clientID = AppConstants.OAuth.clientID
        guard clientID != "YOUR_CLIENT_ID.apps.googleusercontent.com" else {
            throw AuthError.missingConfiguration
        }

        var components = URLComponents(string: AppConstants.OAuth.authorizationEndpoint)!
        components.queryItems = [
            URLQueryItem(name: "client_id", value: clientID),
            URLQueryItem(name: "redirect_uri", value: AppConstants.OAuth.redirectURI),
            URLQueryItem(name: "response_type", value: "code"),
            URLQueryItem(name: "scope", value: AppConstants.OAuth.scopes.joined(separator: " ")),
            URLQueryItem(name: "access_type", value: "offline"),
            URLQueryItem(name: "prompt", value: "consent")
        ]

        guard let url = components.url else {
            throw AuthError.invalidResponse
        }
        return url
    }

    /// Performs the full OAuth2 authorization code flow
    private func performOAuthFlow() async throws -> TokenResponse {
        let authURL = try buildAuthURL()
        let codeVerifier = generateCodeVerifier()
        let codeChallenge = generateCodeChallenge(from: codeVerifier)

        // Include PKCE parameters
        var components = URLComponents(url: authURL, resolvingAgainstBaseURL: false)!
        var queryItems = components.queryItems ?? []
        queryItems.append(URLQueryItem(name: "code_challenge", value: codeChallenge))
        queryItems.append(URLQueryItem(name: "code_challenge_method", value: "S256"))
        components.queryItems = queryItems

        guard let pkceURL = components.url else {
            throw AuthError.invalidResponse
        }

        // Show browser for authorization
        let authCode = try await presentAuthSession(url: pkceURL)
        let tokens = try await exchangeCodeForTokens(code: authCode, codeVerifier: codeVerifier)
        return tokens
    }

    /// Presents the ASWebAuthenticationSession for user login
    private func presentAuthSession(url: URL) async throws -> String {
        return try await withCheckedThrowingContinuation { continuation in
            let session = ASWebAuthenticationSession(
                url: url,
                callbackURLScheme: "com.google.tasks.desktop"
            ) { callbackURL, error in
                if let error = error {
                    let nsError = error as NSError
                    if nsError.domain == ASWebAuthenticationSessionErrorDomain
                        && nsError.code == ASWebAuthenticationSessionError.canceledLogin.rawValue {
                        continuation.resume(throwing: AuthError.userCancelled)
                    } else {
                        continuation.resume(throwing: error)
                    }
                    return
                }

                guard let callbackURL = callbackURL,
                      let components = URLComponents(url: callbackURL, resolvingAgainstBaseURL: false),
                      let code = components.queryItems?.first(where: { $0.name == "code" })?.value else {
                    continuation.resume(throwing: AuthError.invalidResponse)
                    return
                }

                continuation.resume(returning: code)
            }

            session.presentationContextProvider = AuthPresentationContext.shared
            session.prefersEphemeralWebBrowserSession = false
            session.start()

            self.currentSession = session
        }
    }

    /// Exchanges authorization code for tokens
    private func exchangeCodeForTokens(code: String, codeVerifier: String) async throws -> TokenResponse {
        let clientID = AppConstants.OAuth.clientID
        var request = URLRequest(url: URL(string: AppConstants.OAuth.tokenEndpoint)!)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")

        let bodyParams: [String: String] = [
            "code": code,
            "client_id": clientID,
            "redirect_uri": AppConstants.OAuth.redirectURI,
            "grant_type": "authorization_code",
            "code_verifier": codeVerifier
        ]

        request.httpBody = bodyParams
            .compactMap { key, value in
                "\(key)=\(value.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? value)"
            }
            .joined(separator: "&")
            .data(using: .utf8)

        let (data, response) = try await URLSession.shared.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse,
              (200...299).contains(httpResponse.statusCode) else {
            let errorBody = String(data: data, encoding: .utf8) ?? "Unknown error"
            throw AuthError.tokenExchangeFailed(errorBody)
        }

        return try JSONDecoder().decode(TokenResponse.self, from: data)
    }

    /// Refreshes the access token using the refresh token
    private func refreshAccessToken() async throws -> String {
        guard let refreshToken = try KeychainHelper.read(
            service: AppConstants.Keychain.service,
            account: AppConstants.Keychain.refreshTokenKey
        ) else {
            authState = .notSignedIn
            isAuthenticated = false
            throw AuthError.noRefreshToken
        }

        authState = .refreshing

        do {
            let clientID = AppConstants.OAuth.clientID
            var request = URLRequest(url: URL(string: AppConstants.OAuth.tokenEndpoint)!)
            request.httpMethod = "POST"
            request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")

            let bodyParams: [String: String] = [
                "refresh_token": refreshToken,
                "client_id": clientID,
                "grant_type": "refresh_token"
            ]

            request.httpBody = bodyParams
                .compactMap { key, value in
                    "\(key)=\(value.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? value)"
                }
                .joined(separator: "&")
                .data(using: .utf8)

            let (data, response) = try await URLSession.shared.data(for: request)

            guard let httpResponse = response as? HTTPURLResponse,
                  (200...299).contains(httpResponse.statusCode) else {
                let errorBody = String(data: data, encoding: .utf8) ?? "Unknown error"
                throw AuthError.refreshFailed(errorBody)
            }

            var tokens = try JSONDecoder().decode(TokenResponse.self, from: data)

            if tokens.refreshToken == nil {
                tokens = TokenResponse(
                    accessToken: tokens.accessToken,
                    expiresIn: tokens.expiresIn,
                    refreshToken: refreshToken,
                    scope: tokens.scope,
                    tokenType: tokens.tokenType
                )
            }

            try storeTokens(tokens)
            authState = .signedIn

            // Resume all waiting continuations with the new access token
            let continuations = refreshContinuations
            refreshContinuations = []
            for continuation in continuations {
                continuation.resume(returning: tokens.accessToken)
            }

            return tokens.accessToken
        } catch {
            // Resume all waiting continuations with the error
            let continuations = refreshContinuations
            refreshContinuations = []
            for continuation in continuations {
                continuation.resume(throwing: error)
            }

            authState = .error(AuthError.refreshFailed(error.localizedDescription))
            throw error
        }
    }

    // MARK: - Token Storage (Keychain)

    private func storeTokens(_ tokens: TokenResponse) throws {
        try KeychainHelper.save(
            service: AppConstants.Keychain.service,
            account: AppConstants.Keychain.accessTokenKey,
            data: tokens.accessToken
        )

        if let refreshToken = tokens.refreshToken {
            try KeychainHelper.save(
                service: AppConstants.Keychain.service,
                account: AppConstants.Keychain.refreshTokenKey,
                data: refreshToken
            )
        }

        if let expiresIn = tokens.expiresIn {
            let expiryDate = Date().addingTimeInterval(TimeInterval(expiresIn))
            let expiryTimestamp = String(expiryDate.timeIntervalSince1970)
            try KeychainHelper.save(
                service: AppConstants.Keychain.service,
                account: AppConstants.Keychain.tokenExpiryKey,
                data: expiryTimestamp
            )
            tokenExpiryDate = expiryDate
        }
    }

    private func loadTokensFromKeychain() {
        do {
            let hasAccessToken = try KeychainHelper.read(
                service: AppConstants.Keychain.service,
                account: AppConstants.Keychain.accessTokenKey
            ) != nil
            let hasRefreshToken = try KeychainHelper.read(
                service: AppConstants.Keychain.service,
                account: AppConstants.Keychain.refreshTokenKey
            ) != nil

            if hasAccessToken && hasRefreshToken {
                authState = .signedIn
                isAuthenticated = true
            }
        } catch {
            authState = .error(error)
            isAuthenticated = false
        }
    }

    // MARK: - PKCE Helpers

    private func generateCodeVerifier() -> String {
        var bytes = [UInt8](repeating: 0, count: 32)
        _ = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        return Data(bytes).base64URLEncodedString()
    }

    private func generateCodeChallenge(from verifier: String) -> String {
        let data = verifier.data(using: .ascii)!
        let hash = SHA256.hash(data: data)
        return Data(hash).base64URLEncodedString()
    }
}

// MARK: - ASWebAuthenticationSession Context Provider

final class AuthPresentationContext: NSObject, ASWebAuthenticationPresentationContextProviding {
    static let shared = AuthPresentationContext()

    func presentationAnchor(for session: ASWebAuthenticationSession) -> ASPresentationAnchor {
        return NSApp.keyWindow ?? NSApp.mainWindow ?? NSApp.windows.first!
    }
}

// MARK: - Keychain Helper

struct KeychainHelper {
    static func save(service: String, account: String, data: String) throws {
        guard let data = data.data(using: .utf8) else {
            throw AuthError.keychainError(errSecParam)
        }

        // Delete existing item first
        try? delete(service: service, account: account)

        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlock
        ]

        let status = SecItemAdd(query as CFDictionary, nil)
        guard status == errSecSuccess else {
            throw AuthError.keychainError(status)
        }
    }

    static func read(service: String, account: String) throws -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]

        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)

        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess else {
            throw AuthError.keychainError(status)
        }

        guard let data = item as? Data,
              let string = String(data: data, encoding: .utf8) else {
            return nil
        }

        return string
    }

    static func delete(service: String, account: String) throws {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]

        let status = SecItemDelete(query as CFDictionary)
        if status != errSecSuccess && status != errSecItemNotFound {
            throw AuthError.keychainError(status)
        }
    }
}

extension Data {
    func base64URLEncodedString() -> String {
        self.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}
