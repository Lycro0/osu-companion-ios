import Foundation
import AuthenticationServices
import CryptoKit
import UIKit

struct TokenResponse: Decodable {
    let accessToken: String
    let refreshToken: String?
    let expiresIn: Int?
}

enum AuthError: LocalizedError {
    case cancelled, badCallback, server(String)
    var errorDescription: String? {
        switch self {
        case .cancelled: return "Sign-in cancelled."
        case .badCallback: return "Unexpected callback from osu!. Check the redirect URI in Settings."
        case .server(let m): return m
        }
    }
}

@MainActor
final class AuthManager: NSObject, ObservableObject, ASWebAuthenticationPresentationContextProviding {
    @Published var isSignedIn: Bool = Keychain.get("refresh") != nil
    @Published var error: String?
    private var session: ASWebAuthenticationSession?
    private var server: LoopbackServer?
    private var handled = false

    func presentationAnchor(for session: ASWebAuthenticationSession) -> ASPresentationAnchor {
        UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .flatMap { $0.windows }
            .first { $0.isKeyWindow } ?? ASPresentationAnchor()
    }

    private static func b64url(_ data: Data) -> String {
        data.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    func signIn() {
        error = nil
        handled = false
        var bytes = [UInt8](repeating: 0, count: 48)
        _ = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        let verifier = Self.b64url(Data(bytes))
        let challenge = Self.b64url(Data(SHA256.hash(data: Data(verifier.utf8))))
        let state = UUID().uuidString
        let redirect = Config.redirectURI

        var comps = URLComponents(string: Config.authorizeURL)!
        comps.queryItems = [
            .init(name: "client_id", value: Config.clientID),
            .init(name: "redirect_uri", value: redirect),
            .init(name: "response_type", value: "code"),
            .init(name: "scope", value: Config.scopes),
            .init(name: "state", value: state),
            .init(name: "code_challenge", value: challenge),
            .init(name: "code_challenge_method", value: "S256")
        ]
        guard let url = comps.url else { return }

        let useLoopback = redirect.hasPrefix("http://127.0.0.1")

        let finish: (_ items: [URLQueryItem]) -> Void = { [weak self] items in
            Task { @MainActor in
                guard let self, !self.handled else { return }
                self.handled = true
                self.server?.stop()
                self.server = nil
                self.session?.cancel()
                guard items.first(where: { $0.name == "state" })?.value == state,
                      let code = items.first(where: { $0.name == "code" })?.value else {
                    self.error = AuthError.badCallback.localizedDescription
                    return
                }
                do {
                    let tok = try await Self.exchange([
                        "grant_type": "authorization_code",
                        "code": code,
                        "redirect_uri": redirect,
                        "code_verifier": verifier
                    ])
                    Self.store(tok)
                    self.isSignedIn = true
                } catch {
                    self.error = error.localizedDescription
                }
            }
        }

        if useLoopback {
            let port = URLComponents(string: redirect)?.port ?? 42069
            let srv = LoopbackServer()
            do {
                try srv.start(port: UInt16(port), onResult: finish)
            } catch {
                self.error = "Could not start local callback listener: \(error.localizedDescription)"
                return
            }
            server = srv
        }

        let s = ASWebAuthenticationSession(url: url, callbackURLScheme: Config.callbackScheme) { callback, err in
            Task { @MainActor [weak self] in
                guard let self, !self.handled else { return }
                if let err = err as? ASWebAuthenticationSessionError, err.code == .canceledLogin {
                    self.server?.stop(); self.server = nil
                    self.error = AuthError.cancelled.localizedDescription
                    return
                }
                if let err {
                    self.server?.stop(); self.server = nil
                    self.error = err.localizedDescription
                    return
                }
                if let callback {
                    finish(URLComponents(url: callback, resolvingAgainstBaseURL: false)?.queryItems ?? [])
                }
            }
        }
        s.presentationContextProvider = self
        s.prefersEphemeralWebBrowserSession = false
        session = s
        s.start()
    }

    func signOut() {
        Keychain.delete("access")
        Keychain.delete("refresh")
        Keychain.delete("expiry")
        isSignedIn = false
    }

    nonisolated static func store(_ t: TokenResponse) {
        Keychain.set(t.accessToken, for: "access")
        if let r = t.refreshToken { Keychain.set(r, for: "refresh") }
        let exp = Date().addingTimeInterval(TimeInterval((t.expiresIn ?? 3600) - 60))
        Keychain.set(String(exp.timeIntervalSince1970), for: "expiry")
    }

    nonisolated static func exchange(_ body: [String: String]) async throws -> TokenResponse {
        guard let url = URL(string: Config.proxyURL) else { throw AuthError.server("Invalid proxy URL") }
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try JSONSerialization.data(withJSONObject: body)
        let (data, resp) = try await URLSession.shared.data(for: req)
        let status = (resp as? HTTPURLResponse)?.statusCode ?? 0
        guard status == 200 else {
            let msg = String(data: data, encoding: .utf8) ?? "HTTP \(status)"
            throw AuthError.server("Token exchange failed (\(status)): \(msg)")
        }
        let dec = JSONDecoder()
        dec.keyDecodingStrategy = .convertFromSnakeCase
        return try dec.decode(TokenResponse.self, from: data)
    }
}
