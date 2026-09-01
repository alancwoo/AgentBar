import Foundation
import os.log

struct SocketNotifyEvent: Decodable, Sendable {
    let agent: String
    let event: String
    let sessionID: String?
    let message: String?
    let timestamp: String?

    enum CodingKeys: String, CodingKey {
        case agent, event, message, timestamp
        case sessionID = "session_id"
    }
}

final class NotifySocketListener: @unchecked Sendable {
    private let logger = Logger(
        subsystem: Bundle.main.bundleIdentifier ?? "com.agentbar.app",
        category: "NotifySocketListener"
    )
    private let socketPath: String
    private let fileManager: FileManager
    private let queue = DispatchQueue(label: "com.agentbar.socket-listener")
    var onEvent: (@Sendable (AgentNotifyEvent) -> Void)?

    /// Upper bound on a single client's buffered payload, so a local process
    /// cannot grow the listener's memory without bound.
    private static let maxClientBufferBytes = 1 << 20  // 1 MiB

    private var serverFD: Int32 = -1
    private var acceptSource: DispatchSourceRead?
    private var _isListening = false
    private var clientSources: [Int32: DispatchSourceRead] = [:]

    var isListening: Bool {
        queue.sync { _isListening }
    }

    var activeClientCountForTesting: Int {
        queue.sync { clientSources.count }
    }

    init(
        socketPath: String? = nil,
        fileManager: FileManager = .default
    ) {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        self.socketPath = socketPath ?? "\(home)/.agentbar/events.sock"
        self.fileManager = fileManager
    }

    func start() {
        queue.sync { self._start() }
    }

    func stop() {
        queue.sync { self._stop() }
    }

    private func _start() {
        _stop()

        let dir = (socketPath as NSString).deletingLastPathComponent
        try? fileManager.createDirectory(
            atPath: dir,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )

        if fileManager.fileExists(atPath: socketPath) {
            try? fileManager.removeItem(atPath: socketPath)
        }

        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else {
            logger.error("Failed to create socket fd.")
            return
        }

        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        let pathBytes = socketPath.utf8CString
        guard pathBytes.count <= MemoryLayout.size(ofValue: addr.sun_path) else {
            close(fd)
            return
        }
        withUnsafeMutablePointer(to: &addr.sun_path) { ptr in
            ptr.withMemoryRebound(to: CChar.self, capacity: pathBytes.count) { dest in
                for (i, byte) in pathBytes.enumerated() {
                    dest[i] = byte
                }
            }
        }

        let addrLen = socklen_t(MemoryLayout<sockaddr_un>.size)
        let bindResult = withUnsafePointer(to: &addr) { ptr in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockPtr in
                bind(fd, sockPtr, addrLen)
            }
        }
        guard bindResult == 0 else {
            logger.error("Failed to bind socket at \(self.socketPath, privacy: .public). errno=\(errno, privacy: .public)")
            close(fd)
            return
        }

        guard listen(fd, 5) == 0 else {
            logger.error("Failed to listen on socket at \(self.socketPath, privacy: .public). errno=\(errno, privacy: .public)")
            close(fd)
            try? fileManager.removeItem(atPath: socketPath)
            return
        }

        // Only this user may talk to the event socket.
        _ = chmod(socketPath, 0o600)

        let flags = fcntl(fd, F_GETFL)
        _ = fcntl(fd, F_SETFL, flags | O_NONBLOCK)

        serverFD = fd
        _isListening = true

