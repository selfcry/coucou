import Foundation

// Telegram Bot API client.
// The user creates a bot via @BotFather, adds it to their groups/channels,
// and the bot monitors unread messages via getUpdates.

final class TelegramClient: @unchecked Sendable {
    static let shared = TelegramClient()

    private let queue = DispatchQueue(label: "tg-client", qos: .background)
    private var timer: DispatchSourceTimer?
    private var lastUpdateId: Int64 = 0

    enum AuthState: String { case none, ready }
    private(set) var authState: AuthState = .none

    private init() {
        if let token = KeychainStore.shared.get("tg-bot-token"), !token.isEmpty {
            authState = .ready
        }
    }

    func configure(token: String) {
        KeychainStore.shared.set("tg-bot-token", value: token)
        authState = .ready
        poll()
    }

    func logout() {
        authState = .none
        KeychainStore.shared.remove("tg-bot-token")
        lastUpdateId = 0
        DispatchQueue.main.async {
            AppState.shared.telegramChats = []
        }
    }

    // MARK: - Polling

    func start() {
        guard timer == nil else { return }
        let t = DispatchSource.makeTimerSource(queue: queue)
        t.schedule(deadline: .now() + 3, repeating: 30, leeway: .seconds(5))
        t.setEventHandler { [weak self] in self?.poll() }
        t.resume()
        timer = t
    }

    func stop() {
        timer?.cancel()
        timer = nil
    }

    private func poll() {
        guard !DemoEngine.isPollerPaused else { return }
        guard authState == .ready,
              let token = KeychainStore.shared.get("tg-bot-token"), !token.isEmpty else { return }

        // Get bot's chats via getUpdates (collects chat info from recent messages)
        let urlStr = "https://api.telegram.org/bot\(token)/getUpdates?offset=\(lastUpdateId)&timeout=1&allowed_updates=[\"message\"]"
        guard let url = URL(string: urlStr) else { return }

        var req = URLRequest(url: url, timeoutInterval: 10)
        req.httpMethod = "GET"

        URLSession.shared.dataTask(with: req) { [weak self] data, _, error in
            guard let self, error == nil, let data,
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let ok = json["ok"] as? Bool, ok,
                  let results = json["result"] as? [[String: Any]] else { return }

            var chatMap: [Int64: TelegramChat] = [:]

            for update in results {
                if let uid = update["update_id"] as? Int64 {
                    self.lastUpdateId = max(self.lastUpdateId, uid + 1)
                }
                guard let msg = update["message"] as? [String: Any],
                      let chat = msg["chat"] as? [String: Any],
                      let chatId = chat["id"] as? Int64 else { continue }

                let type = chat["type"] as? String ?? "private"
                let chatType: TelegramChat.ChatType
                let name: String
                switch type {
                case "group", "supergroup":
                    chatType = .group
                    name = chat["title"] as? String ?? "Group"
                case "channel":
                    chatType = .channel
                    name = chat["title"] as? String ?? "Channel"
                default:
                    chatType = .personal
                    let first = chat["first_name"] as? String ?? ""
                    let last = chat["last_name"] as? String ?? ""
                    name = (first + " " + last).trimmingCharacters(in: .whitespaces)
                }

                let existing = chatMap[chatId]
                chatMap[chatId] = TelegramChat(
                    name: name,
                    unreadCount: (existing?.unreadCount ?? 0) + 1,
                    chatType: chatType,
                    lastMessageDate: Date()
                )
            }

            if !chatMap.isEmpty {
                let chats = Array(chatMap.values).sorted { $0.unreadCount > $1.unreadCount }
                DispatchQueue.main.async {
                    AppState.shared.telegramChats = chats
                }
            }
        }.resume()
    }
}

// MARK: - Models

struct TelegramChat: Identifiable, Equatable {
    enum ChatType: String { case personal, group, channel }
    let id = UUID()
    let name: String
    let unreadCount: Int
    let chatType: ChatType
    let lastMessageDate: Date

    var icon: String {
        switch chatType {
        case .personal: return "person.fill"
        case .group:    return "person.3.fill"
        case .channel:  return "megaphone.fill"
        }
    }

    var timeAgo: String {
        let seconds = Int(Date().timeIntervalSince(lastMessageDate))
        if seconds < 60 { return "now" }
        if seconds < 3600 { return "\(seconds / 60)m" }
        if seconds < 86400 { return "\(seconds / 3600)h" }
        return "\(seconds / 86400)d"
    }

    static func == (lhs: TelegramChat, rhs: TelegramChat) -> Bool {
        lhs.name == rhs.name && lhs.unreadCount == rhs.unreadCount && lhs.chatType == rhs.chatType
    }
}

enum TGError: Error, Equatable {
    case missingCredentials, invalidResponse, httpError(Int), apiError(String)
}
