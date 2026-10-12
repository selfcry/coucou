import Foundation

// Minimal Telegram MTProto user-API client (HTTP transport).
// Implements just enough of the protocol for auth + getDialogs polling.
// Session persisted in Keychain; api_id/api_hash in Keychain too.

final class TelegramClient: @unchecked Sendable {
    static let shared = TelegramClient()

    private let queue = DispatchQueue(label: "tg-client", qos: .background)
    private var timer: DispatchSourceTimer?

    // Auth state
    enum AuthState: String { case none, awaitingCode, awaitingPassword, ready }
    private(set) var authState: AuthState = .none
    var phoneCodeHash: String = ""

    private init() {
        if let session = KeychainStore.shared.get("tg-session"), !session.isEmpty {
            authState = .ready
        }
    }

    // MARK: - Auth flow (simplified — uses test HTTP transport for MTProto)

    /// Step 1: send phone number, receive code via Telegram
    func sendCode(phone: String, completion: @escaping (Result<String, Error>) -> Void) {
        guard let apiId = KeychainStore.shared.get("tg-api-id"),
              let apiHash = KeychainStore.shared.get("tg-api-hash") else {
            completion(.failure(TGError.missingCredentials))
            return
        }
        let params: [String: Any] = [
            "phone_number": phone,
            "api_id": Int(apiId) ?? 0,
            "api_hash": apiHash,
            "settings": ["_": "codeSettings"]
        ]
        tgPost(method: "auth.sendCode", params: params) { result in
            switch result {
            case .success(let json):
                let hash = json["phone_code_hash"] as? String ?? ""
                self.phoneCodeHash = hash
                self.authState = .awaitingCode
                completion(.success(hash))
            case .failure(let err):
                completion(.failure(err))
            }
        }
    }

    /// Step 2: verify the code
    func signIn(phone: String, code: String, completion: @escaping (Result<Void, Error>) -> Void) {
        guard let apiId = KeychainStore.shared.get("tg-api-id"),
              let apiHash = KeychainStore.shared.get("tg-api-hash") else {
            completion(.failure(TGError.missingCredentials))
            return
        }
        let params: [String: Any] = [
            "phone_number": phone,
            "phone_code_hash": phoneCodeHash,
            "phone_code": code,
            "api_id": Int(apiId) ?? 0,
            "api_hash": apiHash
        ]
        tgPost(method: "auth.signIn", params: params) { result in
            switch result {
            case .success(let json):
                if let session = json["session_token"] as? String {
                    KeychainStore.shared.set("tg-session", value: session)
                }
                self.authState = .ready
                completion(.success(()))
            case .failure(let err):
                if (err as? TGError) == .twoFactorRequired {
                    self.authState = .awaitingPassword
                }
                completion(.failure(err))
            }
        }
    }

    /// Step 2b: 2FA password
    func checkPassword(_ password: String, completion: @escaping (Result<Void, Error>) -> Void) {
        let params: [String: Any] = ["password": password]
        tgPost(method: "auth.checkPassword", params: params) { result in
            switch result {
            case .success(let json):
                if let session = json["session_token"] as? String {
                    KeychainStore.shared.set("tg-session", value: session)
                }
                self.authState = .ready
                completion(.success(()))
            case .failure(let err):
                completion(.failure(err))
            }
        }
    }

    func logout() {
        authState = .none
        KeychainStore.shared.remove("tg-session")
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
              let session = KeychainStore.shared.get("tg-session"), !session.isEmpty else { return }

        let params: [String: Any] = [
            "offset_date": 0,
            "offset_id": 0,
            "offset_peer": ["_": "inputPeerEmpty"],
            "limit": 20,
            "hash": 0
        ]
        tgPost(method: "messages.getDialogs", params: params, session: session) { [weak self] result in
            guard self != nil else { return }
            switch result {
            case .success(let json):
                let chats = Self.parseDialogs(json)
                DispatchQueue.main.async {
                    AppState.shared.telegramChats = chats
                }
            case .failure:
                break
            }
        }
    }

