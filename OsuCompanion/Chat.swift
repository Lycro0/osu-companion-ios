import SwiftUI
import Network

struct ChatMessage: Identifiable {
    let id = UUID()
    let sender: String
    let text: String
    let date = Date()
    var isAction = false
    var isMine = false
    var isSystem = false
}

/// Minimal Bancho IRC client (irc.ppy.sh:6667, plain TCP like the Android app).
@MainActor
final class IRCClient: ObservableObject {
    enum State { case disconnected, connecting, connected }

    @Published var state: State = .disconnected
    @Published var error: String?
    @Published var tabs: [String] = []
    @Published var messages: [String: [ChatMessage]] = [:]
    @Published var unread: [String: Int] = [:]
    @Published var hasCredentials: Bool = Keychain.get("ircUser") != nil && Keychain.get("ircPass") != nil
    var activeTab: String?

    private var conn: NWConnection?
    private var buffer = Data()
    private var nick = ""

    private var savedChannels: [String] {
        get { UserDefaults.standard.stringArray(forKey: "ircChannels") ?? ["#osu"] }
        set { UserDefaults.standard.set(newValue, forKey: "ircChannels") }
    }

    // MARK: Credentials

    func saveCredentials(user: String, pass: String) {
        Keychain.set(user.trimmingCharacters(in: .whitespaces), for: "ircUser")
        Keychain.set(pass.trimmingCharacters(in: .whitespaces), for: "ircPass")
        hasCredentials = true
        connect()
    }

    func clearCredentials() {
        disconnect()
        Keychain.delete("ircUser")
        Keychain.delete("ircPass")
        tabs = []; messages = [:]; unread = [:]
        hasCredentials = false
    }

    // MARK: Connection

    func connect() {
        guard state == .disconnected,
              let user = Keychain.get("ircUser"), let pass = Keychain.get("ircPass") else { return }
        nick = user.replacingOccurrences(of: " ", with: "_")
        error = nil
        state = .connecting
        buffer = Data()
        let c = NWConnection(host: "irc.ppy.sh", port: 6667, using: .tcp)
        conn = c
        c.stateUpdateHandler = { [weak self] st in
            Task { @MainActor in
                guard let self, self.conn === c else { return }
                switch st {
                case .ready:
                    self.sendRaw("PASS \(pass)")
                    self.sendRaw("NICK \(self.nick)")
                    self.sendRaw("USER \(self.nick) 0 * :\(self.nick)")
                    self.receive(c)
                case .failed(let e):
                    self.drop(e.localizedDescription)
                case .waiting(let e):
                    self.error = e.localizedDescription
                default:
                    break
                }
            }
        }
        c.start(queue: .main)
    }

    func disconnect() {
        conn?.cancel()
        conn = nil
        state = .disconnected
    }

    private func drop(_ message: String?) {
        conn?.cancel()
        conn = nil
        state = .disconnected
        if let message { error = message }
    }

    private func receive(_ c: NWConnection) {
        c.receive(minimumIncompleteLength: 1, maximumLength: 16384) { [weak self] data, _, done, err in
            Task { @MainActor in
                guard let self, self.conn === c else { return }
                if let data, !data.isEmpty { self.consume(data) }
                if err != nil || done {
                    self.drop(err?.localizedDescription ?? "Disconnected from Bancho.")
                    return
                }
                self.receive(c)
            }
        }
    }

    private func consume(_ data: Data) {
        buffer.append(data)
        while let idx = buffer.firstIndex(of: 10) {
            let lineData = buffer[buffer.startIndex..<idx]
            buffer.removeSubrange(buffer.startIndex...idx)
            let line = String(decoding: lineData, as: UTF8.self).trimmingCharacters(in: .newlines)
            if !line.isEmpty { handle(line) }
        }
    }

    private func sendRaw(_ line: String) {
        let clean = line.replacingOccurrences(of: "\r", with: "").replacingOccurrences(of: "\n", with: " ")
        conn?.send(content: Data((clean + "\r\n").utf8), completion: .contentProcessed { _ in })
    }

    // MARK: Parsing

