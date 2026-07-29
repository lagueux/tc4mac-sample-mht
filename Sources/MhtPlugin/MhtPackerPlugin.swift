import Foundation
import TCPluginSDK

/// The MHT packer plugin — the WCX sample, written against the public SDK
/// exactly as a third party would write one. It reads and writes, because a
/// sample that only unpacks teaches half the interface, and the half authors
/// get wrong is packing.
///
/// CHM, the other format in this family, is read-only for a real reason:
/// unpacking needs an LZX decompressor and writing one is a research
/// project, not a sample. That is what the capability bits are for — the
/// Pack dialog offers MHT and not CHM without a special case anywhere.
public struct MhtPackerPlugin: PackerPlugin {
    public init() {}

    public var capabilities: PackerCapabilities {
        // No .modify: adding to an MHT means rewriting the whole document,
        // and claiming an ability the format cannot do cheaply would put a
        // button in front of the user that quietly rebuilds their file.
        [.create, .multipleFiles, .searchable, .detectByContent]
    }

    public var extensions: [String] { ["mht", "mhtml"] }

    /// A saved page is sometimes named `.eml`, or nothing at all. The header
    /// says what it really is, and reading a few hundred bytes is cheaper
    /// than being wrong.
    public func canHandle(fileAt url: URL) async -> Bool {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return false }
        defer { try? handle.close() }
        let head = (try? handle.read(upToCount: 4096)) ?? Data()
        let text = MhtArchive.latin1(head).lowercased()
        return text.contains("multipart/related") || text.contains("multipart/mixed")
    }

    public func entries(in archive: URL) -> AsyncThrowingStream<ArchiveEntryHeader, Error> {
        AsyncThrowingStream { continuation in
            do {
                let modified = (try? FileManager.default.attributesOfItem(
                    atPath: archive.path)[.modificationDate]) as? Date
                for part in try MhtArchive.parse(try Data(contentsOf: archive)) {
                    continuation.yield(ArchiveEntryHeader(
                        path: part.path,
                        size: Int64(part.body.count),
                        modified: modified,
                        method: part.contentType))
                }
                continuation.finish()
            } catch {
                continuation.finish(throwing: Self.mapped(error, archive: archive))
            }
        }
    }

    public func extract(
        _ entry: ArchiveEntryHeader, from archive: URL, to destination: URL,
        services: any PluginHostServices
    ) async throws {
        let parts = try MhtArchive.parse(try Data(contentsOf: archive))
        guard let part = parts.first(where: { $0.path == entry.path }) else {
            throw PluginError.notFound(entry.path)
        }
        guard await services.report(PluginProgress(
            source: entry.path, destination: destination.path,
            bytesTransferred: Int64(part.body.count),
            totalBytes: Int64(part.body.count), percent: 100)) else {
            throw PluginError.cancelled
        }
        do {
            try part.body.write(to: destination)
        } catch {
            throw PluginError.failed(error.localizedDescription)
        }
    }

    public func pack(
        _ files: [PackerInputFile], into archive: URL, options: PackerOptions,
        services: any PluginHostServices
    ) async throws {
        var parts: [MhtArchive.Part] = []
        for (index, file) in files.enumerated() {
            // Progress before each file, and the answer is the only way the
            // user can stop a long pack.
            guard await services.report(PluginProgress(
                source: file.pathInArchive,
                destination: archive.lastPathComponent,
                percent: index * 100 / max(files.count, 1))) else {
                throw PluginError.cancelled
            }
            guard let body = try? Data(contentsOf: file.source) else {
                throw PluginError.notFound(file.source.path)
            }
            let name = options.savePaths
                ? file.pathInArchive
                : (file.pathInArchive as NSString).lastPathComponent
            parts.append(MhtArchive.Part(
                path: name,
                contentType: MhtArchive.contentType(forFileNamed: name),
                body: body))
        }
        let document = MhtArchive.build(parts, boundary: MhtArchive.makeBoundary())
        do {
            try document.write(to: archive, options: .atomic)
        } catch {
            throw PluginError.failed(error.localizedDescription)
        }
        await services.log(PluginLogEvent(
            kind: .operationComplete,
            message: "\(files.count) file(s) -> \(archive.lastPathComponent)")) // l10n:exempt: log line
    }

    private static func mapped(_ error: Error, archive: URL) -> PluginError {
        switch error {
        case MhtArchive.Failure.notMultipart:
            return .failed("\(archive.lastPathComponent) is not an MHTML document") // l10n:exempt: diagnostic
        case MhtArchive.Failure.noBoundary:
            return .failed("\(archive.lastPathComponent) has no MIME boundary") // l10n:exempt: diagnostic
        default:
            return .failed(error.localizedDescription)
        }
    }
}
