import Foundation

/// MHTML (`.mht`) — a saved web page: the HTML plus every image, stylesheet
/// and script it needs, wrapped in one MIME `multipart/related` document.
/// That makes it an archive in every sense a file manager cares about, which
/// is why it is the packer sample: a real format, no dependencies, and both
/// directions are honest work.
///
/// Pure parsing and building; the plugin shell around it does the I/O.
public enum MhtArchive {
    /// One part of the document, as the panel will show it.
    public struct Part: Equatable, Sendable {
        /// Path derived from the part's Content-Location, so a page saved
        /// from a site keeps its folder shape ("images/logo.png").
        public var path: String
        public var contentType: String
        public var body: Data

        public init(path: String, contentType: String, body: Data) {
            self.path = path
            self.contentType = contentType
            self.body = body
        }
    }

    public enum Failure: Error, Equatable {
        case notMultipart
        case noBoundary
    }

    // MARK: - Reading

    /// Splits a document into its parts. Deliberately tolerant: a real `.mht`
    /// comes from Internet Explorer, Word, Chrome, or a scraper, and they
    /// disagree about header case, line endings, and whether the epilogue
    /// after the closing boundary exists at all.
    public static func parse(_ document: Data) throws -> [Part] {
        let text = latin1(document)
        let (headers, body) = splitHeaders(text)
        let contentType = headers["content-type"] ?? ""
        guard contentType.lowercased().contains("multipart/") else {
            throw Failure.notMultipart
        }
        guard let boundary = value(ofParameter: "boundary", in: contentType) else {
            throw Failure.noBoundary
        }

        var parts: [Part] = []
        var usedPaths: Set<String> = []
        for chunk in split(body, on: boundary) {
            let (partHeaders, partBody) = splitHeaders(chunk)
            guard !partHeaders.isEmpty else { continue }
            let encoding = (partHeaders["content-transfer-encoding"] ?? "")
                .trimmingCharacters(in: .whitespaces).lowercased()
            let type = value(beforeSemicolon: partHeaders["content-type"] ?? "text/plain")
            let decoded = decode(partBody, encoding: encoding)
            let location = partHeaders["content-location"]
                ?? partHeaders["content-id"]
                ?? ""
            var path = self.path(fromLocation: location, contentType: type)
            // Two parts may name the same file; the panel needs distinct rows.
            var counter = 2
            while usedPaths.contains(path.lowercased()) {
                let base = (path as NSString).deletingPathExtension
                let ext = (path as NSString).pathExtension
                path = ext.isEmpty ? "\(base)-\(counter)" : "\(base)-\(counter).\(ext)"
                counter += 1
            }
            usedPaths.insert(path.lowercased())
            parts.append(Part(path: path, contentType: type, body: decoded))
        }
        return parts
    }

