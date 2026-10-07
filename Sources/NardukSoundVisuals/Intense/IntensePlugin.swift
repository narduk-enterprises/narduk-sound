import Foundation

/// Why a plugin file is not a visualizer.
public enum IntensePluginError: Error, Equatable, Sendable {
    /// The file has no `// fragment:` line and no `fragment float4 name(` to default to.
    case noFragment
    case missingFunction(String)
    case unreadable(String)

    /// Text for a tile: the compiler's own message when there is one, trimmed to what fits on a card.
    static func describe(_ error: Error, fragment: String) -> String {
        var text: String
        switch error {
        case IntensePluginError.missingFunction(let name): text = "No fragment function named \(name) in this file."
        case IntensePluginError.noFragment: text = "No fragment function: add `// fragment: <name>` to the header."
        case IntensePluginError.unreadable(let why): text = "Cannot read the file: \(why)"
        default: text = (error as NSError).localizedDescription
        }
        text = text.replacingOccurrences(of: "program_source:", with: "line ")
        return text.count > 900 ? String(text.prefix(900)) + "…" : text
    }
}

/// What a plugin file says about itself in its comment header.
///
///     // title: Aurora
///     // fragment: auroraFragment
///
/// `title` defaults to the file name and `fragment` to the first `fragment float4 name(` in the file.
public struct IntensePluginHeader: Equatable, Sendable {
    public var title: String
    public var fragment: String

    public static func parse(source: String, fileName: String) throws -> IntensePluginHeader {
        var title: String?
        var fragment: String?
        for line in source.split(separator: "\n", omittingEmptySubsequences: false).prefix(40) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard trimmed.hasPrefix("//") else {
                if !trimmed.isEmpty { break }
                continue
            }
            let body = trimmed.dropFirst(2).trimmingCharacters(in: .whitespaces)
            if let value = Self.value(of: "title:", in: body) { title = value }
            if let value = Self.value(of: "fragment:", in: body) { fragment = value }
        }
        if fragment == nil { fragment = firstFragmentName(in: source) }
        guard let fragment, !fragment.isEmpty else { throw IntensePluginError.noFragment }
        let stem = (fileName as NSString).deletingPathExtension
        return IntensePluginHeader(title: (title?.isEmpty == false ? title : nil) ?? stem, fragment: fragment)
    }

    private static func value(of key: String, in body: String) -> String? {
        guard body.lowercased().hasPrefix(key) else { return nil }
        return body.dropFirst(key.count).trimmingCharacters(in: .whitespaces)
    }

    private static func firstFragmentName(in source: String) -> String? {
        guard
            let range = source.range(
                of: #"fragment\s+float4\s+([A-Za-z_][A-Za-z0-9_]*)\s*\("#, options: .regularExpression)
        else { return nil }
        let match = source[range]
        return match.split(whereSeparator: { $0 == " " || $0 == "\t" || $0 == "\n" }).dropFirst(2).first
            .map { String($0.prefix { $0 != "(" }) }
    }
}

/// One `.metal` file in the plugin folder: a tile when it compiled, an error tile when it did not.
public struct IntensePluginEntry: Identifiable, Sendable, Equatable {
    /// The file name.
    public let id: String
    public let title: String
    /// The kind to draw, nil when the file could not be read or has no usable header.
    public let kind: IntenseKind?
    /// The reason the file is not drawing, shown on its tile.
    public let error: String?
}

