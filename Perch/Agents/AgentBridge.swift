import Darwin
import Foundation

/// Unix socket server for `perch event` / `perch watch`. One JSON `AgentEvent` per line.
/// The socket is owner-only (0600); a stale socket file from a previous run is replaced at start.
///
/// An event with a `request` (`perch event --await`) keeps its connection open until `reply` answers it, one
/// `AgentReply` line back. When that client goes away first (its timeout, or the agent was answered in its
/// terminal and killed the hook), `onRequestEnded` fires with the request id.
nonisolated final class AgentBridge: @unchecked Sendable {
    enum BridgeError: Error {
        case pathTooLong
        case system(String, Int32)
    }

    /// A client that sends this much without a newline is cut off.
    private static let maxLineLength = 64 * 1024

    private let socketURL: URL
    private let onEvent: @Sendable (AgentEvent) -> Void
    private let onRequestEnded: @Sendable (String) -> Void
    /// Everything below is touched only on `queue`.
    private let queue = DispatchQueue(label: "perch.agent-bridge")
    private var listener: DispatchSourceRead?
    private var clients: [Int32: (source: DispatchSourceRead, buffer: Data, request: String?)] = [:]
    /// Request id → the client waiting for its reply.
    private var requests: [String: Int32] = [:]

    /// - Parameters:
    ///   - onRequestEnded: Called on the bridge's queue when a client waiting for a reply disconnects without one.
    ///   - onEvent: Called on the bridge's queue for every valid event.
    init(
        socketURL: URL = AgentEvent.socketURL,
        onRequestEnded: @escaping @Sendable (String) -> Void = { _ in },
        onEvent: @escaping @Sendable (AgentEvent) -> Void
    ) {
        self.socketURL = socketURL
        self.onRequestEnded = onRequestEnded
        self.onEvent = onEvent
    }

    deinit {
        listener?.cancel()
        for client in clients.values { client.source.cancel() }
    }

    func start() throws {
        try queue.sync { try listen() }
    }

    func stop() {
        queue.sync {
            listener?.cancel()
            listener = nil
            for client in clients.values { client.source.cancel() }
            clients.removeAll()
            requests.removeAll()
        }
    }

    /// A relaunch must not strand a hook waiting for an Allow / Deny answer.
    var hasPendingRequests: Bool {
        queue.sync { !requests.isEmpty }
    }

    /// Answers the client waiting on `request` and closes its connection. Does nothing when that client is
    /// already gone (the caller learns that through `onRequestEnded`).
    func reply(request: String, allow: Bool) {
        queue.async { [self] in
            guard let client = requests.removeValue(forKey: request) else { return }
            clients[client]?.request = nil
            if let line = AgentReply(request: request, allow: allow).encodedLine() { write(line, to: client) }
            disconnect(client)
        }
    }

    private func listen() throws {
        let path = socketURL.path
        let directory = socketURL.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        // Owner-only folder: no other user can reach the socket, even before its own mode is set.
        // `createDirectory`'s attributes are skipped when the folder already exists, so set them every time.
        chmod(directory.path, 0o700)

        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        guard path.utf8.count < MemoryLayout.size(ofValue: address.sun_path) else { throw BridgeError.pathTooLong }
        withUnsafeMutableBytes(of: &address.sun_path) { buffer in
            buffer.copyBytes(from: path.utf8)
            buffer[path.utf8.count] = 0
        }

        unlink(path) // stale socket from a previous run
        let descriptor = socket(AF_UNIX, SOCK_STREAM, 0)
        guard descriptor >= 0 else { throw BridgeError.system("socket", errno) }

        let bound = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                bind(descriptor, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard bound == 0 else {
            let code = errno
            close(descriptor)
            throw BridgeError.system("bind", code)
        }
        chmod(path, 0o600)
        guard Darwin.listen(descriptor, 16) == 0 else {
            let code = errno
            close(descriptor)
            throw BridgeError.system("listen", code)
        }
        setNonBlocking(descriptor)

        let source = DispatchSource.makeReadSource(fileDescriptor: descriptor, queue: queue)
        source.setEventHandler { [unowned self] in acceptClients(on: descriptor) }
        source.setCancelHandler {
            close(descriptor)
            unlink(path)
        }
        source.resume()
        listener = source
    }

    private func acceptClients(on descriptor: Int32) {
        while true {
            let client = accept(descriptor, nil, nil)
            guard client >= 0 else { return } // EAGAIN: drained
            setNonBlocking(client)
            var one: Int32 = 1
            setsockopt(client, SOL_SOCKET, SO_NOSIGPIPE, &one, socklen_t(MemoryLayout<Int32>.size))
            let source = DispatchSource.makeReadSource(fileDescriptor: client, queue: queue)
            source.setEventHandler { [unowned self] in read(from: client) }
            source.setCancelHandler { close(client) }
            clients[client] = (source, Data(), nil)
            source.resume()
        }
    }

    private func read(from client: Int32) {
        var chunk = [UInt8](repeating: 0, count: 8192)
        while true {
            let count = Darwin.read(client, &chunk, chunk.count)
            if count > 0 {
                clients[client]?.buffer.append(contentsOf: chunk[..<count])
                drainLines(of: client)
                continue
            }
            if count < 0, errno == EAGAIN || errno == EINTR { return }
            // EOF or error: a final line without a trailing newline still counts.
            if let rest = clients[client]?.buffer, !rest.isEmpty { deliver(rest, from: client) }
            disconnect(client)
            return
        }
    }

    private func drainLines(of client: Int32) {
        guard var buffer = clients[client]?.buffer else { return }
        while let newline = buffer.firstIndex(of: 0x0A) {
            deliver(buffer[buffer.startIndex..<newline], from: client)
            buffer = Data(buffer[buffer.index(after: newline)...])
        }
        if buffer.count > Self.maxLineLength {
            disconnect(client)
            return
        }
        clients[client]?.buffer = buffer
    }

    private func deliver(_ line: Data, from client: Int32) {
        guard let event = try? JSONDecoder().decode(AgentEvent.self, from: line),
              event.v <= AgentEvent.currentVersion
        else { return }
        // Register before delivering, so an immediate `reply` finds the client.
        if let request = event.request, clients[client] != nil, clients[client]?.request == nil, requests[request] == nil {
            clients[client]?.request = request
            requests[request] = client
        }
        onEvent(event)
    }

    private func disconnect(_ client: Int32) {
        guard let removed = clients.removeValue(forKey: client) else { return }
        removed.source.cancel()
        if let request = removed.request, requests[request] == client {
            requests.removeValue(forKey: request)
            onRequestEnded(request)
        }
    }

    /// Writes all of `data`, or gives up on a client that does not drain a few bytes.
    private func write(_ data: Data, to client: Int32) {
        data.withUnsafeBytes { buffer in
            var offset = 0
            while offset < buffer.count {
                let count = Darwin.write(client, buffer.baseAddress! + offset, buffer.count - offset)
                if count > 0 { offset += count } else if count < 0, errno == EINTR { continue } else { return }
            }
        }
    }

    private func setNonBlocking(_ descriptor: Int32) {
        _ = fcntl(descriptor, F_SETFL, fcntl(descriptor, F_GETFL) | O_NONBLOCK)
    }
}
