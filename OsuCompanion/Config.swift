import Foundation

enum Config {
    static let defaultClientID = "75323"
    static let defaultProxyURL = "https://osucompanion-auth.egemen147hesabi.workers.dev/"
    static let defaultRedirectURI = "osuchat://oauth/callback"
    static let callbackScheme = "osuchat"
    static let authorizeURL = "https://osu.ppy.sh/oauth/authorize"
    static let apiBase = "https://osu.ppy.sh/api/v2"
    static let scopes = "public identify friends.read"
    static let mirror = "https://catboy.best/d/"

    static var clientID: String {
        get { UserDefaults.standard.string(forKey: "clientID") ?? defaultClientID }
        set { UserDefaults.standard.set(newValue, forKey: "clientID") }
    }
    static var proxyURL: String {
        get { UserDefaults.standard.string(forKey: "proxyURL") ?? defaultProxyURL }
        set { UserDefaults.standard.set(newValue, forKey: "proxyURL") }
    }
    static var redirectURI: String {
        get { UserDefaults.standard.string(forKey: "redirectURI") ?? defaultRedirectURI }
        set { UserDefaults.standard.set(newValue, forKey: "redirectURI") }
    }
}
