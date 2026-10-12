import Foundation

// Discord self-bot client: uses the user's own token to poll unread messages.
// ⚠️ This violates Discord ToS — account may be banned.

final class DiscordClient: @unchecked Sendable {
    static let shared = DiscordClient()
    private var timer: DispatchSourceTimer?
    private let queue = DispatchQueue(label: "discord-client", qos: .background)
    private let baseURL = "https://discord.com/api/v10"
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

    private func poll() {
        guard !DemoEngine.isPollerPaused else { return }
        guard let token = KeychainStore.shared.get("discord-token"), !token.isEmpty else { return }
        fetchUnreadChannels(token: token)
    }

    // Fetch guilds, then check for unread channels
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
                self.discordGet("guilds/\(guildId)/channels", token: token) { chResult in
                    defer { group.leave() }
                    guard case .success(let chJson) = chResult,
                          let channels = chJson as? [[String: Any]] else { return }

                    var batch: [DiscordNotification] = []
                    for ch in channels {
                        guard let chId = ch["id"] as? String,
                              let chName = ch["name"] as? String,
                              let type = ch["type"] as? Int, type == 0 else { continue }
                        if ch["last_message_id"] != nil {
                            batch.append(DiscordNotification(
                                guildName: guildName, channelName: chName,
                                channelId: chId, guildId: guildId
                            ))
                        }
                    }
                    lock.lock()
                    collected.append(contentsOf: batch)
                    lock.unlock()
                }
            }

            group.notify(queue: self.queue) {
                let notifs = lock.withLock { collected }
                self.fetchDMs(token: token) { dms in
                    DispatchQueue.main.async {
                        AppState.shared.discordNotifications = Array((notifs + dms).prefix(10))
                    }
                }
            }
        }
    }

    private func fetchDMs(token: String, completion: @escaping ([DiscordNotification]) -> Void) {
        discordGet("users/@me/channels", token: token) { result in
            guard case .success(let json) = result,
                  let channels = json as? [[String: Any]] else {
                completion([])
                return
            }
            var dms: [DiscordNotification] = []
            for ch in channels.prefix(5) {
                guard let chId = ch["id"] as? String,
                      let type = ch["type"] as? Int, type == 1,
                      ch["last_message_id"] != nil else { continue }

                let recipients = ch["recipients"] as? [[String: Any]] ?? []
                let name = recipients.first?["global_name"] as? String
                    ?? recipients.first?["username"] as? String ?? "DM"
                dms.append(DiscordNotification(
                    guildName: "DM", channelName: name,
                    channelId: chId, guildId: nil
                ))
            }
            completion(dms)
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

    var isDM: Bool { guildId == nil }
    var displayName: String { isDM ? channelName : "\(guildName) → #\(channelName)" }

    static func == (lhs: DiscordNotification, rhs: DiscordNotification) -> Bool {
        lhs.channelId == rhs.channelId && lhs.guildName == rhs.guildName
    }
}

enum DCError: Error {
    case invalidURL, invalidJSON, httpError(Int)
}
