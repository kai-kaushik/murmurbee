import CryptoKit
import Foundation

/// The speech model's files, pinned: Parakeet Ultra from FluidInference/parakeet-ultra-coreml at commit 95eaa59,
/// cross-checked against Hugging Face's published hashes. Nothing is loaded unless every file matches, so a changed
/// or substituted upstream model can't reach the app.
enum SpeechModelPin {
    static let sha256: [String: String] = [
        "Decoder.mlmodelc/analytics/coremldata.bin": "fe92b6cfaa012abd5248c0bc877832f19807015abffc60d87b8ccc8ccb48b3b5",
        "Decoder.mlmodelc/coremldata.bin": "3b06e66768f0df7e21795f50e2b29300e33eeb1a2579dc42c695279c2d308497",
        "Decoder.mlmodelc/model.mil": "956f600207f88396017ca5c96cfa3acd5bfee60835a5b44b762e033a8fb28955",
        "Decoder.mlmodelc/weights/weight.bin": "02a0d219f281b9665bc10c8768649403b2eebbbf4b44c627041d948e0de11bb4",
        "Encoder.mlmodelc/analytics/coremldata.bin": "d87101d824d6723cf95304da33755c3c60e762663b9ef2b0c4bd0aa166a09a0d",
        "Encoder.mlmodelc/coremldata.bin": "397a84a4062f563cbc5f56077c674f09a61d85be5090f61d2f1932afb92ac0fe",
        "Encoder.mlmodelc/model.mil": "f5d601568a4171d99a314c0fe3f6bc67715da2623732a3fb566e050ea83e5848",
        "Encoder.mlmodelc/weights/weight.bin": "315ba01f33cadbf601d43ac7f5c86208b7aa75fdaa34705c9869d5abe3521c9b",
        "JointDecisionv3.mlmodelc/analytics/coremldata.bin": "68d38ca646aebafa7a9329e2efda50f5767c49e89fdb5f77f212072bb66f97c4",
        "JointDecisionv3.mlmodelc/coremldata.bin": "5e3af5a4ce686f6c237cadbd9284e10d333bc0e1546633cd0e430e6194044bc4",
        "JointDecisionv3.mlmodelc/model.mil": "791b3c3cf3eb2079c84623fc880f6bba008d1366e5f8b03e9a8ed8bd4d7194a0",
        "JointDecisionv3.mlmodelc/weights/weight.bin": "3f310b85b82341c53ec383025ab094a4e462ee1c592e1ad7c6bfe39cff66ca25",
        "Preprocessor.mlmodelc/analytics/coremldata.bin": "c9beeb989c8d66f8be11df59bc6df277ec76cee404f6865b46243835ef562f6d",
        "Preprocessor.mlmodelc/coremldata.bin": "dbde3f2300842c1fd51ef3ff948a0bcffe65ffd2dca10707f2509f32c1d65b1d",
        "Preprocessor.mlmodelc/metadata.json": "2a98699e22d279dd37fa1d238aeb1c6db1df0d6fad687775324157689d8f3acf",
        "Preprocessor.mlmodelc/model.mil": "4b8518a956450fec57f06c2a21bdffc26973f7f1fa6842fb38fe917f896b6b93",
        "Preprocessor.mlmodelc/weights/weight.bin": "129b76e3aeafa8afa3ea76d995b964b145fe83700d579f6ff42c4c38fa0968ea",
        "config.json": "965c69bf500c7be18958df6438dc1ba897721690ae412937ca7c91e28cec1870",
        "parakeet_v3_vocab.json": "7ec60e05f1b24480736ec0eed40900f4626bce1fa9a60fd700ec7e2a59198735",
        "parakeet_vocab.json": "7ec60e05f1b24480736ec0eed40900f4626bce1fa9a60fd700ec7e2a59198735",
    ]

    enum PinError: LocalizedError {
        case mismatch(String)
        var errorDescription: String? {
            if case .mismatch(let file) = self { return "the speech model failed its integrity check (\(file))" }
            return nil
        }
    }

    /// Throws unless every pinned file exists with the right hash and no unexpected file sits inside a model bundle.
    static func verify(_ dir: URL) throws {
        for (path, expected) in sha256 {
            let url = dir.appendingPathComponent(path)
            guard let handle = try? FileHandle(forReadingFrom: url) else { throw PinError.mismatch(path) }
            defer { try? handle.close() }
            var hasher = SHA256()
            while let chunk = try handle.read(upToCount: 4 << 20), !chunk.isEmpty { hasher.update(data: chunk) }
            let hex = hasher.finalize().map { String(format: "%02x", $0) }.joined()
            guard hex == expected else { throw PinError.mismatch(path) }
        }
        let fm = FileManager.default
        if let walker = fm.enumerator(at: dir, includingPropertiesForKeys: [.isRegularFileKey]) {
            for case let url as URL in walker where url.path.contains(".mlmodelc/") {
                guard (try? url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true else { continue }
                let rel = String(url.path.dropFirst(dir.path.count + 1))
                guard sha256[rel] != nil else { throw PinError.mismatch(rel) }
            }
        }
    }
}