        let source = DispatchSource.makeReadSource(fileDescriptor: fd, queue: queue)
        source.setEventHandler { [weak self] in
            self?.acceptConnection()
        }
        let capturedFD = fd
        source.setCancelHandler {
            close(capturedFD)
        }
        self.acceptSource = source
        source.resume()
        logger.info("Socket listener started at \(self.socketPath, privacy: .public).")
    }

    private func _stop() {
        for (_, source) in clientSources {
            source.cancel()
        }
        clientSources.removeAll()

        _isListening = false

        if let source = acceptSource {
            serverFD = -1
            source.cancel()
            acceptSource = nil

            if fileManager.fileExists(atPath: socketPath) {
                try? fileManager.removeItem(atPath: socketPath)
            }
        } else if serverFD >= 0 {
            close(serverFD)
            serverFD = -1
            if fileManager.fileExists(atPath: socketPath) {
                try? fileManager.removeItem(atPath: socketPath)
            }
        } else if fileManager.fileExists(atPath: socketPath) {
            try? fileManager.removeItem(atPath: socketPath)
        }
        logger.info("Socket listener stopped.")
    }

    private func acceptConnection() {
        let clientFD = accept(serverFD, nil, nil)
        guard clientFD >= 0 else {
            logger.error("Failed to accept client. errno=\(errno, privacy: .public)")
            return
        }

        let flags = fcntl(clientFD, F_GETFL)
        _ = fcntl(clientFD, F_SETFL, flags | O_NONBLOCK)

        var buffer = Data()
        let readSource = DispatchSource.makeReadSource(fileDescriptor: clientFD, queue: queue)
        readSource.setEventHandler { [weak self] in
            var buf = [UInt8](repeating: 0, count: 4096)
            let bytesRead = read(clientFD, &buf, buf.count)
            if bytesRead > 0 {
                buffer.append(contentsOf: buf[0..<bytesRead])
                if buffer.count > Self.maxClientBufferBytes {
                    self?.logger.error("Dropping client: payload exceeded buffer limit.")
                    readSource.cancel()
                    self?.removeClient(clientFD)
                }
            } else if bytesRead == 0 {
                readSource.cancel()
                self?.processBuffer(buffer)
                self?.removeClient(clientFD)
            } else {
                if errno == EAGAIN || errno == EWOULDBLOCK {
                    return
                }
                readSource.cancel()
                self?.processBuffer(buffer)
                self?.removeClient(clientFD)
            }
        }
        readSource.setCancelHandler { [weak self] in
            close(clientFD)
            self?.clientSources.removeValue(forKey: clientFD)
        }
        clientSources[clientFD] = readSource
        readSource.resume()
    }

    private func removeClient(_ fd: Int32) {
        if let source = clientSources.removeValue(forKey: fd) {
            source.cancel()
        }
    }

    private func processBuffer(_ data: Data) {
        guard let text = String(data: data, encoding: .utf8) else { return }

        let lines = text.components(separatedBy: "\n")
        for line in lines {
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { continue }

            guard let jsonData = trimmed.data(using: .utf8),
                  let socketEvent = try? JSONDecoder().decode(SocketNotifyEvent.self, from: jsonData) else {
                logger.debug("Dropped malformed socket line.")
                continue
            }

            guard let notifyEvent = mapSocketEvent(socketEvent) else {
                logger.debug("Dropped unmapped socket event agent=\(socketEvent.agent, privacy: .public) event=\(socketEvent.event, privacy: .public).")
                continue
            }
            onEvent?(notifyEvent)
        }
    }

    static func mapEventType(_ event: String) -> AgentNotifyEventType? {
        switch event.lowercased() {
        case "stop", "subagent_stop":
            return .taskCompleted
        case "permission":
            return .permissionRequired
        case "decision":
            return .decisionRequired
        default:
            return nil
        }
    }

    static func mapAgent(_ agent: String) -> ServiceType? {
        switch agent.lowercased() {
        case "claude":
            return .claude
        case "codex":
            return .codex
        case "gemini":
            return .gemini
        case "copilot":
            return .copilot
        case "cursor":
            return .cursor
        case "opencode", "open-code", "open_code":
            return .opencode
        case "zai":
            return .zai
        default:
            return nil
        }
    }

    private func mapSocketEvent(_ socketEvent: SocketNotifyEvent) -> AgentNotifyEvent? {
        guard let service = Self.mapAgent(socketEvent.agent),
              let eventType = Self.mapEventType(socketEvent.event) else {
            return nil
        }

        let timestamp: Date
        if let ts = socketEvent.timestamp, let parsed = DateUtils.parseISO8601(ts) {
            timestamp = parsed
        } else {
            timestamp = Date()
        }

        return AgentNotifyEvent(
            service: service,
            type: eventType,
            timestamp: timestamp,
            message: socketEvent.message,
            sessionID: socketEvent.sessionID,
            sourceRecordID: "socket-\(UUID().uuidString)"
        )
    }
}
