import SwiftUI

struct Avatar: View {
    let url: String?
    var size: CGFloat = 40
    var body: some View {
        AsyncImage(url: url.flatMap(URL.init)) { img in
            img.resizable().scaledToFill()
        } placeholder: {
            Color.gray.opacity(0.3)
        }
        .frame(width: size, height: size)
        .clipShape(RoundedRectangle(cornerRadius: size * 0.2))
    }
}

struct RulesetPicker: View {
    @Binding var selection: Ruleset
    var body: some View {
        Picker("Ruleset", selection: $selection) {
            ForEach(Ruleset.allCases) { Text($0.title).tag($0) }
        }
        .pickerStyle(.segmented)
    }
}

struct ErrorText: View {
    let message: String?
    var body: some View {
        if let m = message { Text(m).font(.footnote).foregroundStyle(.red) }
    }
}

// MARK: Profile

struct ProfileView: View {
    /// nil = signed-in user
    let userKey: String?
    @State private var ruleset: Ruleset = .osu
    @State private var user: User?
    @State private var scoreType = "best"
    @State private var scores: [Score] = []
    @State private var error: String?
    @State private var loading = false
    @State private var query = ""
    @State private var lookupKey: String?

    var body: some View {
        List {
            Section { RulesetPicker(selection: $ruleset) }
            if let u = user {
                Section {
                    HStack(spacing: 12) {
                        Avatar(url: u.avatarUrl, size: 64)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(u.username).font(.title3.bold())
                            Text(u.countryCode ?? "").foregroundStyle(.secondary)
                        }
                    }
                    if let s = u.stats(for: ruleset) {
                        stat("Global rank", s.globalRank.map { "#\($0)" })
                        stat("Country rank", s.countryRank.map { "#\($0)" })
                        stat("PP", s.pp.map { String(format: "%.0f", $0) })
                        stat("Accuracy", s.hitAccuracy.map { String(format: "%.2f%%", $0) })
                        stat("Play count", s.playCount.map(String.init))
                        stat("Level", s.level?.current.map(String.init))
                    }
                }
                Section {
                    Picker("Scores", selection: $scoreType) {
                        Text("Top").tag("best")
                        Text("Recent").tag("recent")
                    }
                    .pickerStyle(.segmented)
                }
                Section(scoreType == "best" ? "Top plays" : "Recent plays") {
                    ForEach(scores) { ScoreRow(score: $0) }
                }
            }
            if let error { Section { ErrorText(message: error) } }
        }
        .navigationTitle(userKey == nil && lookupKey == nil ? "Me" : (user?.username ?? "Player"))
        .searchable(text: $query, prompt: "Look up player")
        .onSubmit(of: .search) {
            let q = query.trimmingCharacters(in: .whitespaces)
            lookupKey = q.isEmpty ? nil : q
        }
        .refreshable { await load() }
        .task(id: "\(ruleset.rawValue)|\(scoreType)|\(lookupKey ?? "")") { await load() }
    }

    private func stat(_ name: String, _ value: String?) -> some View {
        HStack { Text(name); Spacer(); Text(value ?? "-").foregroundStyle(.secondary) }
    }

    private func load() async {
        error = nil
        do {
            let key = lookupKey ?? userKey
            let u: User
            if let key { u = try await API.shared.user(key, ruleset) }
            else { u = try await API.shared.me(ruleset) }
            user = u
            scores = try await API.shared.scores(userID: u.id, type: scoreType, ruleset: ruleset)
        } catch is CancellationError {
        } catch {
            self.error = error.localizedDescription
        }
    }
}

struct ScoreRow: View {
    let score: Score
    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(score.beatmapset?.title ?? "Unknown map").font(.headline).lineLimit(1)
                Spacer()
                Text(score.rank ?? "").font(.headline).foregroundStyle(.tint)
            }
            Text("\(score.beatmapset?.artist ?? "") [\(score.beatmap?.version ?? "")]")
                .font(.caption).foregroundStyle(.secondary).lineLimit(1)
            HStack(spacing: 8) {
                if let pp = score.pp { Text(String(format: "%.0fpp", pp)) }
                if let acc = score.accuracy { Text(String(format: "%.2f%%", acc * 100)) }
                if let c = score.maxCombo { Text("\(c)x") }
                if !score.visibleMods.isEmpty { Text(score.visibleMods.joined()).bold() }
                Text(score.isClassic ? "CL" : "Lazer")
                    .font(.caption2.bold())
                    .padding(.horizontal, 6).padding(.vertical, 2)
                    .background(.quaternary, in: Capsule())
            }
            .font(.subheadline)
        }
    }
}

// MARK: Rankings

struct RankingsView: View {
    @State private var ruleset: Ruleset = .osu
    @State private var country = ""
    @State private var entries: [RankingEntry] = []
    @State private var page = 1
    @State private var error: String?
    @State private var loading = false

