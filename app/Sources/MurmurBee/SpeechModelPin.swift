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

    /// The offline speaker model behind meeting transcripts: pyannote community-1 from FluidInference's
    /// speaker-diarization-coreml, as used for M01–M09.
    static let diarizerSHA256: [String: String] = [
        "Embedding.mlmodelc/analytics/coremldata.bin": "8d6706436639b53830b4dbe8aaf9c9a843f7f582d63e16f3cb8bb7c6ccd58682",
        "Embedding.mlmodelc/coremldata.bin": "4a705bac27d151d9642f37609296042a15602a42253039e0921dc9e75da7e004",
        "Embedding.mlmodelc/metadata.json": "1854371eb6b438fb8aeac96afb45c999af7902581c06afdfcd7ff3cb1ce66be5",
        "Embedding.mlmodelc/model.mil": "22fa958aef72a561c21f874a07cbdcd30fdf40ee961c0bc2fb67c119273b46d3",
        "Embedding.mlmodelc/weights/weight.bin": "99356b2985b8d43880a657024d941d450b38820451ccff903f76ed4e52d1868b",
        "FBank.mlmodelc/analytics/coremldata.bin": "0e8bd3a8b82ac123580989f490e4d9245127c535857630b543311268accc3f0a",
        "FBank.mlmodelc/coremldata.bin": "57ac436bb0671cbb5527a339134d695f752eb77f7a18966b93c6835335595759",
        "FBank.mlmodelc/metadata.json": "2623785f5d186893b82d01e84aa33a7704ef763c3309e02055f22dc9d871ce9a",
        "FBank.mlmodelc/model.mil": "27aaeb21569e81bdbe2eef87789f50a37cfea800039bd134448a9417de2f30ed",
        "FBank.mlmodelc/weights/weight.bin": "9e83fdd3ea78064b078069e4d9141603c61c47a27fd19e7e3142ff7476f8db36",
        "PldaRho.mlmodelc/analytics/coremldata.bin": "8940ea6044dbcbefa22da8cc41e0b485e1fb5ed89aecaf37c6e0c483a97ddcd7",
        "PldaRho.mlmodelc/coremldata.bin": "4d9741477f721c79b09fcdfe455110c4b7d4272e2de3496bf1729d966d3ee418",
        "PldaRho.mlmodelc/metadata.json": "b314cf25a93e46b4076883a6f5a2f8848b73c3851bd9d36074d067f35a1c7945",
        "PldaRho.mlmodelc/model.mil": "83aee2e5310d19b5f202aea97d07a0e12102556d1b32ef3ed08b36f7f9725041",
        "PldaRho.mlmodelc/weights/weight.bin": "80f7d229202636d372428c90596f11a91545f07da77259f07153aaf225914a36",
        "Segmentation.mlmodelc/analytics/coremldata.bin": "64265f8e7ad41a5f68d630c15288c2499cca5892ad49e20096819cdeac004cdb",
        "Segmentation.mlmodelc/coremldata.bin": "ea51481b8bd3e496ad3cf16f066ddaa37f20e8772eaac76b3393c28de20e06bc",
        "Segmentation.mlmodelc/metadata.json": "88dbf0b07208fe142e1729c2b4c974ad3599fcb2ae5d5f18fce782b225384124",
        "Segmentation.mlmodelc/model.mil": "d37e4ce30b406a6b34f765f769b9baed3178cc0c2b2e299c641daa43a052dd3f",
        "Segmentation.mlmodelc/weights/weight.bin": "c3189a64946c75bc24fcb98afe89ad78c52bdbadfdf65e857fb1b81e2cc9fbb2",
        "config.json": "44136fa355b3678a1146ad16f7e8649e94fb4fc21fe77e8310c060f61caaff8a",
        "plda-parameters.json": "38ee28d4269c076cef254ee760bbd811f0738a92e0f01f9699ad372828c5de8f",
        "provenance.json": "0353430db062715c411ba32e66cb435b9caee2662bccdb298f9e5d1bae760872",
        "xvector-transform.json": "f7cd5cc16e63e2d89db052a23018ecfc47a311998ed1e9e39838fbac65048688",
    ]

    enum PinError: LocalizedError {
        case mismatch(String)
        var errorDescription: String? {
            if case .mismatch(let file) = self { return "a speech model failed its integrity check (\(file))" }
            return nil
        }
    }

    /// Throws unless every pinned file exists with the right hash and no unexpected file sits inside a model bundle.
    static func verify(_ dir: URL, pins: [String: String] = sha256) throws {
        for (path, expected) in pins {
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
                guard pins[rel] != nil else { throw PinError.mismatch(rel) }
            }
        }
    }
}