    private func handle(_ raw: String) {
        var line = Substring(raw)
        var prefix = ""
        if line.hasPrefix(":") {
            guard let sp = line.firstIndex(of: " ") else { return }
            prefix = String(line[line.index(after: line.startIndex)..<sp])
            line = line[line.index(after: sp)...]
        }
        var trailing: String?
        if let r = line.range(of: " :") {
            trailing = String(line[r.upperBound...])
            line = line[..<r.lowerBound]
        }
        let parts = line.split(separator: " ").map(String.init)
        guard let cmd = parts.first?.uppercased() else { return }
        let params = Array(parts.dropFirst())
        let sender = prefix.split(separator: "!").first.map(String.init) ?? prefix

        switch cmd {
        case "PING":
            sendRaw("PONG :\(trailing ?? "")")
        case "001":
            state = .connected
            error = nil
            for ch in savedChannels { sendRaw("JOIN \(ch)"); _ = ensureTab(ch) }
        case "464":
            drop("Authentication failed. Check your IRC username and IRC password.")
        case "PRIVMSG":
            guard let target = params.first, var text = trailing else { return }
            var action = false
            if text.hasPrefix("\u{01}ACTION ") {
                action = true
                text = String(text.dropFirst(8)).replacingOccurrences(of: "\u{01}", with: "")
            }
            let tab = target.hasPrefix("#") ? target : sender
            add(tab, ChatMessage(sender: sender, text: text, isAction: action))
        case "JOIN":
            let ch = trailing ?? params.first ?? ""
            if sender.lowercased() == nick.lowercased(), ch.hasPrefix("#") { _ = ensureTab(ch) }
        case "NOTICE":
            if let t = trailing, !t.isEmpty, let tab = activeTab {
                add(tab, ChatMessage(sender: sender, text: t, isSystem: true))
            }
        case "401", "403", "404", "442", "473", "474", "475":
            let msg = trailing ?? "Request failed."
            let target = params.dropFirst().first ?? ""
            error = "\(target): \(msg)"
            if let tab = activeTab { add(tab, ChatMessage(sender: "", text: "\(target): \(msg)", isSystem: true)) }
        default:
            break
        }
    }

    // MARK: Tabs & messages

    @discardableResult
    func ensureTab(_ name: String) -> String {
        if let existing = tabs.first(where: { $0.lowercased() == name.lowercased() }) { return existing }
        tabs.append(name)
        return name
    }

    private func add(_ tabName: String, _ msg: ChatMessage) {
        let tab = ensureTab(tabName)
        messages[tab, default: []].append(msg)
        if messages[tab]!.count > 500 { messages[tab]!.removeFirst(messages[tab]!.count - 500) }
        if !msg.isMine && !msg.isSystem && activeTab?.lowercased() != tab.lowercased() {
            unread[tab, default: 0] += 1
        }
    }

    func join(_ channel: String) {
        var ch = channel.trimmingCharacters(in: .whitespaces)
        guard !ch.isEmpty else { return }
        if !ch.hasPrefix("#") { ch = "#" + ch }
        sendRaw("JOIN \(ch)")
        _ = ensureTab(ch)
        if !savedChannels.contains(where: { $0.lowercased() == ch.lowercased() }) { savedChannels.append(ch) }
    }

    func openDM(_ user: String) {
        let u = user.trimmingCharacters(in: .whitespaces).replacingOccurrences(of: " ", with: "_")
        guard !u.isEmpty else { return }
        _ = ensureTab(u)
    }

    func close(_ tab: String) {
        if tab.hasPrefix("#") {
            sendRaw("PART \(tab)")
            savedChannels = savedChannels.filter { $0.lowercased() != tab.lowercased() }
        }
        tabs.removeAll { $0 == tab }
        messages[tab] = nil
        unread[tab] = nil
    }

    func send(_ input: String, to tab: String) {
        let text = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        guard state == .connected else {
            error = "Not connected to Bancho."
            return
        }
        if text.lowercased().hasPrefix("/join ") {
            join(String(text.dropFirst(6)))
            return
        }
        if text.lowercased().hasPrefix("/me ") {
            let body = String(text.dropFirst(4))
            sendRaw("PRIVMSG \(tab) :\u{01}ACTION \(body)\u{01}")
            add(tab, ChatMessage(sender: nick, text: body, isAction: true, isMine: true))
            return
        }
        sendRaw("PRIVMSG \(tab) :\(text)")
        add(tab, ChatMessage(sender: nick, text: text, isMine: true))
    }
}

// MARK: Views

struct ChatRootView: View {
    @EnvironmentObject var irc: IRCClient
    @State private var showNew = false

    var body: some View {
        Group {
            if irc.hasCredentials { conversationList } else { IRCSetupView() }
        }
        .navigationTitle("Chat")
    }

    private var statusText: String {
        switch irc.state {
        case .connected: return "Connected to Bancho"
        case .connecting: return "Connecting..."
        case .disconnected: return "Disconnected"
        }
    }

    private var statusColor: Color {
        switch irc.state {
        case .connected: return .green
        case .connecting: return .orange
        case .disconnected: return .gray
        }
    }

