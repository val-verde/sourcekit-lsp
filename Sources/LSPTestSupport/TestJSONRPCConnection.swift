//===----------------------------------------------------------------------===//
//
// This source file is part of the Swift.org open source project
//
// Copyright (c) 2014 - 2020 Apple Inc. and the Swift project authors
// Licensed under Apache License v2.0 with Runtime Library Exception
//
// See https://swift.org/LICENSE.txt for license information
// See https://swift.org/CONTRIBUTORS.txt for the list of Swift project authors
//
//===----------------------------------------------------------------------===//

import LanguageServerProtocol
import LanguageServerProtocolJSONRPC
import class Foundation.Pipe
import XCTest

// Workaround ambiguity with Foundation.
public typealias Notification = LanguageServerProtocol.Notification

#if !os(Windows)
public final class TestJSONRPCConnection {
  public let clientToServer: Pipe = Pipe()
  public let serverToClient: Pipe = Pipe()
  public let client: TestClient
  public let clientConnection: JSONRPCConnection
  public let server: TestServer
  public let serverConnection: JSONRPCConnection

  public init() {
    clientConnection = JSONRPCConnection(
      protocol: testMessageRegistry,
      inFD: serverToClient.fileHandleForReading,
      outFD: clientToServer.fileHandleForWriting
    )

    serverConnection = JSONRPCConnection(
      protocol: testMessageRegistry,
      inFD: clientToServer.fileHandleForReading,
      outFD: serverToClient.fileHandleForWriting
    )

    client = TestClient(server: clientConnection)
    server = TestServer(client: serverConnection)

    clientConnection.start(receiveHandler: client) {
      // FIXME: keep the pipes alive until we close the connection. This
      // should be fixed systemically.
      withExtendedLifetime(self) {}
    }
    serverConnection.start(receiveHandler: server) {
      // FIXME: keep the pipes alive until we close the connection. This
      // should be fixed systemically.
      withExtendedLifetime(self) {}
    }
  }

  public func close() {
    clientConnection.close()
    serverConnection.close()
  }
}
#endif

public struct TestLocalConnection {
  public let client: TestClient
  public let clientConnection: LocalConnection = .init()
  public let server: TestServer
  public let serverConnection: LocalConnection = .init()

  public init() {
    client = TestClient(server: serverConnection)
    server = TestServer(client: clientConnection)

    clientConnection.start(handler: client)
    serverConnection.start(handler: server)
  }

  public func close() {
    clientConnection.close()
    serverConnection.close()
  }
}

public final class TestClient: MessageHandler {
  /// The connection to the language client.
  public let server: Connection

  public init(server: Connection) {
    self.server = server
  }

  public var replyQueue: DispatchQueue = DispatchQueue(label: "testclient-reply-queue")
  var oneShotNotificationHandlers: [((Any) -> Void)] = []
  var oneShotRequestHandlers: [((Any) -> Void)] = []

  public var allowUnexpectedNotification: Bool = true

  public func appendOneShotNotificationHandler<N>(_ handler: @escaping (Notification<N>) -> Void) {
    oneShotNotificationHandlers.append({ anyNote in
      guard let note = anyNote as? Notification<N> else {
        fatalError("received notification of the wrong type \(anyNote); expected \(N.self)")
      }
      handler(note)
    })
  }

  public func appendOneShotRequestHandler<R>(_ handler: @escaping (Request<R>) -> Void) {
    oneShotRequestHandlers.append({ anyRequest in
      guard let request = anyRequest as? Request<R> else {
        fatalError("received request of the wrong type \(anyRequest); expected \(R.self)")
      }
      handler(request)
    })
  }

  public func handleNextNotification<N>(_ handler: @escaping (Notification<N>) -> Void) {
    precondition(oneShotNotificationHandlers.isEmpty)
    appendOneShotNotificationHandler(handler)
  }

  public func handleNextRequest<R>(_ handler: @escaping (Request<R>) -> Void) {
    precondition(oneShotRequestHandlers.isEmpty)
    appendOneShotRequestHandler(handler)
  }

  public func handle<N>(_ params: N, from clientID: ObjectIdentifier) where N: NotificationType {
    let notification = Notification(params, clientID: clientID)

    guard !oneShotNotificationHandlers.isEmpty else {
      if allowUnexpectedNotification { return }
      fatalError("unexpected notification \(notification)")
    }
    let handler = oneShotNotificationHandlers.removeFirst()
    handler(notification)
  }

  public func handle<R: RequestType>(_ params: R, id: RequestID, from clientID: ObjectIdentifier, reply: @escaping (LSPResult<R.Response>) -> Void) {
    let cancellationToken = CancellationToken()

    let request = Request(params, id: id, clientID: clientID, cancellation: cancellationToken, reply: reply)

    guard !oneShotRequestHandlers.isEmpty else {
      fatalError("unexpected request \(request)")
    }
    let handler = oneShotRequestHandlers.removeFirst()
    handler(request)
  }
}

