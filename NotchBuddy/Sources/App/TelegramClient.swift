import Foundation

// Telegram selfbot via TDLib (libtdjson.dylib loaded at runtime).
// Full user auth: api_id + api_hash + phone → code → optional 2FA.

final class TelegramClient: @unchecked Sendable {
    static let shared = TelegramClient()

    private let queue = DispatchQueue(label: "tg-client", qos: .background)
    private var pollTimer: DispatchSourceTimer?
    private var recvTimer: DispatchSourceTimer?
    private var previousChatIds: Set<Int64> = []

    // TDLib function pointers
    private var lib: UnsafeMutableRawPointer?
    private var clientId: Int32 = 0
    private typealias CreateFn = @convention(c) () -> Int32
    private typealias SendFn = @convention(c) (Int32, UnsafePointer<CChar>) -> Void
    private typealias RecvFn = @convention(c) (Double) -> UnsafePointer<CChar>?
    private var tdSend: SendFn?
    private var tdRecv: RecvFn?

    enum AuthState: String { case none, awaitingPhone, awaitingCode, awaitingPassword, ready }
    private(set) var authState: AuthState = .none
    var authError: String = ""

    private var pendingExtra: [String: (([String: Any]) -> Void)] = [:]

    private init() {
        loadTDLib()
    }

    // MARK: - TDLib loading

    private func loadTDLib() {
        let paths = [
            Bundle.main.privateFrameworksPath.map { $0 + "/libtdjson.dylib" },
            Bundle.main.executablePath.map { URL(fileURLWithPath: $0).deletingLastPathComponent().path + "/../Frameworks/libtdjson.dylib" }
        ].compactMap { $0 }

        for path in paths {
            if let handle = dlopen(path, RTLD_NOW) {
                lib = handle
                break
            }
        }

        guard let lib else { return }

        guard let createSym = dlsym(lib, "td_create_client_id"),
              let sendSym = dlsym(lib, "td_send"),
              let recvSym = dlsym(lib, "td_receive") else { return }

        let tdCreate = unsafeBitCast(createSym, to: CreateFn.self)
        tdSend = unsafeBitCast(sendSym, to: SendFn.self)
        tdRecv = unsafeBitCast(recvSym, to: RecvFn.self)

        clientId = tdCreate()
        startRecvLoop()
    }

    var isLoaded: Bool { lib != nil && tdSend != nil }

    // MARK: - Send/Receive

    private func send(_ json: [String: Any]) {
        guard let tdSend, let data = try? JSONSerialization.data(withJSONObject: json),
              let str = String(data: data, encoding: .utf8) else { return }
        str.withCString { tdSend(clientId, $0) }
    }

    private func send(_ json: [String: Any], extra: String, completion: @escaping ([String: Any]) -> Void) {
        var j = json
        j["@extra"] = extra
        pendingExtra[extra] = completion
        send(j)
    }

    private func startRecvLoop() {
        let t = DispatchSource.makeTimerSource(queue: queue)
        t.schedule(deadline: .now(), repeating: 0.5, leeway: .milliseconds(100))
        t.setEventHandler { [weak self] in self?.drainReceive() }
        t.resume()
        recvTimer = t
    }

    private func drainReceive() {
        guard let tdRecv else { return }
        while let ptr = tdRecv(0) {
            let str = String(cString: ptr)
            guard let data = str.data(using: .utf8),
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { continue }
            handleEvent(json)
        }
    }

    // MARK: - Event handling

    private func handleEvent(_ json: [String: Any]) {
        if let extra = json["@extra"] as? String, let cb = pendingExtra.removeValue(forKey: extra) {
            cb(json)
            return
        }

        let type = json["@type"] as? String ?? ""

        switch type {
        case "updateAuthorizationState":
            guard let state = json["authorization_state"] as? [String: Any] else { return }
            handleAuthState(state)
        case "updateNewMessage":
            handleNewMessage(json)
        default:
            break
        }
    }

