import Foundation
import Network
import SystemConfiguration

// Monitors VPN connection status, tracks uptime, and allows server switching.
// Uses NWPathMonitor to detect VPN interfaces (utun/ipsec) and tracks connection duration.

final class VPNMonitor: @unchecked Sendable {
    static let shared = VPNMonitor()
    private var timer: DispatchSourceTimer?
    private var pathMonitor: NWPathMonitor?
    private let queue = DispatchQueue(label: "vpn-monitor", qos: .background)
    private init() {
        loadServers()
    }

    // MARK: - Server list (persisted in UserDefaults)

    struct VPNServer: Codable, Identifiable, Equatable, Hashable {
        var id: String { address }
        let name: String
        let address: String
        let port: Int
        let proto: VPNProto

        enum VPNProto: String, Codable, CaseIterable {
            case wireguard = "WireGuard"
            case openvpn   = "OpenVPN"
            case ikev2     = "IKEv2"
        }
    }

    private(set) var servers: [VPNServer] = []
    var activeServerAddress: String {
        get { UserDefaults.standard.string(forKey: "vpn-active-server") ?? "" }
        set { UserDefaults.standard.set(newValue, forKey: "vpn-active-server") }
    }

    var activeServer: VPNServer? {
        servers.first { $0.address == activeServerAddress }
    }

    func loadServers() {
        guard let data = UserDefaults.standard.data(forKey: "vpn-servers"),
              let list = try? JSONDecoder().decode([VPNServer].self, from: data) else { return }
        servers = list
    }

    func saveServers(_ list: [VPNServer]) {
        servers = list
        if let data = try? JSONEncoder().encode(list) {
            UserDefaults.standard.set(data, forKey: "vpn-servers")
        }
    }

    func addServer(_ server: VPNServer) {
        var list = servers
        list.append(server)
        saveServers(list)
    }

    func removeServer(at index: Int) {
        var list = servers
        guard list.indices.contains(index) else { return }
        let removed = list.remove(at: index)
        if activeServerAddress == removed.address { activeServerAddress = "" }
        saveServers(list)
    }

    func selectServer(_ server: VPNServer) {
        activeServerAddress = server.address
        DispatchQueue.main.async {
            AppState.shared.vpnCurrentServer = server.name
        }
    }

    // MARK: - Monitoring

    func start() {
        guard timer == nil else { return }

        // Path monitor for VPN interface detection
        let monitor = NWPathMonitor()
        monitor.pathUpdateHandler = { [weak self] path in
            self?.handlePathUpdate(path)
        }
        monitor.start(queue: queue)
        pathMonitor = monitor

        // Periodic poll for uptime and detailed status
        let t = DispatchSource.makeTimerSource(queue: queue)
        t.schedule(deadline: .now() + 2, repeating: 10, leeway: .seconds(2))
        t.setEventHandler { [weak self] in self?.pollStatus() }
        t.resume()
        timer = t
    }

    func stop() {
        timer?.cancel()
        timer = nil
        pathMonitor?.cancel()
        pathMonitor = nil
    }

    private func handlePathUpdate(_ path: NWPath) {
        let vpnActive = path.usesInterfaceType(.other) // VPN tunnels are .other
        let connected = vpnActive && path.status == .satisfied

        DispatchQueue.main.async {
            let old = AppState.shared.vpnConnected
            AppState.shared.vpnConnected = connected
            if connected && !old {
                AppState.shared.vpnConnectedSince = Date()
            } else if !connected {
                AppState.shared.vpnConnectedSince = nil
            }
        }
    }

    private func pollStatus() {
        guard !DemoEngine.isPollerPaused else { return }

        // Detect VPN interfaces from ifconfig
        let pipe = Pipe()
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/sbin/ifconfig")
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        do { try process.run() } catch { return }
        process.waitUntilExit()

        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        let output = String(data: data, encoding: .utf8) ?? ""

        var vpnInterfaces: [String] = []
        var currentIface = ""
        for line in output.components(separatedBy: "\n") {
            if !line.hasPrefix("\t") && !line.hasPrefix(" ") && line.contains(":") {
                currentIface = String(line.prefix(while: { $0 != ":" }))
            }
            if (currentIface.hasPrefix("utun") || currentIface.hasPrefix("ipsec") || currentIface.hasPrefix("ppp"))
                && line.contains("inet ") {
                vpnInterfaces.append(currentIface)
            }
        }

        let connected = !vpnInterfaces.isEmpty
        // Try to detect server from routing table
        var serverIP: String? = nil
        if connected {
            let rtPipe = Pipe()
            let rtProc = Process()
            rtProc.executableURL = URL(fileURLWithPath: "/usr/sbin/netstat")
            rtProc.arguments = ["-rn"]
            rtProc.standardOutput = rtPipe
            rtProc.standardError = FileHandle.nullDevice
            do { try rtProc.run() } catch { }
            rtProc.waitUntilExit()
            let rtData = rtPipe.fileHandleForReading.readDataToEndOfFile()
            let rtOutput = String(data: rtData, encoding: .utf8) ?? ""
            for line in rtOutput.components(separatedBy: "\n") {
                let cols = line.split(separator: " ", omittingEmptySubsequences: true)
                if cols.count >= 4, let iface = cols.last,
                   vpnInterfaces.contains(String(iface)),
                   cols[0] == "default" || cols[0].contains("/") {
                    serverIP = String(cols[1])
                    break
                }
            }
        }

        DispatchQueue.main.async {
            let old = AppState.shared.vpnConnected
            AppState.shared.vpnConnected = connected
            AppState.shared.vpnInterface = vpnInterfaces.first ?? ""
            if let ip = serverIP { AppState.shared.vpnServerIP = ip }
            if connected && !old {
                AppState.shared.vpnConnectedSince = Date()
            } else if !connected {
                AppState.shared.vpnConnectedSince = nil
                AppState.shared.vpnServerIP = ""
            }
            // Match to configured server
            if let ip = serverIP, let match = self.servers.first(where: { $0.address == ip }) {
                AppState.shared.vpnCurrentServer = match.name
            } else if connected {
                AppState.shared.vpnCurrentServer = serverIP ?? "Unknown"
            }
        }
    }
}
