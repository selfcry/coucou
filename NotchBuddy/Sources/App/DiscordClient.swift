import Foundation

// Discord self-bot client: uses the user's own token to poll unread messages.

final class DiscordClient: @unchecked Sendable {
    static let shared = DiscordClient()
    private var timer: DispatchSourceTimer?
    private let queue = DispatchQueue(label: "discord-client", qos: .background)
    private let baseURL = "https://discord.com/api/v10"
    private var previousChannelIds: Set<String> = []
    private init() {}

    func start() {
        guard timer == nil else { return }
        let t = DispatchSource.makeTimerSource(queue: queue)
        t.schedule(deadline: .now() + 5, repeating: 30, leeway: .seconds(5))
        t.setEventHandler { [weak self] in self?.poll() }
        t.resume()
        timer = t
    }

    func stop() {
        timer?.cancel()
        timer = nil
    }

    // MARK: - Send message

    func sendMessage(channelId: String, text: String, completion: @escaping (Bool) -> Void) {
        guard let token = KeychainStore.shared.get("discord-token"), !token.isEmpty else {
            completion(false)
            return
        }
        guard let url = URL(string: "\(baseURL)/channels/\(channelId)/messages") else {
            completion(false)
            return
        }
        var req = URLRequest(url: url, timeoutInterval: 15)
        req.httpMethod = "POST"
        req.setValue(token, forHTTPHeaderField: "Authorization")
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try? JSONSerialization.data(withJSONObject: ["content": text])

        URLSession.shared.dataTask(with: req) { _, response, _ in
            let code = (response as? HTTPURLResponse)?.statusCode ?? 0
            completion((200...299).contains(code))
        }.resume()
    }

    // MARK: - Poll

    private func poll() {
        guard !DemoEngine.isPollerPaused else { return }
        guard let token = KeychainStore.shared.get("discord-token"), !token.isEmpty else { return }
        fetchUnreadChannels(token: token)
    }

    private func fetchUnreadChannels(token: String) {
        discordGet("users/@me/guilds", token: token) { [weak self] result in
            guard let self, case .success(let guildsJson) = result,
                  let guilds = guildsJson as? [[String: Any]] else { return }

            let lock = NSLock()
            var collected: [DiscordNotification] = []
            let group = DispatchGroup()

            for guild in guilds.prefix(10) {
                guard let guildId = guild["id"] as? String,
                      let guildName = guild["name"] as? String else { continue }

                group.enter()
                self.fetchLastMessages(guildId: guildId, guildName: guildName, token: token) { notifs in
                    lock.lock()
                    collected.append(contentsOf: notifs)
                    lock.unlock()
                    group.leave()
                }
            }

            group.notify(queue: self.queue) {
                let notifs = lock.withLock { collected }
                self.fetchDMs(token: token) { dms in
                    let all = Array((notifs + dms).prefix(10))
                    let newIds = Set(all.map(\.channelId))
                    let hasNew = !newIds.subtracting(self.previousChannelIds).isEmpty
                    self.previousChannelIds = newIds

                    DispatchQueue.main.async {
                        AppState.shared.discordNotifications = all
                        if hasNew && !all.isEmpty {
                            NotificationCenter.default.post(name: .hookReveal, object: nil)
                        }
                    }
                }
            }
        }
    }

