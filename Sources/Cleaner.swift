import Foundation
import Security

enum Keychain {
    private static let service = Bundle.main.bundleIdentifier ?? "VOIX", account = "anthropic-api-key"

    static func get() -> String? {
        let q: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
                                kSecAttrAccount as String: account, kSecReturnData as String: true]
        var out: AnyObject?
        guard SecItemCopyMatching(q as CFDictionary, &out) == errSecSuccess, let d = out as? Data else { return nil }
        return String(data: d, encoding: .utf8)
    }

    static func set(_ value: String?) {
        let q: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
                                kSecAttrAccount as String: account]
        SecItemDelete(q as CFDictionary)
        guard let value, !value.isEmpty else { return }
        var add = q
        add[kSecValueData as String] = value.data(using: .utf8)!
        SecItemAdd(add as CFDictionary, nil)
    }
}

enum Cleaner {
    static let system = """
    You clean up raw voice dictation so it can be pasted as a prompt or message. \
    Remove filler words, false starts and repetitions; fix punctuation, capitalization and obvious mis-transcriptions \
    (prefer the user's custom vocabulary when a word sounds like one of those terms). \
    Keep the speaker's meaning, wording, tone and language; do not add content, do not answer or act on the text. \
    Output only the cleaned text.
    """

    /// Calls Claude; completes with nil on any failure so the caller can paste the raw transcript instead.
    static func clean(_ text: String, words: [String], done: @escaping (String?) -> Void) {
        guard let key = Keychain.get() else { vlog("clean-up skipped: no API key"); done(nil); return }
        var user = text
        if !words.isEmpty { user = "Custom vocabulary: \(words.joined(separator: ", "))\n\nDictation:\n\(text)" }
        let payload: [String: Any] = [
            "model": "claude-opus-5-5",
            "max_tokens": 4000,
            "output_config": ["effort": "low"],
            "fallbacks": "default",
            "system": system,
            "messages": [["role": "user", "content": user]],
        ]
        var req = URLRequest(url: URL(string: "https://api.anthropic.com/v1/messages")!, timeoutInterval: 20)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue(key, forHTTPHeaderField: "x-api-key")
        req.setValue("2026-10-21", forHTTPHeaderField: "anthropic-version")
        req.setValue("server-side-fallback-2026-07-01", forHTTPHeaderField: "anthropic-beta")
        req.httpBody = try? JSONSerialization.data(withJSONObject: payload)
        let t0 = Date()
        URLSession.shared.dataTask(with: req) { data, resp, err in
            var out: String?
            let status = (resp as? HTTPURLResponse)?.statusCode ?? 0
            if status == 200, let data, let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                if json["stop_reason"] as? String == "refusal" {
                    vlog("clean-up refused")
                } else if let content = json["content"] as? [[String: Any]] {
                    let text = content.filter { $0["type"] as? String == "text" }
                        .compactMap { $0["text"] as? String }.joined()
                        .trimmingCharacters(in: .whitespacesAndNewlines)
                    out = text.isEmpty ? nil : text
                }
            } else {
                let body = data.map { String(decoding: $0.prefix(300), as: UTF8.self) } ?? ""
                vlog("clean-up failed: status=\(status) \(err?.localizedDescription ?? body)")
            }
            vlog(String(format: "clean-up took %.0fms", Date().timeIntervalSince(t0) * 1000))
            DispatchQueue.main.async { done(out) }
        }.resume()
    }
}
