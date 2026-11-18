import CryptoKit
import Foundation

/// Cleanup models live in Application Support/MurmurBee/models/<name>/ (MLX weights + tokenizer + localflow.json).
/// localflow.json is {"prompt": "v3", "rank": 1}. The highest rank wins, so a personal model trained on this Mac
/// (rank 10+) takes over from the downloaded general model (rank 1).
enum ModelStore {
    struct Remote: Sendable {
        let name: String
        let url: URL
        let sha256: String
        /// A package bigger than GitHub's 2 GiB limit for release files is published in parts, `<url>.1`, `<url>.2`
        /// and so on, joined back together before the checksum (of the whole zip) is checked.
        var parts = 1

        var urls: [URL] {
            parts == 1 ? [url] : (1...parts).map { URL(string: url.absoluteString + ".\($0)")! }
        }
    }

    static var directory: URL { Store.directory.appendingPathComponent("models") }

    /// The general cleanup model, trained only on synthetic data, published as a GitHub release asset.
    /// The checksum is pinned here and always verified, so a swapped or tampered asset is rejected.
    static let generalSHA256 = "fb5b18f0563a3bd95e0bc4750675bbc5d96cdeda1dc7388d0086713c913b07df"  // models-v1 release asset
    static var general: Remote {
        var url = URL(string: "https://github.com/kai-kaushik/murmurbee/releases/download/models-v1/murmurbee-cleanup-v1.zip")!
        var sha = generalSHA256
        #if DEBUG
        // Debug builds only: `defaults write com.murmurbee.app modelURL <url>` (+ modelSHA256) to test another package.
        let d = UserDefaults.standard
        if let u = d.string(forKey: "modelURL").flatMap(URL.init(string:)), let h = d.string(forKey: "modelSHA256") {
            url = u; sha = h
        }
        #endif
        return Remote(name: "murmurbee-cleanup-v1", url: url, sha256: sha)
    }

    /// The meeting notes model lives in its own folder, so it can never be picked up as a cleanup model. To change
    /// it, publish a package and update this name, URL and checksum: nothing else in the app depends on which model it is.
    static var notesDirectory: URL { Store.directory.appendingPathComponent("notes-models") }

    /// Qwen3.5 4B (mlx-community/Qwen3.5-4B-4bit at 0e7ffd5, Apache 2.0, image encoder left out), packaged by
    /// scripts/meetings/package_notes_model.sh. Poodle 4B covered more on AMI (M09) but is licensed non-commercial only.
    static let notesSHA256 = "a0c4917cfc97614683ca55058b3f35acb2e586e45c5559ffe7ba0dd35cb67749"
    static var notes: Remote {
        var url = URL(string: "https://github.com/kai-kaushik/murmurbee/releases/download/models-v2/murmurbee-notes-v1.zip")!
        var sha = notesSHA256
        #if DEBUG
        let d = UserDefaults.standard
        if let u = d.string(forKey: "notesModelURL").flatMap(URL.init(string:)), let h = d.string(forKey: "notesModelSHA256") {
            url = u; sha = h
        }
        #endif
        return Remote(name: "murmurbee-notes-v1", url: url, sha256: sha, parts: 2)
    }

    /// A model taken file by file from Hugging Face at a fixed commit, every file checked against its SHA-256, so
    /// a changed or substituted upstream model is refused. For models too big to re-host as release files.
    struct PinnedRepo: Sendable {
        let name: String
        let repo: String
        let revision: String
        /// File name: (SHA-256, size in bytes).
        let files: [String: (String, Int64)]
        var bytes: Int64 { files.values.reduce(0) { $0 + $1.1 } }
    }

    /// The bigger notes model, Gemma 4 26B-A4B (4-bit MLX, Apache 2.0). It made the fewest mistakes on real calls
    /// (M06c, M11) but writes shorter notes (M09), and it peaked at 20 GB of memory on a 30-minute call, so it is only
    /// offered on Macs with 32 GB or more.
    static let accurateNotes = PinnedRepo(
        name: "gemma-4-26b-a4b-it-4bit", repo: "mlx-community/gemma-4-26b-a4b-it-4bit",
        revision: "0d77464eeb233a2da68ebf9d7dc4edaac7db956d",
        files: [
            "chat_template.jinja": ("36e3a42e5cf14cd0020e72d92e1fdd9970f59b82170e421f0cbe1bb42bead3f0", 17466),
            "config.json": ("419e13a27ec359654c1ce7dd06d1a87149fd07d0c8af9f770494185e62e1b2ba", 12180),
            "generation_config.json": ("d4226bbe3117d2d253ba4609720ba82c6c4ce4627a9a6ae05387c78983ac03de", 208),
            "model-00001-of-00003.safetensors": ("683f420ee09550b8027bf0335c4202e196b37eb520b60a4bcbe8690b9e388c07", 5320218487),
            "model-00002-of-00003.safetensors": ("feab2873c2976fb7ed666f8462549564a29409364388e0c8f6b015729d165e15", 5363328422),
            "model-00003-of-00003.safetensors": ("bc607486deb1de5bc7e459932fda5c776a4f816b368feaa661bab8cfbb47e567", 4657658867),
            "model.safetensors.index.json": ("bf198c9f5ea6462addca1966e5dd669c407537a876e82cf06db9084c5c850b13", 176940),
            "processor_config.json": ("de3e580aebdc98272d4c4547daffe6525fcbae18a83a0e0bcf0d7444d4ee6f37", 1316),
            "tokenizer.json": ("cc8d3a0ce36466ccc1278bf987df5f71db1719b9ca6b4118264f45cb627bfe0f", 32169626),
            "tokenizer_config.json": ("080d9e1aff284e2f6043889cd05367966f7c7b80e025fbc0b06745e218158656", 2740),
        ])