    /// The name a part takes in the panel. A Content-Location is usually an
    /// absolute URL, and its path is what a person recognises; a part with
    /// none still needs a name, so it gets one from its type.
    static func path(fromLocation location: String, contentType: String) -> String {
        let trimmed = location.trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: CharacterSet(charactersIn: "<>"))
        var candidate = ""
        if let components = URLComponents(string: trimmed), !components.path.isEmpty {
            candidate = components.path
        } else {
            candidate = trimmed
        }
        candidate = candidate.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        // Query strings and fragments are not part of a file name.
        candidate = candidate.components(separatedBy: CharacterSet(charactersIn: "?#"))[0]
        if candidate.isEmpty || candidate.hasSuffix("/") {
            candidate += defaultName(for: contentType)
        }
        // A part must not escape the archive when extracted.
        return candidate
            .components(separatedBy: "/")
            .filter { !$0.isEmpty && $0 != "." && $0 != ".." }
            .joined(separator: "/")
    }

    private static func defaultName(for contentType: String) -> String {
        switch contentType.lowercased() {
        case "text/html": return "index.html"
        case "text/css": return "style.css"
        case "image/png": return "image.png"
        case "image/jpeg": return "image.jpg"
        case "application/javascript", "text/javascript": return "script.js"
        default: return "part"
        }
    }

    // MARK: - Writing

    /// Builds a document from files. The first HTML part is placed first,
    /// because `multipart/related` says the root comes first and browsers
    /// rely on it.
    public static func build(_ parts: [Part], boundary: String) -> Data {
        let ordered = parts.sorted { first, second in
            let firstIsRoot = first.contentType.lowercased() == "text/html"
            let secondIsRoot = second.contentType.lowercased() == "text/html"
            if firstIsRoot != secondIsRoot { return firstIsRoot }
            return first.path < second.path
        }
        var document = ""
        document += "MIME-Version: 1.0\r\n" // l10n:exempt: MIME header
        document += "Content-Type: multipart/related; boundary=\"\(boundary)\"\r\n" // l10n:exempt: MIME header
        if let root = ordered.first {
            document += "Content-Location: \(root.path)\r\n" // l10n:exempt: MIME header
        }
        document += "\r\n" // l10n:exempt: MIME header
        for part in ordered {
            document += "--\(boundary)\r\n" // l10n:exempt: MIME header
            document += "Content-Type: \(part.contentType)\r\n" // l10n:exempt: MIME header
            document += "Content-Transfer-Encoding: base64\r\n" // l10n:exempt: MIME header
            document += "Content-Location: \(part.path)\r\n\r\n" // l10n:exempt: MIME header
            document += wrapped(part.body.base64EncodedString()) + "\r\n"
        }
        document += "--\(boundary)--\r\n" // l10n:exempt: MIME header
        return Data(document.utf8)
    }

    /// A boundary that cannot appear inside the content it separates.
    public static func makeBoundary() -> String {
        let unique = UUID().uuidString.replacingOccurrences(of: "-", with: "") // l10n:exempt: token
        return "----=_tc4mac_\(unique)" // l10n:exempt: MIME boundary token
    }

    /// MIME wants base64 in short lines; 76 characters is the convention.
    private static func wrapped(_ base64: String) -> String {
        stride(from: 0, to: base64.count, by: 76).map { offset in
            let start = base64.index(base64.startIndex, offsetBy: offset)
            let end = base64.index(start, offsetBy: min(76, base64.count - offset))
            return String(base64[start..<end])
        }.joined(separator: "\r\n")
    }

    /// The MIME type for a file, so a packed part declares itself correctly.
    public static func contentType(forFileNamed name: String) -> String {
        switch (name as NSString).pathExtension.lowercased() {
        case "html", "htm": return "text/html"
        case "css": return "text/css"
        case "js": return "application/javascript"
        case "png": return "image/png"
        case "jpg", "jpeg": return "image/jpeg"
        case "gif": return "image/gif"
        case "svg": return "image/svg+xml"
        case "txt": return "text/plain"
        default: return "application/octet-stream"
        }
    }

    // MARK: - MIME plumbing

    /// Bytes as text without ever failing: a MIME document mixes headers in
    /// ASCII with bodies in any encoding, and Latin-1 maps every byte to a
    /// character, so nothing is lost before the parts are decoded.
    static func latin1(_ data: Data) -> String {
        String(data: data, encoding: .isoLatin1) ?? ""
    }

    static func latin1(_ text: String) -> Data {
        text.data(using: .isoLatin1) ?? Data()
    }

    /// Headers up to the first blank line, lower-cased keys, plus the rest.
    /// Continuation lines (a header folded onto the next, indented) are
    /// joined back on, which is how long Content-Location values arrive.
    static func splitHeaders(_ text: String) -> ([String: String], String) {
        let normalized = text.replacingOccurrences(of: "\r\n", with: "\n")
        guard let blank = normalized.range(of: "\n\n") else { return ([:], normalized) }
        let headerText = String(normalized[..<blank.lowerBound])
        let body = String(normalized[blank.upperBound...])
        var headers: [String: String] = [:]
        var lastKey: String?
        for line in headerText.split(separator: "\n", omittingEmptySubsequences: false) {
            if line.hasPrefix(" ") || line.hasPrefix("\t") {
                if let lastKey {
                    headers[lastKey, default: ""] += line.trimmingCharacters(in: .whitespaces)
                }
                continue
            }
            guard let colon = line.firstIndex(of: ":") else { continue }
            let key = line[..<colon].trimmingCharacters(in: .whitespaces).lowercased()
            headers[key] = line[line.index(after: colon)...]
                .trimmingCharacters(in: .whitespaces)
            lastKey = key
        }
        return (headers, body)
    }

    /// The chunks between boundary markers, excluding the preamble and
    /// whatever follows the closing marker.
    static func split(_ body: String, on boundary: String) -> [String] {
        let marker = "--" + boundary
        var chunks = body.components(separatedBy: marker)
        if !chunks.isEmpty { chunks.removeFirst() }  // preamble
        return chunks.compactMap { chunk in
            if chunk.hasPrefix("--") { return nil }  // closing marker onward
            var trimmed = chunk.hasPrefix("\n") ? String(chunk.dropFirst()) : chunk
            // MIME counts the line break BEFORE a boundary as part of the
            // boundary, not of the body — keeping it appends a stray newline
            // to every extracted file.
            if trimmed.hasSuffix("\n") { trimmed.removeLast() }
            return trimmed.isEmpty ? nil : trimmed
        }
    }

    static func decode(_ body: String, encoding: String) -> Data {
        switch encoding {
        case "base64":
            let stripped = body.filter { !$0.isWhitespace }
            return Data(base64Encoded: stripped, options: .ignoreUnknownCharacters) ?? Data()
        case "quoted-printable":
            return quotedPrintable(body)
        default:
            return latin1(body)
        }
    }

    /// Quoted-printable: "=XX" is a byte, "=" at end of line is a soft break.
    static func quotedPrintable(_ text: String) -> Data {
        var out = Data()
        let characters = Array(text.replacingOccurrences(of: "\r\n", with: "\n"))
        var index = 0
        while index < characters.count {
            let character = characters[index]
            guard character == "=" else {
                out.append(contentsOf: String(character).data(using: .isoLatin1) ?? Data())
                index += 1
                continue
            }
            if index + 1 < characters.count, characters[index + 1] == "\n" {
                index += 2  // soft line break: the newline is not content
                continue
            }
            guard index + 2 < characters.count,
                  let byte = UInt8(String(characters[(index + 1)...(index + 2)]), radix: 16)
            else {
                out.append(0x3D)  // a lone "=" is literal
                index += 1
                continue
            }
            out.append(byte)
            index += 3
        }
        return out
    }

    /// `boundary="…"` out of a Content-Type value, quoted or bare.
    static func value(ofParameter name: String, in header: String) -> String? {
        for piece in header.components(separatedBy: ";") {
            let trimmed = piece.trimmingCharacters(in: .whitespaces)
            guard trimmed.lowercased().hasPrefix(name.lowercased() + "=") else { continue }
            var value = String(trimmed.dropFirst(name.count + 1))
                .trimmingCharacters(in: .whitespaces)
            if value.hasPrefix("\"") && value.hasSuffix("\"") && value.count >= 2 {
                value = String(value.dropFirst().dropLast())
            }
            return value.isEmpty ? nil : value
        }
        return nil
    }

    static func value(beforeSemicolon header: String) -> String {
        header.components(separatedBy: ";")[0]
            .trimmingCharacters(in: .whitespaces)
            .lowercased()
    }
}