extension TestClient: Connection {

  /// Send a notification to the language server.
  public func send<Notification>(_ notification: Notification) where Notification: NotificationType {
    server.send(notification)
  }

  /// Send a request to the language server and (asynchronously) receive a reply.
  public func send<Request>(_ request: Request, queue: DispatchQueue, reply: @escaping (LSPResult<Request.Response>) -> Void) -> RequestID where Request: RequestType {
    return server.send(request, queue: queue, reply: reply)
  }

  /// Convenience method to get reply on replyQueue.
  public func send<Request>(_ request: Request, reply: @escaping (LSPResult<Request.Response>) -> Void) -> RequestID where Request: RequestType {
    return send(request, queue: replyQueue, reply: reply)
  }


  /// Send a notification and expect a notification in reply synchronously.
  /// For testing notifications that behave like requests  - e.g. didChange & publishDiagnostics.
  public func sendNoteSync<NSend, NReply>(_ notification: NSend, _ handler: @escaping (Notification<NReply>) -> Void) where NSend: NotificationType {

    let expectation = XCTestExpectation(description: "sendNoteSync - note received")

    handleNextNotification { (note: Notification<NReply>) in
      handler(note)
      expectation.fulfill()
    }

    send(notification)

    let result = XCTWaiter.wait(for: [expectation], timeout: 15)
    if result != .completed {
      fatalError("error \(result) waiting for notification in response to \(notification)")
    }
  }

  /// Send a notification and expect two notifications in reply synchronously.
  /// For testing notifications that behave like requests  - e.g. didChange & publishDiagnostics.
  public func sendNoteSync<NSend, NReply1, NReply2>(
    _ notification: NSend,
    _ handler1: @escaping (Notification<NReply1>) -> Void,
    _ handler2: @escaping (Notification<NReply2>) -> Void
  ) where NSend: NotificationType {

    let expectation = XCTestExpectation(description: "sendNoteSync - note received")
    expectation.expectedFulfillmentCount = 2

    handleNextNotification { (note: Notification<NReply1>) in
      handler1(note)
      expectation.fulfill()
    }
    appendOneShotNotificationHandler { (note: Notification<NReply2>) in
      handler2(note)
      expectation.fulfill()
    }

    send(notification)

    let result = XCTWaiter.wait(for: [expectation], timeout: 15)
    if result != .completed {
      fatalError("error \(result) waiting for notification in response to \(notification)")
    }
  }
}

public final class TestServer: MessageHandler {
  public let client: Connection

  init(client: Connection) {
    self.client = client
  }

  public func handle<N: NotificationType>(_ params: N, from clientID: ObjectIdentifier) {
    let note = Notification(params, clientID: clientID)
    if params is EchoNotification {
      self.client.send(note.params)
    } else {
      fatalError("Unhandled notification")
    }
  }

  public func handle<R: RequestType>(_ params: R, id: RequestID, from clientID: ObjectIdentifier, reply: @escaping (LSPResult<R.Response >) -> Void) {
    let cancellationToken = CancellationToken()

    if let params = params as? EchoRequest {
      let req = Request(params, id: id, clientID: clientID, cancellation: cancellationToken, reply: { result in
        reply(result.map({ $0 as! R.Response }))
      })
      req.reply(req.params.string)
    } else if let params = params as? EchoError {
      let req = Request(params, id: id, clientID: clientID, cancellation: cancellationToken, reply: { result in
        reply(result.map({ $0 as! R.Response }))
      })
      if let code = req.params.code {
        req.reply(.failure(ResponseError(code: code, message: req.params.message!)))
      } else {
        req.reply(VoidResponse())
      }
    } else {
      fatalError("Unhandled request")
    }
  }
}

// MARK: Test requests.

private let testMessageRegistry = MessageRegistry(
  requests: [EchoRequest.self, EchoError.self],
  notifications: [EchoNotification.self])

extension String: ResponseType {}

public struct EchoRequest: RequestType {
  public static var method: String = "test_server/echo"
  public typealias Response = String

  public var string: String

  public init(string: String) {
    self.string = string
  }
}

public struct EchoError: RequestType {
  public static var method: String = "test_server/echo_error"
  public typealias Response = VoidResponse

  public var code: ErrorCode?
  public var message: String?

  public init(code: ErrorCode? = nil, message: String? = nil) {
    self.code = code
    self.message = message
  }
}

public struct EchoNotification: NotificationType {
  public static var method: String = "test_server/echo_note"

  public var string: String

  public init(string: String) {
    self.string = string
  }
}
