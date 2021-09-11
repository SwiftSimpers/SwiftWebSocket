import Foundation

public enum Errors: Error {
    case connectionError(String)
}

public enum ReadyState: Int {
    case connecting = 0
    case open = 1
    case closing = 2
    case closed = 3
}

// sora gay
// let's keep this lmao
// YEP

private class SessionDelegate: NSObject, URLSessionWebSocketDelegate {
    private let didOpen: (String?) -> Void
    private let didClose: (Int, Data?) -> Void

    init(didOpen: @escaping (String?) -> Void, didClose: @escaping (Int, Data?) -> Void) {
        self.didOpen = didOpen
        self.didClose = didClose
    }

    func urlSession(
        _: URLSession,
        webSocketTask _: URLSessionWebSocketTask,
        didOpenWithProtocol: String?
    ) {
        didOpen(didOpenWithProtocol)
    }

    func urlSession(
        _: URLSession,
        webSocketTask _: URLSessionWebSocketTask,
        didCloseWith: URLSessionWebSocketTask.CloseCode,
        reason: Data?
    ) {
        didClose(didCloseWith.rawValue, reason)
    }
}

public typealias ClosedHandler = (Int, String?) -> Void
public typealias ErrorHandler = (Error) -> Void

public protocol WSMessage {}
extension String: WSMessage {}
extension Data: WSMessage {}

public class WebSocketStream: AsyncSequence {
    private var messageHandlers: [(WSMessage) -> Void] = []

    public class AsyncIterator: AsyncIteratorProtocol {
        var websocketStream: WebSocketStream
        private var _nextHandler: ((WSMessage) -> Void)?
        private var messageCache: [WSMessage] = []
        var nextHandler: ((WSMessage) -> Void)? {
            get {
                self._nextHandler
            }
            set(newHandler) {
                self._nextHandler = newHandler
                if let newHandler = newHandler {
                    for msg in messageCache {
                        newHandler(msg)
                    }
                }
            }
        }

        public func next() async -> WSMessage? {
            let msg: WSMessage? = await withCheckedContinuation { ctx in
                if self.websocketStream.readyState == .closed {
                    ctx.resume(returning: nil)
                } else {
                    nextHandler = { msg in
                        ctx.resume(returning: msg)
                    }
                }
            }
            return msg
        }

        public init(websocketStream: WebSocketStream) {
            self.websocketStream = websocketStream
            self.websocketStream.message(handler)
        }

        private func handler(msg: WSMessage) {
            if let nextHandler = nextHandler {
                nextHandler(msg)
            } else {
                messageCache.append(msg)
            }
        }
    }

    public func makeAsyncIterator() -> AsyncIterator {
        return AsyncIterator(websocketStream: self)
    }

    public typealias Element = WSMessage

    public let url: URL
    private(set) var readyState = ReadyState.connecting
    private(set) var subProtocol: String?
    private var wsTask: URLSessionWebSocketTask?
    public var maximumMessageSize: Int {
        get {
            return wsTask?.maximumMessageSize ?? 0
        }
        set(value) {
            if let wsTask = self.wsTask {
                wsTask.maximumMessageSize = value
            }
        }
    }

    private var readyHandles: [() -> Void] = []
    private var closedHandlers: [ClosedHandler] = []
    private var errorHandlers: [ErrorHandler] = []
    
    private var messageCache: [WSMessage] = []

    /// Wait for the connection to get ready.
    public func ready() async {
        handleMessage()
        wsTask?.resume()
        let _: () = await withCheckedContinuation { ctx in
            if self.readyState == .open {
                ctx.resume()
            } else {
                readyHandles.append {
                    ctx.resume()
                }
            }
        }
    }

    init(url: URL, protocols: [String] = [], headers: [String: String] = [:]) {
        self.url = url
        let session = URLSession(
            configuration: URLSessionConfiguration.default,
            delegate: SessionDelegate(
                didOpen: { [weak self] proto in
                    guard let self = self else { return }
                    self.subProtocol = proto
                    self.readyState = .open

                    for handle in self.readyHandles {
                        handle()
                    }
                },
                didClose: { [weak self] closedCode, reason in
                    guard let self = self else { return }
                    self.readyState = .closed
                    for handler in self.closedHandlers {
                        handler(closedCode, String(data: reason ?? Data(), encoding: .utf8))
                    }
                }
            ),
            delegateQueue: nil
        )
        var request = URLRequest(url: url)
        request.allHTTPHeaderFields = [:]
        if protocols.count > 0 {
            request.allHTTPHeaderFields!["Sec-WebSocket-Protocol"] = protocols.joined(separator: ",")
        }
        for header in headers {
            request.allHTTPHeaderFields![header.key] = header.value
        }

        wsTask = session.webSocketTask(with: request)
    }

    /// Send binary data to the Web Socket
    public func send(_ data: Data) async throws {
        try await wsTask?.send(.data(data))
    }

    /// Send text data to the Web Socket
    public func send(_ string: String) async throws {
        try await wsTask?.send(.string(string))
    }

    public typealias CloseCode = URLSessionWebSocketTask.CloseCode

    public func close(code: CloseCode, reason: String) {
        close(code: code, reason: reason.data(using: .utf8)!)
    }

    public func close(code: CloseCode, reason: Data) {
        wsTask?.cancel(with: code, reason: reason)
    }

    public func close(code: CloseCode) {
        wsTask?.cancel(with: code, reason: nil)
    }

    private func handleMessage() {
        wsTask?.receive { [weak self] result in
            guard let self = self else { return }

            switch result {
            case let .failure(error):
                for handler in self.errorHandlers {
                    handler(error)
                }
            case let .success(msg):
                switch msg {
                case let .data(data):
                    if self.messageHandlers.count == 0 {
                        self.messageCache.append(data)
                    } else {
                        for handler in self.messageHandlers {
                            handler(data)
                        }
                    }
                case let .string(str):
                    if self.messageHandlers.count == 0 {
                        self.messageCache.append(str)
                    } else {
                        for handler in self.messageHandlers {
                            handler(str)
                        }
                    }
                @unknown default: break
                }
            }

            self.handleMessage()
        }
    }

    func closed(_ handler: @escaping ClosedHandler) {
        closedHandlers.append(handler)
    }

    func error(_ handler: @escaping ErrorHandler) {
        errorHandlers.append(handler)
    }

    func message(_ handler: @escaping (WSMessage) -> Void) {
        if messageHandlers.count == 0 {
            for msg in messageCache {
                handler(msg)
            }
        }
        messageHandlers.append(handler)
    }
}
