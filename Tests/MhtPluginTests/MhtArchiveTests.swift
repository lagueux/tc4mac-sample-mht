import Foundation
@testable import MhtPlugin
import Testing
import TCPluginSDK

/// An MHTML document as a browser actually writes one: CRLF endings, a
/// quoted-printable HTML part, a base64 image, absolute Content-Locations,
/// and an epilogue after the closing boundary.
private let savedPage = """
From: <Saved by tc4mac>\r
Subject: Example\r
MIME-Version: 1.0\r
Content-Type: multipart/related;\r
\tboundary="----=_NextPart_000_0000";\r
\ttype="text/html"\r
\r
------=_NextPart_000_0000\r
Content-Type: text/html; charset="utf-8"\r
Content-Transfer-Encoding: quoted-printable\r
Content-Location: https://example.com/index.html\r
\r
<html><body><p>Caf=C3=A9 =\r
time</p></body></html>\r
------=_NextPart_000_0000\r
Content-Type: image/png\r
Content-Transfer-Encoding: base64\r
Content-Location: https://example.com/images/logo.png?v=3\r
\r
UE5HIGRhdGE=\r
------=_NextPart_000_0000--\r
\r
epilogue that is not a part\r
"""

@Suite("MHTML archive format")
struct MhtArchiveTests {
    @Test("a saved page parses into its parts, decoded and named")
    func parsesSavedPage() throws {
        let parts = try MhtArchive.parse(Data(savedPage.utf8))
        #expect(parts.count == 2)

        // The path comes from the Content-Location, so the page keeps its
        // folder shape and loses the query string.
        #expect(parts[0].path == "index.html")
        #expect(parts[1].path == "images/logo.png")

        // Quoted-printable: "=C3=A9" is é and "=" at line end is a soft break.
        let html = String(bytes: parts[0].body, encoding: .utf8)
        #expect(html == "<html><body><p>Café time</p></body></html>")
        #expect(String(bytes: parts[1].body, encoding: .utf8) == "PNG data")
        #expect(parts[1].contentType == "image/png")
    }

    @Test("what is packed can be read back, byte for byte")
    func roundTrip() throws {
        let original = [
            MhtArchive.Part(
                path: "index.html", contentType: "text/html",
                body: Data("<h1>hello</h1>".utf8)),
            MhtArchive.Part(
                path: "images/logo.png", contentType: "image/png",
                body: Data((0..<256).map { UInt8($0) }))
        ]
        let document = MhtArchive.build(original, boundary: MhtArchive.makeBoundary())
        let parsed = try MhtArchive.parse(document)
        #expect(parsed.count == 2)
        #expect(parsed.first { $0.path == "index.html" }?.body == original[0].body)
        // Arbitrary bytes survive the base64 trip intact.
        #expect(parsed.first { $0.path == "images/logo.png" }?.body == original[1].body)
    }

    @Test("the HTML part is written first, because the root must come first")
    func rootComesFirst() throws {
        let document = MhtArchive.build([
            MhtArchive.Part(path: "a.png", contentType: "image/png", body: Data("x".utf8)),
            MhtArchive.Part(path: "page.html", contentType: "text/html", body: Data("y".utf8))
        ], boundary: "BOUND")
        #expect(try MhtArchive.parse(document).first?.path == "page.html")
    }

    @Test("a part cannot escape the archive when it is extracted")
    func pathTraversalIsRefused() {
        // A hostile Content-Location must not write outside the destination.
        #expect(MhtArchive.path(
            fromLocation: "https://evil.test/../../../etc/passwd", contentType: "text/plain")
            == "etc/passwd")
        #expect(MhtArchive.path(fromLocation: "/../../secret", contentType: "text/plain")
            == "secret")
        // A part with no location still gets a name, from its type.
        #expect(MhtArchive.path(fromLocation: "", contentType: "text/html") == "index.html")
        #expect(MhtArchive.path(fromLocation: "https://example.com/", contentType: "text/css")
            == "style.css")
    }

    @Test("two parts naming the same file still list as separate rows")
    func duplicateNames() throws {
        let document = """
        Content-Type: multipart/related; boundary=B\r
        \r
        --B\r
        Content-Type: text/plain\r
        Content-Location: http://a.test/note.txt\r
        \r
        first\r
        --B\r
        Content-Type: text/plain\r
        Content-Location: http://b.test/note.txt\r
        \r
        second\r
        --B--\r
        """
        let parts = try MhtArchive.parse(Data(document.utf8))
        #expect(parts.map(\.path) == ["note.txt", "note-2.txt"])
    }

    @Test("something that is not multipart is refused, not half-parsed")
    func rejectsNonMultipart() {
        #expect(throws: MhtArchive.Failure.notMultipart) {
            _ = try MhtArchive.parse(Data("Content-Type: text/plain\r\n\r\nhello".utf8))
        }
        #expect(throws: MhtArchive.Failure.noBoundary) {
            _ = try MhtArchive.parse(Data("Content-Type: multipart/related\r\n\r\nbody".utf8))
        }
        #expect(throws: (any Error).self) { _ = try MhtArchive.parse(Data()) }
    }

    @Test("the plugin declares what the format can actually do")
    func capabilities() {
        let plugin = MhtPackerPlugin()
        #expect(plugin.extensions == ["mht", "mhtml"])
        #expect(plugin.capabilities.contains(.create))
        #expect(plugin.capabilities.contains(.detectByContent))
        // No .modify: adding to an MHT rewrites the whole document, and the
        // dialog must not offer an "add" that silently rebuilds the file.
        #expect(!plugin.capabilities.contains(.modify))
        #expect(!plugin.capabilities.contains(.delete))
    }

    @Test("a document is recognised by its header, whatever it is named")
    func detectsByContent() async throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("saved-\(UUID().uuidString).eml")
        try Data(savedPage.utf8).write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }
        #expect(await MhtPackerPlugin().canHandle(fileAt: url))

        let plain = url.deletingPathExtension().appendingPathExtension("txt")
        try Data("just text".utf8).write(to: plain)
        defer { try? FileManager.default.removeItem(at: plain) }
        #expect(await MhtPackerPlugin().canHandle(fileAt: plain) == false)
    }
}