    private func fetchLastMessages(guildId: String, guildName: String, token: String,
                                   completion: @escaping ([DiscordNotification]) -> Void) {
        discordGet("guilds/\(guildId)/channels", token: token) { [weak self] chResult in
            guard let self, case .success(let chJson) = chResult,
                  let channels = chJson as? [[String: Any]] else {
                completion([])
                return
            }

            var batch: [DiscordNotification] = []
            let innerGroup = DispatchGroup()
            let innerLock = NSLock()

            for ch in channels {
                guard let chId = ch["id"] as? String,
                      let chName = ch["name"] as? String,
                      let type = ch["type"] as? Int, type == 0,
                      ch["last_message_id"] != nil else { continue }

                innerGroup.enter()
                self.discordGet("channels/\(chId)/messages?limit=1", token: token) { msgResult in
                    defer { innerGroup.leave() }
                    var lastMsg: String?
                    var author: String?
                    if case .success(let msgJson) = msgResult,
                       let msgs = msgJson as? [[String: Any]],
                       let first = msgs.first {
                        lastMsg = first["content"] as? String
                        let authorObj = first["author"] as? [String: Any]
                        author = authorObj?["global_name"] as? String
                            ?? authorObj?["username"] as? String
                    }
                    let notif = DiscordNotification(
                        guildName: guildName, channelName: chName,
                        channelId: chId, guildId: guildId,
                        lastMessage: lastMsg, lastAuthor: author
                    )
                    innerLock.lock()
                    batch.append(notif)
                    innerLock.unlock()
                }
            }

            innerGroup.notify(queue: self.queue) {
                completion(innerLock.withLock { batch })
            }
        }
    }

    private func fetchDMs(token: String, completion: @escaping ([DiscordNotification]) -> Void) {
        discordGet("users/@me/channels", token: token) { [weak self] result in
            guard let self, case .success(let json) = result,
                  let channels = json as? [[String: Any]] else {
                completion([])
                return
            }

            var dms: [DiscordNotification] = []
            let group = DispatchGroup()
            let lock = NSLock()

            for ch in channels.prefix(5) {
                guard let chId = ch["id"] as? String,
                      let type = ch["type"] as? Int, type == 1,
                      ch["last_message_id"] != nil else { continue }

                let recipients = ch["recipients"] as? [[String: Any]] ?? []
                let name = recipients.first?["global_name"] as? String
                    ?? recipients.first?["username"] as? String ?? "DM"

                group.enter()
                self.discordGet("channels/\(chId)/messages?limit=1", token: token) { msgResult in
                    defer { group.leave() }
                    var lastMsg: String?
                    var author: String?
                    if case .success(let msgJson) = msgResult,
                       let msgs = msgJson as? [[String: Any]],
                       let first = msgs.first {
                        lastMsg = first["content"] as? String
                        let authorObj = first["author"] as? [String: Any]
                        author = authorObj?["global_name"] as? String
                            ?? authorObj?["username"] as? String
                    }
                    let notif = DiscordNotification(
                        guildName: "DM", channelName: name,
                        channelId: chId, guildId: nil,
                        lastMessage: lastMsg, lastAuthor: author
                    )
                    lock.lock()
                    dms.append(notif)
                    lock.unlock()
                }
            }

            group.notify(queue: self.queue) {
                completion(lock.withLock { dms })
            }
        }
    }

    // MARK: - HTTP

    private func discordGet(_ path: String, token: String,
                            completion: @escaping (Result<Any, Error>) -> Void) {
        guard let url = URL(string: "\(baseURL)/\(path)") else {
            completion(.failure(DCError.invalidURL))
            return
        }
        var req = URLRequest(url: url, timeoutInterval: 15)
        req.setValue(token, forHTTPHeaderField: "Authorization")
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")

        URLSession.shared.dataTask(with: req) { data, response, error in
            if let error { completion(.failure(error)); return }
            let code = (response as? HTTPURLResponse)?.statusCode ?? 0
            guard let data, (200...299).contains(code) else {
                completion(.failure(DCError.httpError(code)))
                return
            }
            guard let json = try? JSONSerialization.jsonObject(with: data) else {
                completion(.failure(DCError.invalidJSON))
                return
            }
            completion(.success(json))
        }.resume()
    }
}

// MARK: - Models

struct DiscordNotification: Identifiable, Equatable {
    let id = UUID()
    let guildName: String
    let channelName: String
    let channelId: String
    let guildId: String?
    let lastMessage: String?
    let lastAuthor: String?

    var isDM: Bool { guildId == nil }
    var displayName: String { isDM ? channelName : "\(guildName) → #\(channelName)" }

    static func == (lhs: DiscordNotification, rhs: DiscordNotification) -> Bool {
        lhs.channelId == rhs.channelId && lhs.guildName == rhs.guildName
    }
}

enum DCError: Error {
    case invalidURL, invalidJSON, httpError(Int)
}