    private func handleAuthState(_ state: [String: Any]) {
        let type = state["@type"] as? String ?? ""
        switch type {
        case "authorizationStateWaitTdlibParameters":
            sendTdlibParameters()
        case "authorizationStateWaitPhoneNumber":
            DispatchQueue.main.async {
                self.authState = .awaitingPhone
            }
        case "authorizationStateWaitCode":
            DispatchQueue.main.async {
                self.authState = .awaitingCode
            }
        case "authorizationStateWaitPassword":
            DispatchQueue.main.async {
                self.authState = .awaitingPassword
            }
        case "authorizationStateReady":
            DispatchQueue.main.async {
                self.authState = .ready
                self.authError = ""
            }
            loadChats()
        default:
            break
        }
    }

    // MARK: - Auth flow

    private func sendTdlibParameters() {
        guard let apiId = KeychainStore.shared.get("tg-api-id"),
              let apiHash = KeychainStore.shared.get("tg-api-hash") else { return }

        let dbPath = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
            .appendingPathComponent("CoucouTDLib").path

        send([
            "@type": "setTdlibParameters",
            "api_id": Int(apiId) ?? 0,
            "api_hash": apiHash,
            "database_directory": dbPath,
            "use_message_database": true,
            "use_chat_info_database": true,
            "system_language_code": "en",
            "device_model": "Mac",
            "application_version": "1.0"
        ])
    }

    func setCredentials(apiId: String, apiHash: String) {
        KeychainStore.shared.set("tg-api-id", value: apiId)
        KeychainStore.shared.set("tg-api-hash", value: apiHash)
        if isLoaded {
            sendTdlibParameters()
        }
    }

    func sendPhone(_ phone: String) {
        KeychainStore.shared.set("tg-phone", value: phone)
        send([
            "@type": "setAuthenticationPhoneNumber",
            "phone_number": phone
        ], extra: "phone") { [weak self] json in
            if let err = json["message"] as? String, json["@type"] as? String == "error" {
                DispatchQueue.main.async { self?.authError = err }
            }
        }
    }

    func sendCode(_ code: String) {
        send([
            "@type": "checkAuthenticationCode",
            "code": code
        ], extra: "code") { [weak self] json in
            if let err = json["message"] as? String, json["@type"] as? String == "error" {
                DispatchQueue.main.async { self?.authError = err }
            }
        }
    }

    func sendPassword(_ password: String) {
        send([
            "@type": "checkAuthenticationPassword",
            "password": password
        ], extra: "2fa") { [weak self] json in
            if let err = json["message"] as? String, json["@type"] as? String == "error" {
                DispatchQueue.main.async { self?.authError = err }
            }
        }
    }

    func logout() {
        send(["@type": "logOut"])
        authState = .none
        previousChatIds = []
        DispatchQueue.main.async {
            AppState.shared.telegramChats = []
        }
    }

    // MARK: - Chat loading

    private func loadChats() {
        send([
            "@type": "getChats",
            "chat_list": ["@type": "chatListMain"],
            "limit": 20
        ], extra: "getChats") { [weak self] json in
            guard let self, let chatIds = json["chat_ids"] as? [Int64] else { return }
            for chatId in chatIds {
                self.send([
                    "@type": "getChat",
                    "chat_id": chatId
                ], extra: "chat_\(chatId)") { chatJson in
                    self.processChatInfo(chatJson)
                }
            }
        }
    }

