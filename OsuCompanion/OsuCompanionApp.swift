import SwiftUI

@main
struct OsuCompanionApp: App {
    @StateObject private var auth = AuthManager()

    var body: some Scene {
        WindowGroup {
            Group {
                if auth.isSignedIn {
                    RootTabs()
                } else {
                    LoginView()
                }
            }
            .environmentObject(auth)
            .preferredColorScheme(.dark)
            .tint(Color(red: 1.0, green: 0.4, blue: 0.67))
        }
    }
}

struct LoginView: View {
    @EnvironmentObject var auth: AuthManager
    @State private var showSettings = false

    var body: some View {
        NavigationStack {
            VStack(spacing: 20) {
                Spacer()
                Text("osu! Companion").font(.largeTitle.bold())
                Text("Sign in with your osu! account to view profiles, scores, rankings and friends.")
                    .multilineTextAlignment(.center)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal)
                Button("Sign in with osu!") { auth.signIn() }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
                if let e = auth.error {
                    Text(e).font(.footnote).foregroundStyle(.red).multilineTextAlignment(.center).padding(.horizontal)
                }
                Spacer()
                Text("Unofficial. osu! is a trademark of ppy Pty Ltd.")
                    .font(.caption2).foregroundStyle(.secondary)
            }
            .padding()
            .toolbar {
                Button { showSettings = true } label: { Image(systemName: "gearshape") }
            }
            .sheet(isPresented: $showSettings) { NavigationStack { SettingsView() } }
        }
    }
}

struct RootTabs: View {
    @StateObject private var irc = IRCClient()

    var body: some View {
        TabView {
            NavigationStack {
                ProfileView(userKey: nil)
                    .toolbar {
                        ToolbarItem(placement: .navigationBarTrailing) {
                            NavigationLink { SettingsView() } label: { Image(systemName: "gearshape") }
                        }
                    }
            }
            .tabItem { Label("Profile", systemImage: "person.crop.circle") }
            NavigationStack { RankingsView() }
                .tabItem { Label("Rankings", systemImage: "list.number") }
            NavigationStack { BeatmapSearchView() }
                .tabItem { Label("Beatmaps", systemImage: "music.note.list") }
            NavigationStack { FriendsView() }
                .tabItem { Label("Friends", systemImage: "person.2") }
            NavigationStack { ChatRootView() }
                .tabItem { Label("Chat", systemImage: "bubble.left.and.bubble.right") }
        }
        .environmentObject(irc)
    }
}