    private var conversationList: some View {
        List {
            Section {
                HStack {
                    Circle().fill(statusColor).frame(width: 10, height: 10)
                    Text(statusText)
                    Spacer()
                    Button(irc.state == .disconnected ? "Connect" : "Disconnect") {
                        if irc.state == .disconnected { irc.connect() } else { irc.disconnect() }
                    }
                    .buttonStyle(.bordered).controlSize(.small)
                }
                if let e = irc.error { ErrorText(message: e) }
            }
            Section("Conversations") {
                if irc.tabs.isEmpty {
                    Text("No conversations yet. Tap + to join a channel or message a player.")
                        .font(.footnote).foregroundStyle(.secondary)
                }
                ForEach(irc.tabs, id: \.self) { tab in
                    NavigationLink {
                        ConversationView(tab: tab)
                    } label: {
                        HStack {
                            Image(systemName: tab.hasPrefix("#") ? "number" : "person.fill")
                                .foregroundStyle(.secondary)
                            Text(tab)
                            Spacer()
                            if let n = irc.unread[tab], n > 0 {
                                Text("\(n)").font(.caption2.bold())
                                    .padding(.horizontal, 7).padding(.vertical, 3)
                                    .background(Color.accentColor, in: Capsule())
                            }
                        }
                    }
                }
            }
        }
        .toolbar {
            ToolbarItemGroup(placement: .navigationBarTrailing) {
                Button { showNew = true } label: { Image(systemName: "plus") }
                Menu {
                    Button("Change IRC login", role: .destructive) { irc.clearCredentials() }
                } label: { Image(systemName: "ellipsis.circle") }
            }
        }
        .sheet(isPresented: $showNew) { NewChatSheet() }
        .task { irc.connect() }
    }
}

struct ConversationView: View {
    let tab: String
    @EnvironmentObject var irc: IRCClient
    @Environment(\.dismiss) private var dismiss
    @State private var draft = ""

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 6) {
                    ForEach(irc.messages[tab] ?? []) { m in
                        row(m).id(m.id).textSelection(.enabled)
                    }
                }
                .padding(.horizontal)
                .padding(.top, 8)
            }
            .onChange(of: irc.messages[tab]?.count ?? 0) { _ in scrollToEnd(proxy) }
            .onAppear { scrollToEnd(proxy) }
        }
        .safeAreaInset(edge: .bottom) { inputBar }
        .navigationTitle(tab)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            Button(tab.hasPrefix("#") ? "Leave" : "Close") {
                irc.close(tab)
                dismiss()
            }
        }
        .onAppear { irc.activeTab = tab; irc.unread[tab] = 0 }
        .onDisappear { if irc.activeTab == tab { irc.activeTab = nil } }
    }

    private func scrollToEnd(_ proxy: ScrollViewProxy) {
        if let last = irc.messages[tab]?.last { proxy.scrollTo(last.id, anchor: .bottom) }
    }

    private func sendDraft() {
        irc.send(draft, to: tab)
        draft = ""
    }

    @ViewBuilder
    private func row(_ m: ChatMessage) -> some View {
        if m.isSystem {
            Text(m.text).font(.footnote).foregroundColor(.secondary)
        } else if m.isAction {
            Text("* \(m.sender) \(m.text)").italic().foregroundColor(.secondary)
        } else {
            Text(m.sender).bold().foregroundColor(m.isMine ? .accentColor : .primary)
                + Text(": ")
                + Text(m.text)
        }
    }

    private var inputBar: some View {
        HStack {
            TextField("Message \(tab)", text: $draft)
                .textFieldStyle(.roundedBorder)
                .submitLabel(.send)
                .onSubmit(sendDraft)
            Button(action: sendDraft) { Image(systemName: "paperplane.fill") }
                .disabled(draft.trimmingCharacters(in: .whitespaces).isEmpty)
        }
        .padding(8)
        .background(.bar)
    }
}

struct NewChatSheet: View {
    @EnvironmentObject var irc: IRCClient
    @Environment(\.dismiss) private var dismiss
    @State private var isChannel = true
    @State private var name = ""

    var body: some View {
        NavigationStack {
            Form {
                Picker("Type", selection: $isChannel) {
                    Text("Channel").tag(true)
                    Text("Player").tag(false)
                }
                .pickerStyle(.segmented)
                TextField(isChannel ? "#channel" : "Username", text: $name)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                Button(isChannel ? "Join" : "Message") {
                    if isChannel { irc.join(name) } else { irc.openDM(name) }
                    dismiss()
                }
                .disabled(name.trimmingCharacters(in: .whitespaces).isEmpty)
            }
            .navigationTitle("New chat")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { Button("Cancel") { dismiss() } }
        }
        .presentationDetents([.medium])
    }
}

struct IRCSetupView: View {
    @EnvironmentObject var irc: IRCClient
    @Environment(\.openURL) private var openURL
    @State private var user = ""
    @State private var pass = ""

    var body: some View {
        Form {
            Section {
                TextField("osu! username", text: $user)
                    .textInputAutocapitalization(.never).autocorrectionDisabled()
                SecureField("IRC password", text: $pass)
            } header: {
                Text("Bancho IRC login")
            } footer: {
                Text("This is the separate IRC password from your osu! account settings (Legacy API), not your osu! password. Bancho IRC is unencrypted, so avoid untrusted Wi-Fi.")
            }
            Section {
                Button("Open osu! account settings") {
                    openURL(URL(string: "https://osu.ppy.sh/home/account/edit#legacy-api")!)
                }
                Button("Save and connect") { irc.saveCredentials(user: user, pass: pass) }
                    .disabled(user.trimmingCharacters(in: .whitespaces).isEmpty || pass.isEmpty)
            }
        }
        .task {
            if user.isEmpty, let me = try? await API.shared.me(.osu) { user = me.username }
        }
    }
}
