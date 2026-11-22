import Foundation

enum Ruleset: String, CaseIterable, Identifiable {
    case osu, taiko, fruits, mania
    var id: String { rawValue }
    var title: String {
        switch self {
        case .osu: return "osu!"
        case .taiko: return "taiko"
        case .fruits: return "catch"
        case .mania: return "mania"
        }
    }
    var searchCode: Int {
        switch self {
        case .osu: return 0
        case .taiko: return 1
        case .fruits: return 2
        case .mania: return 3
        }
    }
}

struct UserLevel: Decodable { let current: Int?; let progress: Int? }

struct UserStats: Decodable {
    let globalRank: Int?
    let countryRank: Int?
    let pp: Double?
    let hitAccuracy: Double?
    let playCount: Int?
    let rankedScore: Int?
    let level: UserLevel?
}

struct User: Decodable, Identifiable, Hashable {
    let id: Int
    let username: String
    let avatarUrl: String?
    let countryCode: String?
    let isOnline: Bool?
    let statistics: UserStats?

    static func == (l: User, r: User) -> Bool { l.id == r.id }
    func hash(into h: inout Hasher) { h.combine(id) }
}

/// Lazer scores send mods as objects, legacy scores as strings.
struct ModItem: Decodable {
    let acronym: String
    init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if let s = try? c.decode(String.self) {
            acronym = s
        } else {
            struct Obj: Decodable { let acronym: String }
            acronym = try c.decode(Obj.self).acronym
        }
    }
}

struct BeatmapLite: Decodable {
    let id: Int?
    let version: String?
    let difficultyRating: Double?
}

struct BeatmapsetLite: Decodable {
    let id: Int?
    let title: String?
    let artist: String?
}

struct Score: Decodable, Identifiable {
    let id: Int
    let pp: Double?
    let accuracy: Double?
    let rank: String?
    let maxCombo: Int?
    let mods: [ModItem]?
    let createdAt: String?
    let beatmap: BeatmapLite?
    let beatmapset: BeatmapsetLite?

    var isClassic: Bool { mods?.contains { $0.acronym == "CL" } ?? false }
    var visibleMods: [String] { (mods ?? []).map(\.acronym).filter { $0 != "CL" } }
}

struct RankingEntry: Decodable, Identifiable {
    let pp: Double?
    let globalRank: Int?
    let hitAccuracy: Double?
    let playCount: Int?
    let user: User
    var id: Int { user.id }
}

struct RankingResponse: Decodable { let ranking: [RankingEntry] }

struct BeatmapsetCovers: Decodable { let card: String?; let list: String? }

struct SetBeatmap: Decodable, Identifiable {
    let id: Int
    let version: String?
    let difficultyRating: Double?
    let mode: String?
}

struct Beatmapset: Decodable, Identifiable {
    let id: Int
    let title: String
    let artist: String
    let creator: String?
    let status: String?
    let playCount: Int?
    let favouriteCount: Int?
    let covers: BeatmapsetCovers?
    let beatmaps: [SetBeatmap]?
}

struct SearchResponse: Decodable { let beatmapsets: [Beatmapset] }

struct Relation: Decodable, Identifiable {
    let targetId: Int
    let target: User?
    var id: Int { targetId }
}