#if canImport(Metal)
    import Observation

    /// The folder of drop-in Metal visualizers (narduk-libs#1665) and what is in it. `reload()` reads every `.metal`
    /// file, compiles each into its own library (a broken one becomes an entry with an `error`, never a failure of
    /// the others) and publishes `entries`. `start()` creates the folder if need be and watches it: a save, an
    /// add or a delete reloads, so the running app updates with no rebuild and no relaunch.
    @MainActor @Observable
    public final class IntensePluginLibrary {
        /// `~/Library/Application Support/SoundGallery/Visualizers/` on macOS; the app's Documents folder on iOS
        /// (visible in Files, so a shader can be AirDropped to the phone).
        public static var defaultDirectory: URL {
            let manager = FileManager.default
            #if os(macOS)
                let base =
                    manager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
                    ?? manager.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support")
                return base.appendingPathComponent("SoundGallery/Visualizers", isDirectory: true)
            #else
                return manager.urls(for: .documentDirectory, in: .userDomainMask).first
                    ?? URL(fileURLWithPath: NSTemporaryDirectory())
            #endif
        }

        public let directory: URL
        public private(set) var entries: [IntensePluginEntry] = []
        /// Bumps on every reload that changed `entries`.
        public private(set) var revision = 0
        @ObservationIgnored private var watcher: IntensePluginFolderWatcher?
        @ObservationIgnored private let renderer: IntenseRenderer?

        public convenience init(directory: URL = IntensePluginLibrary.defaultDirectory) {
            self.init(directory: directory, renderer: IntenseRenderer.shared)
        }

        init(directory: URL, renderer: IntenseRenderer?) {
            self.directory = directory
            self.renderer = renderer
        }

        public func start() {
            guard watcher == nil else { return }
            try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            reload()
            watcher = IntensePluginFolderWatcher(directory: directory) { [weak self] in
                Task { @MainActor in self?.reload() }
            }
        }

        public func stop() {
            watcher?.cancel()
            watcher = nil
        }

        /// Reads and compiles the folder now.
        public func reload() {
            let files =
                ((try? FileManager.default.contentsOfDirectory(
                    at: directory, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles])) ?? [])
                .filter { $0.pathExtension.lowercased() == "metal" }
                .sorted { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }
            let loaded = files.map { entry(for: $0) }
            renderer?.retainPlugins(loaded.compactMap(\.kind))
            if loaded != entries {
                entries = loaded
                revision += 1
            }
        }

        private func entry(for url: URL) -> IntensePluginEntry {
            let name = url.lastPathComponent
            let stem = url.deletingPathExtension().lastPathComponent
            let source: String
            do { source = try String(contentsOf: url, encoding: .utf8) } catch {
                return IntensePluginEntry(
                    id: name, title: stem, kind: nil,
                    error: IntensePluginError.describe(
                        IntensePluginError.unreadable(error.localizedDescription), fragment: ""))
            }
            let header: IntensePluginHeader
            do { header = try IntensePluginHeader.parse(source: source, fileName: name) } catch {
                return IntensePluginEntry(
                    id: name, title: stem, kind: nil, error: IntensePluginError.describe(error, fragment: ""))
            }
            let kind = IntenseKind.plugin(id: name, title: header.title, fragment: header.fragment, source: source)
            guard let renderer else {
                return IntensePluginEntry(id: name, title: header.title, kind: kind, error: "Metal is not available.")
            }
            return IntensePluginEntry(id: name, title: header.title, kind: kind, error: renderer.prepare(kind))
        }
    }

    /// Watches a folder for changes: a directory source for adds, deletes and renames, and a one-second look at the
    /// files' modification dates for in-place saves (which do not touch the directory). Calls `onChange` on a
    /// background queue, once per change.
    final class IntensePluginFolderWatcher: @unchecked Sendable {
        private let directory: URL
        private let onChange: @Sendable () -> Void
        private let queue = DispatchQueue(label: "SoundGallery.plugin-watch", qos: .utility)
        private var source: (any DispatchSourceFileSystemObject)?
        private var timer: (any DispatchSourceTimer)?
        private var signature = ""

        init(directory: URL, onChange: @escaping @Sendable () -> Void) {
            self.directory = directory
            self.onChange = onChange
            signature = currentSignature()
            let descriptor = open(directory.path, O_EVTONLY)
            if descriptor >= 0 {
                let source = DispatchSource.makeFileSystemObjectSource(
                    fileDescriptor: descriptor, eventMask: [.write, .delete, .rename, .extend, .attrib], queue: queue)
                source.setEventHandler { [weak self] in self?.check() }
                source.setCancelHandler { close(descriptor) }
                source.resume()
                self.source = source
            }
            let timer = DispatchSource.makeTimerSource(queue: queue)
            timer.schedule(deadline: .now() + 1, repeating: 1)
            timer.setEventHandler { [weak self] in self?.check() }
            timer.resume()
            self.timer = timer
        }

        func cancel() {
            source?.cancel()
            timer?.cancel()
            source = nil
            timer = nil
        }

        private func check() {
            let now = currentSignature()
            guard now != signature else { return }
            signature = now
            onChange()
        }

        private func currentSignature() -> String {
            let keys: [URLResourceKey] = [.contentModificationDateKey, .fileSizeKey]
            let files =
                (try? FileManager.default.contentsOfDirectory(
                    at: directory, includingPropertiesForKeys: keys, options: [.skipsHiddenFiles])) ?? []
            return files.filter { $0.pathExtension.lowercased() == "metal" }.sorted { $0.path < $1.path }.map { url in
                let values = try? url.resourceValues(forKeys: Set(keys))
                return
                    "\(url.lastPathComponent):\(values?.contentModificationDate?.timeIntervalSince1970 ?? 0):\(values?.fileSize ?? 0)"
            }.joined(separator: "|")
        }
    }
#endif