    private func processChatInfo(_ json: [String: Any]) {
        guard let chatId = json["chat_id"] as? Int64 ?? json["id"] as? Int64 else { return }
        let title = json["title"] as? String ?? "Chat"
        let unread = json["unread_count"] as? Int ?? 0
        guard unread > 0 else { return }

        let typeObj = json["type"] as? [String: Any]
        let typeStr = typeObj?["@type"] as? String ?? ""
        let chatType: TelegramChat.ChatType
        switch typeStr {
        case "chatTypeBasicGroup", "chatTypeSupergroup":
            let isChannel = typeObj?["is_channel"] as? Bool ?? false
            chatType = isChannel ? .channel : .group
        case "chatTypePrivate", "chatTypeSecret":
            chatType = .personal
        default:
            chatType = .personal
        }

        let lastMsg = json["last_message"] as? [String: Any]
        let content = lastMsg?["content"] as? [String: Any]
        let msgText = content?["text"] as? [String: Any]
        let text = msgText?["text"] as? String

        let senderId = lastMsg?["sender_id"] as? [String: Any]
        let senderUserId = senderId?["user_id"] as? Int64

        let chat = TelegramChat(
            chatId: chatId,
            name: title,
            unreadCount: unread,
            chatType: chatType,
            lastMessage: text,
            lastAuthor: senderUserId != nil ? nil : nil,
            lastMessageDate: Date()
        )

        DispatchQueue.main.async {
            var chats = AppState.shared.telegramChats
            chats.removeAll { $0.chatId == chatId }
            chats.append(chat)
            chats.sort { $0.unreadCount > $1.unreadCount }
            AppState.shared.telegramChats = chats

            let newIds = Set(chats.map(\.chatId))
            if !newIds.subtracting(self.previousChatIds).isEmpty {
                NotificationCenter.default.post(name: .hookReveal, object: nil)
            }
            self.previousChatIds = newIds
        }
    }

    // MARK: - New message handling

    private func handleNewMessage(_ json: [String: Any]) {
        guard let msg = json["message"] as? [String: Any],
              let chatId = msg["chat_id"] as? Int64 else { return }

        let content = msg["content"] as? [String: Any]
        let msgText = content?["text"] as? [String: Any]
        let text = msgText?["text"] as? String

        // Refresh this chat's info
        send([
            "@type": "getChat",
            "chat_id": chatId
        ], extra: "chat_\(chatId)") { [weak self] chatJson in
            self?.processChatInfo(chatJson)
        }

        if let text, !text.isEmpty {
            DispatchQueue.main.async {
                NotificationCenter.default.post(name: .hookReveal, object: nil)
            }
        }
    }

    // MARK: - Send message

    func sendMessage(chatId: Int64, text: String, completion: @escaping (Bool) -> Void) {
        send([
            "@type": "sendMessage",
            "chat_id": chatId,
            "input_message_content": [
                "@type": "inputMessageText",
                "text": [
                    "@type": "formattedText",
                    "text": text
                ]
            ]
        ], extra: "send_\(chatId)_\(Int.random(in: 0...99999))") { json in
            let ok = json["@type"] as? String != "error"
            DispatchQueue.main.async { completion(ok) }
        }
    }

    // MARK: - Polling (periodic refresh)

    func start() {
        guard pollTimer == nil else { return }
        let t = DispatchSource.makeTimerSource(queue: queue)
        t.schedule(deadline: .now() + 10, repeating: 60, leeway: .seconds(5))
        t.setEventHandler { [weak self] in
            guard let self, self.authState == .ready else { return }
            self.loadChats()
        }
        t.resume()
        pollTimer = t
    }

    func stop() {
        pollTimer?.cancel()
        pollTimer = nil
    }
}

// MARK: - Models

struct TelegramChat: Identifiable, Equatable {
    enum ChatType: String { case personal, group, channel }
    let id = UUID()
    let chatId: Int64
    let name: String
    let unreadCount: Int
    let chatType: ChatType
    let lastMessage: String?
    let lastAuthor: String?
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
        lhs.chatId == rhs.chatId && lhs.unreadCount == rhs.unreadCount
    }
}

enum TGError: Error, Equatable {
    case missingCredentials, invalidResponse, httpError(Int), apiError(String)
    case tdlibNotLoaded
}