    static var canRunAccurateNotes: Bool { ProcessInfo.processInfo.physicalMemory >= 32 << 30 }

    /// The installed notes model of the size asked for, or nil if it isn't installed. The standard one is whichever
    /// other model ranks highest, so a model installed by hand for testing counts too.
    static func installedNotes(accurate: Bool) -> URL? {
        let fm = FileManager.default
        let hasConfig = { (dir: URL) in fm.fileExists(atPath: dir.appendingPathComponent("config.json").path) }
        if accurate {
            let dir = notesDirectory.appendingPathComponent(accurateNotes.name)
            return hasConfig(dir) ? dir : nil
        }
        guard let names = try? fm.contentsOfDirectory(atPath: notesDirectory.path) else { return nil }
        return names.filter { $0 != accurateNotes.name && !$0.hasPrefix(".") }.sorted()
            .map { notesDirectory.appendingPathComponent($0) }.filter(hasConfig)
            .max { rank(of: $0) < rank(of: $1) }
    }

    /// Downloads every file of `pinned` into `folder`, checking each one, then moves the finished model into place.
    static func download(_ pinned: PinnedRepo, into folder: URL,
                         progress: @escaping @Sendable (Double) -> Void) async throws -> URL {
        let fm = FileManager.default
        try fm.createDirectory(at: folder, withIntermediateDirectories: true)
        let staging = folder.appendingPathComponent(".staging-\(UUID().uuidString)")
        try fm.createDirectory(at: staging, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: staging) }
        var done: Int64 = 0
        let total = Double(pinned.bytes)
        for (file, (sha, size)) in pinned.files.sorted(by: { $0.key < $1.key }) {
            let url = URL(string: "https://huggingface.co/\(pinned.repo)/resolve/\(pinned.revision)/\(file)")!
            let before = done
            let fetched = try await Downloader { p in progress((Double(before) + p * Double(size)) / total) }.fetch(url)
            defer { try? fm.removeItem(at: fetched) }
            guard try sha256(of: fetched) == sha else { throw DownloadError.checksum }
            try fm.moveItem(at: fetched, to: staging.appendingPathComponent(file))
            done += size
        }
        let dest = folder.appendingPathComponent(pinned.name)
        try? fm.removeItem(at: dest)
        try fm.moveItem(at: staging, to: dest)
        return dest
    }

    /// The installed model with the highest rank, or nil if none is installed.
    static func best() -> URL? {
        let fm = FileManager.default
        guard let names = try? fm.contentsOfDirectory(atPath: directory.path) else { return nil }
        let candidates = names.sorted().compactMap { name -> (URL, Int)? in
            let dir = directory.appendingPathComponent(name)
            // A full model, or a personal adapter whose base model is installed.
            let full = fm.fileExists(atPath: dir.appendingPathComponent("config.json").path)
            let adapter = PersonalTrainer.baseName(of: dir).map {
                fm.fileExists(atPath: directory.appendingPathComponent($0).appendingPathComponent("config.json").path)
            } ?? false
            guard full || adapter else { return nil }
            return (dir, rank(of: dir))
        }
        return candidates.max { $0.1 < $1.1 }?.0
    }

    static func rank(of dir: URL) -> Int {
        guard let data = try? Data(contentsOf: dir.appendingPathComponent("localflow.json")),
              let cfg = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return 0 }
        return cfg["rank"] as? Int ?? 0
    }

    enum DownloadError: LocalizedError {
        case noChecksum, checksum, unzip, missing
        var errorDescription: String? {
            switch self {
            case .noChecksum: "no published checksum for this model yet"
            case .checksum: "the download was corrupted (checksum mismatch)"
            case .unzip: "the download couldn't be unpacked"
            case .missing: "the download didn't contain a model"
            }
        }
    }

    /// Downloads, verifies and unpacks `remote` into `folder` (the cleanup models unless told otherwise). `progress`
    /// gets 0…1.
    static func download(_ remote: Remote, into folder: URL? = nil,
                         progress: @escaping @Sendable (Double) -> Void) async throws -> URL {
        guard remote.sha256.count == 64 else { throw DownloadError.noChecksum }  // never install unverified code
        let fm = FileManager.default
        let directory = folder ?? Self.directory
        try fm.createDirectory(at: directory, withIntermediateDirectories: true)
        let zip = try await fetch(remote.urls, progress: progress)
        defer { try? fm.removeItem(at: zip) }

        if try sha256(of: zip) != remote.sha256.lowercased() { throw DownloadError.checksum }

        // Unpack next to the final location, then move into place so a half-written model is never picked up.
        let staging = directory.appendingPathComponent(".staging-\(UUID().uuidString)")
        defer { try? fm.removeItem(at: staging) }
        let ditto = Process()
        ditto.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
        ditto.arguments = ["-x", "-k", zip.path, staging.path]
        try ditto.run()
        ditto.waitUntilExit()
        guard ditto.terminationStatus == 0 else { throw DownloadError.unzip }

        // Accept a zip of the folder itself or of its contents.
        var root = staging
        if !fm.fileExists(atPath: root.appendingPathComponent("config.json").path),
           let inner = try? fm.contentsOfDirectory(atPath: staging.path).first(where: { !$0.hasPrefix(".") && !$0.hasPrefix("__") }) {
            root = staging.appendingPathComponent(inner)
        }
        guard fm.fileExists(atPath: root.appendingPathComponent("config.json").path) else { throw DownloadError.missing }

        // A model name is a single folder name, never a path (no "/" or "..").
        guard !remote.name.isEmpty, !remote.name.contains("/"), !remote.name.contains(".."),
              !remote.name.hasPrefix(".") else { throw URLError(.cannotCreateFile) }
        let dest = directory.appendingPathComponent(remote.name)
        try? fm.removeItem(at: dest)
        try fm.moveItem(at: root, to: dest)
        return dest
    }

    /// Downloads each part in turn and joins them into one file.
    private static func fetch(_ urls: [URL], progress: @escaping @Sendable (Double) -> Void) async throws -> URL {
        var joined: URL?
        var out: FileHandle?
        defer { try? out?.close() }
        for (i, url) in urls.enumerated() {
            let n = Double(urls.count)
            let part = try await Downloader { progress((Double(i) + $0) / n) }.fetch(url)
            guard joined != nil else { joined = part; continue }
            defer { try? FileManager.default.removeItem(at: part) }
            if out == nil {
                out = try FileHandle(forWritingTo: joined!)
                try out!.seekToEnd()
            }
            let input = try FileHandle(forReadingFrom: part)
            defer { try? input.close() }
            while let chunk = try input.read(upToCount: 16 << 20), !chunk.isEmpty { try out!.write(contentsOf: chunk) }
        }
        return joined!
    }

    static func sha256(of file: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: file)
        defer { try? handle.close() }
        var hasher = SHA256()
        while let chunk = try handle.read(upToCount: 4 << 20), !chunk.isEmpty { hasher.update(data: chunk) }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }
}

