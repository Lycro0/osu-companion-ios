import Foundation

enum APIError: LocalizedError {
    case notSignedIn, http(Int)
    var errorDescription: String? {
        switch self {
        case .notSignedIn: return "Not signed in."
        case .http(let c): return "osu! API error (HTTP \(c))."
        }
    }
}

actor API {
    static let shared = API()
    private let decoder: JSONDecoder = {
        let d = JSONDecoder()
        d.keyDecodingStrategy = .convertFromSnakeCase
        return d
    }()

    private func validToken() async throws -> String {
        if let access = Keychain.get("access"),
           let exp = Keychain.get("expiry").flatMap(Double.init),
           Date().timeIntervalSince1970 < exp {
            return access
        }
        return try await refresh()
    }

    private func refresh() async throws -> String {
        guard let r = Keychain.get("refresh") else { throw APIError.notSignedIn }
        let tok = try await AuthManager.exchange(["grant_type": "refresh_token", "refresh_token": r])
        AuthManager.store(tok)
        return tok.accessToken
    }

    func get<T: Decodable>(_ path: String, query: [URLQueryItem] = []) async throws -> T {
        var token = try await validToken()
        for attempt in 0..<2 {
            var comps = URLComponents(string: Config.apiBase + path)!
            if !query.isEmpty { comps.queryItems = query }
            var req = URLRequest(url: comps.url!)
            req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
            req.setValue("application/json", forHTTPHeaderField: "Accept")
            req.setValue("20220705", forHTTPHeaderField: "x-api-version")
            let (data, resp) = try await URLSession.shared.data(for: req)
            let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
            if code == 401 && attempt == 0 {
                token = try await refresh()
                continue
            }
            guard (200..<300).contains(code) else { throw APIError.http(code) }
            return try decoder.decode(T.self, from: data)
        }
        throw APIError.http(401)
    }

    func me(_ r: Ruleset) async throws -> User { try await get("/me/\(r.rawValue)") }
    func user(_ key: String, _ r: Ruleset) async throws -> User {
        try await get("/users/\(key)/\(r.rawValue)")
    }
    func scores(userID: Int, type: String, ruleset: Ruleset) async throws -> [Score] {
        try await get("/users/\(userID)/scores/\(type)", query: [
            .init(name: "mode", value: ruleset.rawValue),
            .init(name: "limit", value: "50"),
            .init(name: "include_fails", value: "0")
        ])
    }
    func rankings(_ r: Ruleset, country: String?, page: Int) async throws -> [RankingEntry] {
        var q: [URLQueryItem] = [.init(name: "cursor[page]", value: String(page))]
        if let c = country, !c.isEmpty { q.append(.init(name: "country", value: c.uppercased())) }
        let res: RankingResponse = try await get("/rankings/\(r.rawValue)/performance", query: q)
        return res.ranking
    }
    func searchBeatmaps(_ text: String, _ r: Ruleset) async throws -> [Beatmapset] {
        let res: SearchResponse = try await get("/beatmapsets/search", query: [
            .init(name: "q", value: text),
            .init(name: "m", value: String(r.searchCode))
        ])
        return res.beatmapsets
    }
    func friends() async throws -> [Relation] { try await get("/friends") }
}
