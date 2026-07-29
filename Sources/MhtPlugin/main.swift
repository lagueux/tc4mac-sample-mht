import Foundation
import TCPluginSDK

/// The plugin process: reads length-prefixed JSON requests on standard input
/// and answers on standard output. Everything format-specific lives in
/// `MhtPackerPlugin`; this is the shell every tc4mac plugin looks like.
struct Runner {
    private let plugin = MhtPackerPlugin()
    private let services = HostServices()
    private let input = FileHandle.standardInput
    private let output = FileHandle.standardOutput
    private var buffer = Data()

    /// The host answers progress and prompts; a plugin never opens UI. This
    /// process cannot call back yet, so it reports nothing and is never
    /// cancelled — the full duplex channel is the host's next step.
    struct HostServices: PluginHostServices {
        func report(_ progress: PluginProgress) async -> Bool { true }
        func log(_ event: PluginLogEvent) async {}
        func request(_ prompt: PluginPrompt) async -> String? { nil }
        func secret(_ operation: PluginSecretOperation) async throws -> String? { nil }
    }

    mutating func run() async {
        while let frame = nextFrame() {
            guard let request = try? JSONDecoder().decode(PluginWire.Request.self, from: frame)
            else { continue }
            await handle(request)
        }
    }

    private mutating func nextFrame() -> Data? {
        guard let header = read(4), let length = try? PluginWire.frameLength(header) else {
            return nil
        }
        return read(length)
    }

    private mutating func read(_ count: Int) -> Data? {
        while buffer.count < count {
            let chunk = input.availableData
            if chunk.isEmpty { return nil }
            buffer.append(chunk)
        }
        defer { buffer.removeFirst(count) }
        return Data(buffer.prefix(count))
    }

    private func handle(_ request: PluginWire.Request) async {
        do {
            switch request.method {
            case PluginWire.Method.hello:
                try reply(request.id, PluginWire.Hello(
                    id: "com.tc4mac.sample.mht",
                    displayName: "MHTML archives (sample)",
                    packerCapabilities: plugin.capabilities.rawValue,
                    packerExtensions: plugin.extensions))

            case PluginWire.Method.archiveEntries:
                let path: PluginPayload.Path = try decode(request)
                var entries: [PluginPayload.ArchiveEntry] = []
                for try await header in plugin.entries(in: URL(filePath: path.path)) {
                    entries.append(PluginPayload.ArchiveEntry(
                        path: header.path, isDirectory: header.isDirectory,
                        size: header.size, modified: header.modified,
                        method: header.method))
                }
                try reply(request.id, PluginPayload.ArchiveEntries(entries: entries))

            case PluginWire.Method.archiveExtract:
                let job: PluginPayload.Extract = try decode(request)
                try await plugin.extract(
                    ArchiveEntryHeader(path: job.entry),
                    from: URL(filePath: job.archive),
                    to: URL(filePath: job.destination),
                    services: services)
                try replyEmpty(request.id)

            case PluginWire.Method.archivePack:
                let job: PluginPayload.Pack = try decode(request)
                try await plugin.pack(
                    job.files.map {
                        PackerInputFile(
                            source: URL(filePath: $0.source), pathInArchive: $0.pathInArchive)
                    },
                    into: URL(filePath: job.archive),
                    options: PackerOptions(
                        savePaths: job.savePaths, compressionLevel: job.compressionLevel),
                    services: services)
                try replyEmpty(request.id)

            default:
                try fail(request.id, .notSupported(request.method))
            }
        } catch let error as PluginError {
            try? fail(request.id, error)
        } catch {
            try? fail(request.id, .failed("\(error)"))
        }
    }

    private func decode<T: Decodable>(_ request: PluginWire.Request) throws -> T {
        try JSONDecoder().decode(T.self, from: request.payload)
    }

    private func reply<T: Encodable>(_ id: Int, _ value: T) throws {
        try send(PluginWire.Response(id: id, payload: try JSONEncoder().encode(value)))
    }

    private func replyEmpty(_ id: Int) throws {
        try send(PluginWire.Response(id: id))
    }

    private func fail(_ id: Int, _ error: PluginError) throws {
        try send(PluginWire.Response(id: id, error: PluginWire.ErrorPayload(error)))
    }

    private func send(_ response: PluginWire.Response) throws {
        try output.write(contentsOf: PluginWire.frame(try JSONEncoder().encode(response)))
    }
}

// A top-level `var` is actor-isolated, which a mutating async call cannot
// touch; running it inside a task keeps the entry point simple.
await Task {
    var runner = Runner()
    await runner.run()
}.value
