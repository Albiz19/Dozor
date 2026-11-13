import Foundation

private final class BotStub: URLProtocol {
    static var requests = 0
    static var status = 200
    static var body = ""
    static var disconnected = false

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        Self.requests += 1
        precondition(request.url?.absoluteString == "https://api.telegram.org/bot123:fixture/sendMessage")
        precondition(request.httpMethod == "POST" && request.value(forHTTPHeaderField: "Content-Type") == "application/json")
        var payload = request.httpBody ?? Data()
        if let stream = request.httpBodyStream {
            stream.open(); defer { stream.close() }
            var buffer = [UInt8](repeating: 0, count: 512)
            while true {
                let count = stream.read(&buffer, maxLength: buffer.count)
                if count <= 0 { break }
                payload.append(contentsOf: buffer.prefix(count))
            }
        }
        let fields = try! JSONDecoder().decode([String: String].self, from: payload)
        precondition(fields["chat_id"] == "-123" && fields["text"] == "Дозор: Заморожено: Fixture")
        if Self.disconnected {
            client?.urlProtocol(self, didFailWithError: URLError(.notConnectedToInternet))
        } else {
            let response = HTTPURLResponse(url: request.url!, statusCode: Self.status, httpVersion: "HTTP/1.1", headerFields: nil)!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: Data(Self.body.utf8))
            client?.urlProtocolDidFinishLoading(self)
        }
    }
    override func stopLoading() {}
}

func testServices() throws {
    let m = Monitor()
    let c = URLSessionConfiguration.ephemeral
    c.protocolClasses = [BotStub.self]
    m.telegramSession = URLSession(configuration: c)
    m.cfg.notifications = false
    m.cfg.telegram.bot_token = " 123:fixture\n"
    m.cfg.telegram.chat_id = " -123 "
    func wait(_ condition: () -> Bool) {
        let deadline = Date().addingTimeInterval(3)
        while !condition() && Date() < deadline { RunLoop.current.run(until: Date().addingTimeInterval(0.01)) }
        precondition(condition())
    }
    func trial(_ expected: TelegramDelivery, _ description: String, force: Bool = false) {
        var result: TelegramDelivery?
        m.sendTelegram("Дозор: Заморожено: Fixture", force: force) { result = $0; precondition(Thread.isMainThread) }
        wait { result != nil }
        expect(result == expected, description)
    }
    trial(.disabled, "Telegram opt-out makes no request")
    expect(BotStub.requests == 0, "disabled Telegram sends nothing")
    BotStub.body = #"{"ok":true,"result":{"message_id":1}}"#
    trial(.sent, "manual Telegram test validates message receipt even when notifications are disabled", force: true)
    m.cfg.telegram.enabled = true
    m.notify("Заморожено: Fixture")
    wait { BotStub.requests == 2 }
    expect(m.events.contains { $0.contains("Заморожено: Fixture") }, "guard notification reaches Telegram and local log")
    BotStub.body = #"{"ok":false,"error_code":403}"#
    trial(.rejected(403), "HTTP 200 with API rejection is not success")
    BotStub.body = #"{"ok":true}"#
    trial(.invalidReply, "Telegram requires a message receipt")
    BotStub.body = "not JSON"
    trial(.invalidReply, "malformed Telegram reply is rejected")
    BotStub.status = 401
    trial(.rejected(401), "Telegram unauthorized error without JSON")
    BotStub.status = 429; BotStub.body = #"{"ok":false,"error_code":429,"parameters":{"retry_after":17}}"#
    trial(.rateLimited(17), "Telegram reports the server retry interval")
    BotStub.disconnected = true
    trial(.unavailable, "Telegram network failure is reported")
    let count = BotStub.requests
    m.cfg.telegram.bot_token = "no/token"
    trial(.settings, "invalid bot settings blocked before HTTP")
    expect(count == BotStub.requests && !m.events.contains { $0.contains("fixture/sendMessage") || $0.contains("123:fixture") }, "no token in logs")
    m.telegramSession.invalidateAndCancel()

    func release(_ tag: String, _ draft: Bool = false, _ pre: Bool = false) -> PublicRelease {
        PublicRelease(tag_name: tag, draft: draft, prerelease: pre)
    }
    let newer = try release("v0.10").newer(than: "0.9")
    let equal = try release("v0.1.0").newer(than: "0.1")
    let older = try release("v0.1").newer(than: "0.1.1")
    expect(newer && !equal && !older, "update comparison handles minor/patch numbers numerically")
    for invalid in [release("v0.2",true), release("v0.2",false,true), release("v0.2-beta"), release("v1/other")] {
        expect((try? invalid.newer(than: "0.1")) == nil, "reject unpublished or malformed release")
    }
}