/// One file download with progress, kept to a temporary file we own.
private final class Downloader: NSObject, URLSessionDownloadDelegate, @unchecked Sendable {
    private let progress: @Sendable (Double) -> Void
    private var continuation: CheckedContinuation<URL, Error>?
    private var lastReported = -1.0

    init(progress: @escaping @Sendable (Double) -> Void) { self.progress = progress }

    func fetch(_ url: URL) async throws -> URL {
        let session = URLSession(configuration: .default, delegate: self, delegateQueue: nil)
        defer { session.finishTasksAndInvalidate() }
        return try await withCheckedThrowingContinuation { c in
            continuation = c
            session.downloadTask(with: url).resume()
        }
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didWriteData bytesWritten: Int64,
                    totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64) {
        guard totalBytesExpectedToWrite > 0 else { return }
        let p = Double(totalBytesWritten) / Double(totalBytesExpectedToWrite)
        if p - lastReported >= 0.01 { lastReported = p; progress(p) }
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {
        if let http = downloadTask.response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            continuation?.resume(throwing: URLError(.badServerResponse, userInfo: [NSLocalizedDescriptionKey: "HTTP \(http.statusCode)"]))
            continuation = nil
            return
        }
        // The system deletes `location` when this returns, so move it somewhere we own first.
        let kept = FileManager.default.temporaryDirectory.appendingPathComponent("murmurbee-\(UUID().uuidString).zip")
        do {
            try FileManager.default.moveItem(at: location, to: kept)
            continuation?.resume(returning: kept)
        } catch {
            continuation?.resume(throwing: error)
        }
        continuation = nil
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        if let error { continuation?.resume(throwing: error); continuation = nil }
    }
}
