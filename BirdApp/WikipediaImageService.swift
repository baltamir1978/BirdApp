import Foundation

struct WikipediaInfo: Sendable {
    let imageURL: String?
    let localizedName: String?  // Common name in the device language (nil if en or not found)
}

// A short article summary for the bird-detail screen, in the app's language
// when available (otherwise English).
struct WikipediaArticle: Sendable {
    let title: String?        // Article title (the localized common name)
    let extract: String?      // Plain-text intro paragraph
    let articleURL: URL?      // Full article, in the app language when it exists
    let imageURL: String?     // Lead thumbnail
}

// Fetches a bird's Wikipedia thumbnail and localized common name.
// Image: English Wikipedia (most complete).
// Localized name: MediaWiki langlinks → fallback to {lang}.wikipedia.org title.
actor WikipediaImageService {
    static let shared = WikipediaImageService()

    private var cache: [String: WikipediaInfo] = [:]
    private var articleCache: [String: WikipediaArticle] = [:]

    func info(for scientificName: String) async -> WikipediaInfo {
        if let cached = cache[scientificName] { return cached }

        let slug = scientificName
            .trimmingCharacters(in: .whitespaces)
            .replacingOccurrences(of: " ", with: "_")
        guard !slug.isEmpty else { return WikipediaInfo(imageURL: nil, localizedName: nil) }

        let lang = Self.deviceLang
        async let imageResult = fetchImage(slug: slug)
        async let nameResult  = lang == "en" ? nil : fetchLocalizedName(slug: slug, lang: lang)

        let result = WikipediaInfo(imageURL: await imageResult, localizedName: await nameResult)
        cache[scientificName] = result
        return result
    }

    // Full intro summary + article link for the detail screen. Prefers the app
    // language: resolves the localized article title via langlinks, then pulls
    // that article's REST summary; falls back to the English article.
    func article(for scientificName: String) async -> WikipediaArticle {
        if let cached = articleCache[scientificName] { return cached }

        let slug = scientificName
            .trimmingCharacters(in: .whitespaces)
            .replacingOccurrences(of: " ", with: "_")
        guard !slug.isEmpty else {
            return WikipediaArticle(title: nil, extract: nil, articleURL: nil, imageURL: nil)
        }

        let lang = Self.deviceLang
        var result = WikipediaArticle(title: nil, extract: nil, articleURL: nil, imageURL: nil)

        if lang != "en", let localized = await fetchLocalizedName(slug: slug, lang: lang) {
            let localizedSlug = localized.replacingOccurrences(of: " ", with: "_")
            let art = await fetchSummary(title: localizedSlug, lang: lang)
            if art.extract != nil { result = art }
        }
        // Fall back to the English article if no localized summary was found.
        if result.extract == nil {
            result = await fetchSummary(title: slug, lang: "en")
        }

        articleCache[scientificName] = result
        return result
    }

    // MARK: - Helpers

    private func fetchSummary(title: String, lang: String) async -> WikipediaArticle {
        let encoded = title.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? title
        guard let url = URL(string: "https://\(lang).wikipedia.org/api/rest_v1/page/summary/\(encoded)") else {
            return WikipediaArticle(title: nil, extract: nil, articleURL: nil, imageURL: nil)
        }
        do {
            let (data, response) = try await URLSession.shared.data(from: url)
            guard (response as? HTTPURLResponse)?.statusCode == 200,
                  let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]
            else { return WikipediaArticle(title: nil, extract: nil, articleURL: nil, imageURL: nil) }

            let extract = (json["extract"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
            let pageTitle = json["title"] as? String
            let pageURL = ((json["content_urls"] as? [String: Any])?["desktop"] as? [String: Any])?["page"] as? String
            let thumb = (json["thumbnail"] as? [String: Any])?["source"] as? String
            return WikipediaArticle(
                title: pageTitle,
                extract: (extract?.isEmpty == false) ? extract : nil,
                articleURL: pageURL.flatMap(URL.init),
                imageURL: thumb
            )
        } catch {
            return WikipediaArticle(title: nil, extract: nil, articleURL: nil, imageURL: nil)
        }
    }

    // "es-ES" → "es",  "en-US" → "en"
    private static let deviceLang: String = {
        let lang = Locale.preferredLanguages.first ?? "en"
        return String(lang.prefix(2)).lowercased()
    }()

    private func fetchImage(slug: String) async -> String? {
        var comps = URLComponents(string: "https://en.wikipedia.org/w/api.php")!
        comps.queryItems = [
            URLQueryItem(name: "action",      value: "query"),
            URLQueryItem(name: "titles",      value: slug),
            URLQueryItem(name: "prop",        value: "pageimages"),
            URLQueryItem(name: "piprop",      value: "thumbnail"),
            URLQueryItem(name: "pithumbsize", value: "600"),
            URLQueryItem(name: "format",      value: "json"),
            URLQueryItem(name: "redirects",   value: "1"),
        ]
        guard let url = comps.url,
              let page = try? await wikiPage(url: url)
        else { return nil }
        return (page["thumbnail"] as? [String: Any])?["source"] as? String
    }

    private func fetchLocalizedName(slug: String, lang: String) async -> String? {
        // 1. Try langlinks from English Wikipedia
        if let name = await fetchViaLanglinks(slug: slug, lang: lang) { return name }
        // 2. Fallback: article title on {lang}.wikipedia.org IS the local common name
        return await fetchViaLocalWiki(slug: slug, lang: lang)
    }

    private func fetchViaLanglinks(slug: String, lang: String) async -> String? {
        var comps = URLComponents(string: "https://en.wikipedia.org/w/api.php")!
        comps.queryItems = [
            URLQueryItem(name: "action",    value: "query"),
            URLQueryItem(name: "titles",    value: slug),
            URLQueryItem(name: "prop",      value: "langlinks"),
            URLQueryItem(name: "lllang",    value: lang),
            URLQueryItem(name: "format",    value: "json"),
            URLQueryItem(name: "redirects", value: "1"),
        ]
        guard let url = comps.url,
              let page = try? await wikiPage(url: url),
              let links = page["langlinks"] as? [[String: Any]],
              let match = links.first(where: { ($0["lang"] as? String) == lang }),
              let title = match["*"] as? String,
              !isScientificName(title, slug: slug)
        else { return nil }
        return title
    }

    private func fetchViaLocalWiki(slug: String, lang: String) async -> String? {
        guard let url = URL(string: "https://\(lang).wikipedia.org/api/rest_v1/page/summary/\(slug)")
        else { return nil }
        do {
            let (data, response) = try await URLSession.shared.data(from: url)
            guard (response as? HTTPURLResponse)?.statusCode == 200,
                  let json  = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let title = json["title"] as? String,
                  !isScientificName(title, slug: slug)
            else { return nil }
            return title
        } catch { return nil }
    }

    // Returns true if title is just the scientific name (or a disambiguation variant like "Turdus merula (ave)").
    private func isScientificName(_ title: String, slug: String) -> Bool {
        let sci = slug.lowercased().replacingOccurrences(of: "_", with: " ")
        return title.lowercased().hasPrefix(sci)
    }

    private func wikiPage(url: URL) async throws -> [String: Any]? {
        let (data, response) = try await URLSession.shared.data(from: url)
        guard (response as? HTTPURLResponse)?.statusCode == 200,
              let json  = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let query = json["query"] as? [String: Any],
              let pages = query["pages"] as? [String: Any],
              let page  = pages.values.first as? [String: Any]
        else { return nil }
        return page
    }
}