    var body: some View {
        List {
            Section {
                RulesetPicker(selection: $ruleset)
                TextField("Country code (e.g. US, leave empty for global)", text: $country)
                    .textInputAutocapitalization(.characters)
                    .autocorrectionDisabled()
                    .onSubmit { Task { await reload() } }
            }
            ForEach(entries) { e in
                NavigationLink {
                    ProfileView(userKey: String(e.user.id))
                } label: {
                    HStack(spacing: 10) {
                        Text("#\(e.globalRank ?? 0)").frame(width: 56, alignment: .leading).foregroundStyle(.secondary)
                        Avatar(url: e.user.avatarUrl, size: 32)
                        VStack(alignment: .leading) {
                            Text(e.user.username).font(.headline)
                            Text(e.user.countryCode ?? "").font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                        Text(String(format: "%.0fpp", e.pp ?? 0))
                    }
                }
            }
            if !entries.isEmpty {
                Button("Load more") { Task { await loadMore() } }
            }
            if let error { ErrorText(message: error) }
        }
        .navigationTitle("Rankings")
        .refreshable { await reload() }
        .task(id: ruleset) { await reload() }
    }

    private func reload() async {
        page = 1
        entries = []
        await loadMore()
    }

    private func loadMore() async {
        error = nil
        do {
            let more = try await API.shared.rankings(ruleset, country: country, page: page)
            entries += more
            page += 1
        } catch is CancellationError {
        } catch {
            self.error = error.localizedDescription
        }
    }
}

// MARK: Beatmaps

struct BeatmapSearchView: View {
    @State private var ruleset: Ruleset = .osu
    @State private var text = ""
    @State private var sets: [Beatmapset] = []
    @State private var error: String?
    @Environment(\.openURL) private var openURL

    var body: some View {
        List {
            Section { RulesetPicker(selection: $ruleset) }
            ForEach(sets) { s in
                VStack(alignment: .leading, spacing: 6) {
                    AsyncImage(url: s.covers?.card.flatMap(URL.init)) { img in
                        img.resizable().scaledToFill()
                    } placeholder: { Color.gray.opacity(0.2) }
                    .frame(height: 90).clipped().clipShape(RoundedRectangle(cornerRadius: 8))
                    Text(s.title).font(.headline)
                    Text("\(s.artist) - mapped by \(s.creator ?? "?")").font(.caption).foregroundStyle(.secondary)
                    if let maps = s.beatmaps {
                        Text(maps.sorted { ($0.difficultyRating ?? 0) < ($1.difficultyRating ?? 0) }
                            .map { String(format: "%.2f*", $0.difficultyRating ?? 0) }.joined(separator: "  "))
                            .font(.caption2).foregroundStyle(.secondary).lineLimit(2)
                    }
                    HStack {
                        Text(s.status?.capitalized ?? "").font(.caption2)
                        Spacer()
                        Button("Open on osu!") { openURL(URL(string: "https://osu.ppy.sh/beatmapsets/\(s.id)")!) }
                        Button("Download") { openURL(URL(string: Config.mirror + String(s.id))!) }
                    }
                    .buttonStyle(.bordered).controlSize(.small)
                }
                .padding(.vertical, 4)
            }
            if let error { ErrorText(message: error) }
        }
        .navigationTitle("Beatmaps")
        .searchable(text: $text, prompt: "Search beatmaps")
        .onSubmit(of: .search) { Task { await search() } }
        .task(id: ruleset) { await search() }
    }

    private func search() async {
        error = nil
        do { sets = try await API.shared.searchBeatmaps(text, ruleset) }
        catch { self.error = error.localizedDescription }
    }
}

// MARK: Friends

struct FriendsView: View {
    @State private var friends: [Friend] = []
    @State private var error: String?

    var body: some View {
        List {
            ForEach(friends) { f in
                NavigationLink {
                    ProfileView(userKey: String(f.user.id))
                } label: {
                    HStack(spacing: 10) {
                        Avatar(url: f.user.avatarUrl, size: 36)
                        Text(f.user.username)
                        Spacer()
                        Circle().fill(f.user.isOnline == true ? Color.green : Color.gray.opacity(0.4)).frame(width: 10, height: 10)
                    }
                }
            }
            if let error { ErrorText(message: error) }
        }
        .navigationTitle("Friends")
        .refreshable { await load() }
        .task { await load() }
    }

    private func load() async {
        error = nil
        do { friends = try await API.shared.friends() }
        catch is CancellationError {}
        catch { self.error = error.localizedDescription }
    }
}

// MARK: Settings

struct SettingsView: View {
    @EnvironmentObject var auth: AuthManager
    @State private var clientID = Config.clientID
    @State private var proxy = Config.proxyURL
    @State private var redirect = Config.redirectURI

    var body: some View {
        Form {
            Section("OAuth") {
                TextField("Client ID", text: $clientID).keyboardType(.numberPad)
                TextField("Token proxy URL", text: $proxy).textInputAutocapitalization(.never).autocorrectionDisabled()
                TextField("Redirect URI", text: $redirect).textInputAutocapitalization(.never).autocorrectionDisabled()
                Button("Save") {
                    Config.clientID = clientID.trimmingCharacters(in: .whitespaces)
                    Config.proxyURL = proxy.trimmingCharacters(in: .whitespaces)
                    Config.redirectURI = redirect.trimmingCharacters(in: .whitespaces)
                }
                Button("Reset to defaults") {
                    clientID = Config.defaultClientID
                    proxy = Config.defaultProxyURL
                    redirect = Config.defaultRedirectURI
                    Config.clientID = clientID; Config.proxyURL = proxy; Config.redirectURI = redirect
                }
            }
            if auth.isSignedIn {
                Section { Button("Sign out", role: .destructive) { auth.signOut() } }
            }
            Section {
                Text("Unofficial port of osu! Companion. osu! is a trademark of ppy Pty Ltd.")
                    .font(.footnote).foregroundStyle(.secondary)
            }
        }
        .navigationTitle("Settings")
    }
}