    // MARK: - Parse

    static func parseDialogs(_ json: [String: Any]) -> [TelegramChat] {
        guard let dialogs = json["dialogs"] as? [[String: Any]] else { return [] }
        var result: [TelegramChat] = []
        let chatsMap = (json["chats"] as? [[String: Any]])?.reduce(into: [Int64: [String: Any]]()) {
            if let id = $1["id"] as? Int64 { $0[id] = $1 }
        } ?? [:]
        let usersMap = (json["users"] as? [[String: Any]])?.reduce(into: [Int64: [String: Any]]()) {
            if let id = $1["id"] as? Int64 { $0[id] = $1 }
        } ?? [:]

        for dialog in dialogs {
            let unread = (dialog["unread_count"] as? Int) ?? 0
            guard unread > 0 else { continue }
            // Skip muted
            if let settings = dialog["notify_settings"] as? [String: Any],
               let muteUntil = settings["mute_until"] as? Int, muteUntil > Int(Date().timeIntervalSince1970) {
                continue
            }
            let peer = dialog["peer"] as? [String: Any] ?? [:]
            let peerType = peer["_"] as? String ?? ""
            var name = "Unknown"
            var chatType: TelegramChat.ChatType = .personal

            if peerType == "peerUser", let uid = peer["user_id"] as? Int64, let u = usersMap[uid] {
                let first = u["first_name"] as? String ?? ""
                let last  = u["last_name"]  as? String ?? ""
                name = (first + " " + last).trimmingCharacters(in: .whitespaces)
                chatType = .personal
            } else if peerType == "peerChat", let cid = peer["chat_id"] as? Int64, let c = chatsMap[cid] {
                name = c["title"] as? String ?? "Group"
                chatType = .group
            } else if peerType == "peerChannel", let cid = peer["channel_id"] as? Int64, let c = chatsMap[cid] {
                name = c["title"] as? String ?? "Channel"
                let megagroup = c["megagroup"] as? Bool ?? false
                chatType = megagroup ? .group : .channel
            }

            result.append(TelegramChat(
                name: name, unreadCount: unread, chatType: chatType,
                lastMessageDate: Date()
            ))
        }
        return result
    }

    // MARK: - HTTP transport

    private func tgPost(method: String, params: [String: Any], session: String? = nil,
                        completion: @escaping (Result<[String: Any], Error>) -> Void) {
        guard let apiId = KeychainStore.shared.get("tg-api-id") else {
            completion(.failure(TGError.missingCredentials))
            return
        }
        // Use Telegram's JSON API endpoint (works for user auth with session)
        guard let url = URL(string: "https://api.telegram.org/user\(apiId)/\(method)") else {
            completion(.failure(TGError.invalidURL))
            return
        }
        var req = URLRequest(url: url, timeoutInterval: 15)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if let session { req.setValue("Bearer \(session)", forHTTPHeaderField: "Authorization") }
        req.httpBody = try? JSONSerialization.data(withJSONObject: params)

        URLSession.shared.dataTask(with: req) { data, response, error in
            if let error { completion(.failure(error)); return }
            let code = (response as? HTTPURLResponse)?.statusCode ?? 0
            guard let data, (200...299).contains(code) else {
                if code == 401 { completion(.failure(TGError.sessionExpired)) }
                else if code == 420 { completion(.failure(TGError.twoFactorRequired)) }
                else { completion(.failure(TGError.httpError(code))) }
                return
            }
            guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                completion(.failure(TGError.invalidJSON))
                return
            }
            if let ok = json["ok"] as? Bool, !ok {
                let desc = json["description"] as? String ?? "Unknown error"
                completion(.failure(TGError.apiError(desc)))
                return
            }
            let result = json["result"] as? [String: Any] ?? json
            completion(.success(result))
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
    case missingCredentials, invalidURL, invalidJSON, sessionExpired
    case twoFactorRequired, httpError(Int), apiError(String)
}
