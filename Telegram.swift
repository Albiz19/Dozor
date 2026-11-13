import Foundation

enum TelegramDelivery: Equatable {
    case sent, disabled, settings, unavailable, invalidReply, rejected(Int), rateLimited(Int?)

    var message: String {
        switch self {
        case .sent: return "Telegram принял сообщение"
        case .disabled: return "Уведомления выключены"
        case .settings: return "Проверьте токен бота и Chat ID"
        case .unavailable: return "Не удалось связаться с Telegram"
        case .invalidReply: return "Некорректный ответ Telegram"
        case .rejected(401): return "Telegram отклонил токен бота"
        case .rejected(403): return "Боту запрещено писать в этот чат"
        case .rejected(let code): return "Telegram отклонил запрос (код \(code))"
        case .rateLimited(let seconds): return seconds.map { "Повторите через \($0) с" } ?? "Превышен лимит запросов Telegram"
        }
    }
}

final class TelegramClient: NSObject, URLSessionTaskDelegate {
    private struct Reply: Decodable {
        struct Message: Decodable { let message_id: Int }
        struct Parameters: Decodable { let retry_after: Int? }
        let ok: Bool
        let result: Message?
        let error_code: Int?
        let parameters: Parameters?
    }

    // Only send bot credentials to the fixed Bot API endpoint.
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        completionHandler(nil)
    }

    func send(_ text: String, config: TelegramConfig, test: Bool, session: URLSession,
              completion: @escaping (TelegramDelivery) -> Void) {
        func finish(_ result: TelegramDelivery) { DispatchQueue.main.async { completion(result) } }
        guard test || config.enabled else { finish(.disabled); return }
        let token = config.bot_token.trimmingCharacters(in: .whitespacesAndNewlines)
        let chat = config.chat_id.trimmingCharacters(in: .whitespacesAndNewlines)
        guard token.range(of: #"^[0-9]+:[a-zA-Z0-9_-]+$"#, options: .regularExpression) != nil, !chat.isEmpty,
              !text.isEmpty, let url = URL(string: "https://api.telegram.org/bot\(token)/sendMessage") else {
            finish(.settings); return
        }
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 10)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try? JSONEncoder().encode(["chat_id": chat, "text": text])
        let task = session.dataTask(with: request) { data, response, error in
            guard error == nil, let http = response as? HTTPURLResponse else { finish(.unavailable); return }
            let reply = data.flatMap { try? JSONDecoder().decode(Reply.self, from: $0) }
            let code = reply?.error_code ?? http.statusCode
            if code == 429 { finish(.rateLimited(reply?.parameters?.retry_after)); return }
            guard (200..<300).contains(http.statusCode) else { finish(.rejected(code)); return }
            guard let reply else { finish(.invalidReply); return }
            guard reply.ok else { finish(.rejected(code)); return }
            guard reply.result != nil else { finish(.invalidReply); return }
            finish(.sent)
        }
        task.delegate = self
        task.resume()
    }
}
