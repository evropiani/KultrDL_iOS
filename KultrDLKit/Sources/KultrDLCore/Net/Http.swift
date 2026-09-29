import Foundation

public struct HttpError: LocalizedError, Sendable {
    public let code: Int
    public let host: String
    public let body: String?

    public var errorDescription: String? { "HTTP \(code) from \(host)" }
}

/** Plain HTTP for the catalogue APIs, cancelled with the task that asked. */
public final class Http: @unchecked Sendable {
    public static let browserUserAgent =
        "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/139.0.0.0 Safari/537.36"

    public let session: URLSession

    public init(session: URLSession? = nil) {
        if let session {
            self.session = session
        } else {
            let config = URLSessionConfiguration.default
            config.timeoutIntervalForRequest = 30
            config.timeoutIntervalForResource = 120
            config.httpCookieStorage = HTTPCookieStorage()
            config.httpCookieAcceptPolicy = .always
            config.requestCachePolicy = .reloadIgnoringLocalCacheData
            config.urlCache = nil
            self.session = URLSession(configuration: config)
        }
    }

    public func get(_ url: String, headers: [String: String] = [:]) async throws -> String {
        try await text(request(url, method: "GET", headers: headers))
    }

    public func getData(_ url: String, headers: [String: String] = [:]) async throws -> Data {
        let (data, _) = try await perform(request(url, method: "GET", headers: headers))
        return data
    }

    public func getJSON(_ url: String, headers: [String: String] = [:]) async throws -> JSON {
        try JSON.parse(try await getData(url, headers: headers))
    }

    public func postJSON(_ url: String, body: JSON, headers: [String: String] = [:]) async throws -> JSON {
        var req = try request(url, method: "POST", headers: headers)
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = Data(body.compact.utf8)
        let (data, _) = try await perform(req)
        return try JSON.parse(data)
    }

    public func postForm(_ url: String, fields: [String: String], headers: [String: String] = [:]) async throws -> String {
        var req = try request(url, method: "POST", headers: headers)
        req.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        req.httpBody = Data(fields.map { "\($0.key.urlQueryEncoded)=\($0.value.urlQueryEncoded)" }.joined(separator: "&").utf8)
        return try await text(req)
    }

    /** Where [url] ends up after redirects (short links such as spotify.link). */
    public func finalUrl(_ url: String) async throws -> String {
        let req = try request(url, method: "GET", headers: [:])
        let (_, response) = try await session.data(for: req)
        return response.url?.absoluteString ?? url
    }

    public func request(_ url: String, method: String, headers: [String: String]) throws -> URLRequest {
        guard let u = URL(string: url) else { throw KultrError("Bad address: \(url)") }
        var req = URLRequest(url: u)
        req.httpMethod = method
        req.setValue(Self.browserUserAgent, forHTTPHeaderField: "User-Agent")
        req.setValue("en-US,en;q=0.9", forHTTPHeaderField: "Accept-Language")
        for (k, v) in headers { req.setValue(v, forHTTPHeaderField: k) }
        return req
    }

    private func text(_ req: URLRequest) async throws -> String {
        let (data, _) = try await perform(req)
        return String(decoding: data, as: UTF8.self)
    }

    public func perform(_ req: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let (data, response) = try await session.data(for: req)
        guard let http = response as? HTTPURLResponse else { throw KultrError("No answer from \(req.url?.host ?? "the server")") }
        guard (200..<300).contains(http.statusCode) else {
            throw HttpError(code: http.statusCode, host: req.url?.host ?? "", body: String(data: data.prefix(2000), encoding: .utf8))
        }
        return (data, http)
    }
}
