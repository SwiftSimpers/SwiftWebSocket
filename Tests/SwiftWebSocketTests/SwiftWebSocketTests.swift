@testable import SwiftWebSocket
import XCTest

enum Err: Error {
    case withMessage(String)
}

final class SwiftWebSocketTests: XCTestCase {
    func testReady() async throws {
        let socket = WebSocketStream(url: URL(string: "wss://gateway.discord.gg/?v=9&encoding=json")!)

        await socket.ready()
        XCTAssertEqual(socket.readyState, .open)
        
        let iter = socket.makeAsyncIterator()
        
        let msg = await iter.next()
        if let msg = msg as? String {
            print(msg)
        } else {
            XCTFail("AssertionFailed: msg is not typeof text")
        }

        socket.close(code: .normalClosure)
    }
}
