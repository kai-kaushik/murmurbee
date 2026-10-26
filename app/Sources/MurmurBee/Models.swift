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

    /// Downloads, verifies and unpacks `remote` into the models folder. `progress` gets 0…1.
    static func download(_ remote: Remote, progress: @escaping @Sendable (Double) -> Void) async throws -> URL {
        guard remote.sha256.count == 64 else { throw DownloadError.noChecksum }  // never install unverified code
        let fm = FileManager.default
        try fm.createDirectory(at: directory, withIntermediateDirectories: true)
        let zip = try await Downloader(progress: progress).fetch(remote.url)
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

        let dest = directory.appendingPathComponent(remote.name)
        try? fm.removeItem(at: dest)
        try fm.moveItem(at: root, to: dest)
        return dest
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
