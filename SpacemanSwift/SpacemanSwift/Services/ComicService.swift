import Foundation

enum ComicError: LocalizedError {
    case noStrip          // page doesn't exist for that date (404)
    case blocked(Int)     // server refused the request (e.g. 403 bot protection)
    case server(Int)
    case parseFailed
    case network(Error)
    case coolingDown(TimeInterval)  // we paused ourselves after a 403/429

    var errorDescription: String? {
        switch self {
        case .coolingDown(let seconds):
            "GoComics is limiting requests. Try again in \(Int(seconds.rounded(.up)))s."
        case .noStrip: "There's no strip for this day."
        case .blocked(let code): "GoComics refused the request (HTTP \(code))."
        case .server(let code): "GoComics returned an error (HTTP \(code))."
        case .parseFailed: "Couldn't find the comic image on the page."
        case .network(let error): error.localizedDescription
        }
    }
}

struct ComicService {
    /// First Calvin and Hobbes strip ran on 18 November 1985.
    static let firstStripDate: Date = {
        var c = DateComponents(); c.year = 1985; c.month = 11; c.day = 18
        return Calendar.gregorian.date(from: c)!
    }()

    var session: URLSession = Self.makeSession()
    var gate: RequestGate = .shared

    /// Browser-like session: persistent cookie jar (so any clearance/session cookies GoComics
    /// sets are replayed), HTTP/2 + system TLS (Safari-like fingerprint), no custom proxying.
    static func makeSession() -> URLSession {
        let config = URLSessionConfiguration.default
        config.httpCookieStorage = .shared
        config.httpCookieAcceptPolicy = .always
        config.httpShouldSetCookies = true
        config.waitsForConnectivity = true
        config.httpMaximumConnectionsPerHost = 2
        config.timeoutIntervalForRequest = 20
        return URLSession(configuration: config)
    }

    /// Headers a real mobile Safari navigation would send.
    static let browserHeaders: [String: String] = [
        "User-Agent": "Mozilla/5.0 (iPhone; CPU iPhone OS 18_5 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/18.5 Mobile/15E148 Safari/604.1",
        "Accept": "text/html,application/xhtml+xml,application/xml;q=0.9,*/*;q=0.8",
        "Accept-Language": "en-US,en;q=0.9",
        "Upgrade-Insecure-Requests": "1",
        "Sec-Fetch-Dest": "document",
        "Sec-Fetch-Mode": "navigate",
        "Sec-Fetch-User": "?1",
    ]

    static func pageURL(for date: Date) -> URL {
        let f = DateFormatter()
        f.calendar = .gregorian
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy/MM/dd"
        return URL(string: "https://www.gocomics.com/calvinandhobbes/\(f.string(from: date))")!
    }

    func imageURL(for date: Date) async throws -> URL {
        let pageURL = Self.pageURL(for: date)

        // Already resolved this day: no network request at all.
        if let cached = await gate.cachedImageURL(for: pageURL) { return cached }

        // Respect any cooldown from an earlier 403/429, and pace requests.
        try await gate.waitForTurn()

        var request = URLRequest(url: pageURL)
        for (k, v) in Self.browserHeaders { request.setValue(v, forHTTPHeaderField: k) }
        // Look like in-site navigation: Referer is the last page we successfully loaded.
        if let referer = await gate.lastVisited {
            request.setValue(referer.absoluteString, forHTTPHeaderField: "Referer")
            request.setValue("same-origin", forHTTPHeaderField: "Sec-Fetch-Site")
        } else {
            request.setValue("none", forHTTPHeaderField: "Sec-Fetch-Site")
        }
        request.timeoutInterval = 20

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch is CancellationError {
            throw CancellationError()
        } catch let error as URLError where error.code == .cancelled {
            throw CancellationError()
        } catch {
            throw ComicError.network(error)
        }

        if let http = response as? HTTPURLResponse {
            switch http.statusCode {
            case 200..<300: break
            case 404: throw ComicError.noStrip
            case 401, 403, 429:
                // Don't keep hammering: back off (honouring Retry-After) before the next request.
                let retryAfter = http.value(forHTTPHeaderField: "Retry-After").flatMap(TimeInterval.init)
                await gate.recordBlock(status: http.statusCode, retryAfter: retryAfter)
                throw ComicError.blocked(http.statusCode)
            default: throw ComicError.server(http.statusCode)
            }
        }

        let html = String(decoding: data, as: UTF8.self)
        guard let url = Self.parseImageURL(fromHTML: html) else { throw ComicError.parseFailed }
        await gate.recordSuccess(page: pageURL, image: url)
        return url
    }

    /// Looks for `og:image` (then `twitter:image`) meta tags, in either attribute order.
    nonisolated static func parseImageURL(fromHTML html: String) -> URL? {
        for key in ["og:image", "twitter:image"] {
            let escaped = NSRegularExpression.escapedPattern(for: key)
            let patterns = [
                #"<meta[^>]+(?:property|name)\s*=\s*["']\#(escaped)["'][^>]*content\s*=\s*["']([^"']+)["']"#,
                #"<meta[^>]+content\s*=\s*["']([^"']+)["'][^>]*(?:property|name)\s*=\s*["']\#(escaped)["']"#,
            ]
            for pattern in patterns {
                guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]),
                      let match = regex.firstMatch(in: html, range: NSRange(html.startIndex..., in: html)),
                      let range = Range(match.range(at: 1), in: html)
                else { continue }
                let raw = String(html[range]).replacingOccurrences(of: "&amp;", with: "&")
                if let url = URL(string: raw), url.scheme?.hasPrefix("http") == true { return url }
            }
        }
        return nil
    }
}

extension Calendar {
    nonisolated static let gregorian = Calendar(identifier: .gregorian)
}

/// Shared pacing / cooldown / cache state so rapid navigation doesn't look like a scraper.
actor RequestGate {
    static let shared = RequestGate()

    /// Minimum spacing between page requests.
    private let minInterval: TimeInterval = 0.8
    /// Cooldown after consecutive blocks grows exponentially, capped.
    private let baseCooldown: TimeInterval = 30
    private let maxCooldown: TimeInterval = 15 * 60

    private var nextAllowed: Date = .distantPast
    private var cooldownUntil: Date = .distantPast
    private var consecutiveBlocks = 0
    private var imageCache: [URL: URL] = [:]
    private(set) var lastVisited: URL?

    func cachedImageURL(for page: URL) -> URL? { imageCache[page] }

    /// Throws if cooling down; otherwise sleeps just long enough to keep requests spaced.
    func waitForTurn() async throws {
        let now = Date()
        if cooldownUntil > now { throw ComicError.coolingDown(cooldownUntil.timeIntervalSince(now)) }
        // Reserve our slot before suspending so concurrent callers queue up behind us.
        let start = max(now, nextAllowed)
        nextAllowed = start.addingTimeInterval(minInterval)
        let delay = start.timeIntervalSince(now)
        if delay > 0 { try await Task.sleep(for: .seconds(delay)) }
    }

    func recordSuccess(page: URL, image: URL) {
        consecutiveBlocks = 0
        imageCache[page] = image
        lastVisited = page
    }

    func recordBlock(status: Int, retryAfter: TimeInterval?) {
        consecutiveBlocks += 1
        let backoff = min(baseCooldown * pow(2, Double(consecutiveBlocks - 1)), maxCooldown)
        let wait = min(max(retryAfter ?? 0, backoff), maxCooldown)
        cooldownUntil = Date().addingTimeInterval(wait)
    }
}
