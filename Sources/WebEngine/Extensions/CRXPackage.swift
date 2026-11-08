import CryptoKit
import Foundation
import Security

// CRX3 signature verification (protobuf walk, SignedData layout, RSA SPKI
// unwrapping, publisher-key check) is adapted from DuckDuckGo's
// ChromeWebStorePackageVerifier.swift (github.com/duckduckgo/apple-browsers,
// SharedPackages/WebExtensions), Copyright © DuckDuckGo, Apache License 2.0.
// See Chromium components/crx_file/crx3.proto and crx_verifier.cc.

public enum CRXError: Error, Equatable, Sendable {
    case badMagic
    case unsupportedVersion(UInt32)
    case truncated
    case malformedHeader
    case missingPayload
    case idMismatch(expected: String, actual: String?)
    case invalidSignature
    case missingDeveloperSignature
    case missingPublisherSignature
}

/// A parsed `.crx` file: the ZIP payload plus what the header says about who signed it.
///
/// `parse` validates structure only (magic, version, lengths, protobuf
/// framing, that the payload is a ZIP). `verify(expectedID:requirePublisherProof:)`
/// checks signatures: for CRX3 every proof must verify over the signed data, the
/// developer key must hash to the CRX ID, and (by default) the Chrome Web Store
/// publisher key must have co-signed. For CRX2 it checks the single RSA-SHA1
/// signature over the ZIP and that the key hashes to the expected ID.
public struct CRXPackage: Sendable {
    public enum Format: Sendable, Equatable { case crx2, crx3 }

    struct Proof: Sendable { let publicKey: Data; let signature: Data; let isRSA: Bool }

    public let format: Format
    /// The ZIP archive that follows the header.
    public let zip: Data
    /// The extension ID the header claims (CRX3 signed header, or the CRX2 key hash).
    public let declaredID: String?
    let signedHeader: Data
    let proofs: [Proof]

    static let magic = Data("Cr24".utf8)
    static let maxHeaderSize = 1 << 20

    /// SHA-256 of the Chrome Web Store publisher key (Chromium's `kPublisherKeyHash`).
    static let publisherKeyHash = Data([
        0x61, 0xf7, 0xf2, 0xa6, 0xbf, 0xcf, 0x74, 0xcd, 0x0b, 0xc1, 0xfe,
        0x24, 0x97, 0xcc, 0x9b, 0x04, 0x25, 0x4c, 0x65, 0x8f, 0x79, 0xf2,
        0x14, 0x53, 0x92, 0x86, 0x7e, 0xa8, 0x36, 0x63, 0x67, 0xcf,
    ])

    public static func parse(_ data: Data) throws -> CRXPackage {
        let data = Data(data) // rebase indices to 0
        guard data.count >= 12 else { throw CRXError.truncated }
        guard data.prefix(4) == magic else { throw CRXError.badMagic }
        let version = data.u32(at: 4)
        switch version {
        case 3:
            let headerSize = Int(data.u32(at: 8))
            guard headerSize <= maxHeaderSize, headerSize <= data.count - 12 else { throw CRXError.truncated }
            let header = data.subdata(in: 12..<(12 + headerSize))
            let fields = try Protobuf.fields(header)
            var proofs: [Proof] = []
            for (field, isRSA) in [(2, true), (3, false)] {
                for proof in fields[field] ?? [] {
                    let parts = try Protobuf.fields(proof)
                    guard let key = parts[1]?.only, let sig = parts[2]?.only else { throw CRXError.malformedHeader }
                    proofs.append(Proof(publicKey: key, signature: sig, isRSA: isRSA))
                }
            }
            let signed = fields[10000]?.only ?? Data()
            var declared: String?
            if !signed.isEmpty, let crxID = try Protobuf.fields(signed)[1]?.only {
                guard crxID.count == 16 else { throw CRXError.malformedHeader }
                declared = ChromeExtensionID.from(idBytes: crxID)
            }
            let zip = data.subdata(in: (12 + headerSize)..<data.count)
            try checkZIP(zip)
            return CRXPackage(format: .crx3, zip: zip, declaredID: declared, signedHeader: signed, proofs: proofs)
        case 2:
            guard data.count >= 16 else { throw CRXError.truncated }
            let keyLen = Int(data.u32(at: 8)), sigLen = Int(data.u32(at: 12))
            guard keyLen > 0, keyLen <= maxHeaderSize, sigLen <= maxHeaderSize,
                  16 + keyLen + sigLen <= data.count else { throw CRXError.truncated }
            let key = data.subdata(in: 16..<(16 + keyLen))
            let sig = data.subdata(in: (16 + keyLen)..<(16 + keyLen + sigLen))
            let zip = data.subdata(in: (16 + keyLen + sigLen)..<data.count)
            try checkZIP(zip)
            return CRXPackage(format: .crx2, zip: zip, declaredID: ChromeExtensionID.from(publicKey: key),
                              signedHeader: Data(), proofs: [Proof(publicKey: key, signature: sig, isRSA: true)])
        default:
            throw CRXError.unsupportedVersion(version)
        }
    }

    /// Verifies signatures and that the package belongs to `expectedID`.
    public func verify(expectedID: String, requirePublisherProof: Bool = true) throws {
        guard declaredID == expectedID else { throw CRXError.idMismatch(expected: expectedID, actual: declaredID) }
        switch format {
        case .crx2:
            guard let proof = proofs.first,
                  try Self.verifyRSA(proof.signature, spki: proof.publicKey, data: zip, algorithm: .rsaSignatureMessagePKCS1v15SHA1)
            else { throw CRXError.invalidSignature }
        case .crx3:
            var signedData = Data("CRX3 SignedData\0".utf8)
            let size = UInt32(signedHeader.count)
            signedData.append(contentsOf: (0..<4).map { UInt8(truncatingIfNeeded: size >> ($0 * 8)) })
            signedData.append(signedHeader)
            signedData.append(zip)
            var developer = false, publisher = false
            for proof in proofs {
                let ok = proof.isRSA
                    ? try Self.verifyRSA(proof.signature, spki: proof.publicKey, data: signedData, algorithm: .rsaSignatureMessagePKCS1v15SHA256)
                    : try Self.verifyECDSA(proof.signature, der: proof.publicKey, data: signedData)
                guard ok else { throw CRXError.invalidSignature }
                let hash = Data(SHA256.hash(data: proof.publicKey))
                if ChromeExtensionID.from(idBytes: hash.prefix(16)) == expectedID { developer = true }
                if hash == Self.publisherKeyHash { publisher = true }
            }
            guard developer else { throw CRXError.missingDeveloperSignature }
            if requirePublisherProof, !publisher { throw CRXError.missingPublisherSignature }
        }
    }

    /// A ZIP payload starts with a local file header (or is an empty archive).
    static func checkZIP(_ zip: Data) throws {
        guard zip.count >= 22 else { throw CRXError.missingPayload }
        let sig = zip.u32(at: 0)
        guard sig == 0x0403_4b50 || sig == 0x0605_4b50 else { throw CRXError.missingPayload }
    }

    private static func verifyECDSA(_ signature: Data, der: Data, data: Data) throws -> Bool {
        guard let key = try? P256.Signing.PublicKey(derRepresentation: der),
              let sig = try? P256.Signing.ECDSASignature(derRepresentation: signature) else { throw CRXError.invalidSignature }
        return key.isValidSignature(sig, for: data)
    }

    private static func verifyRSA(_ signature: Data, spki: Data, data: Data, algorithm: SecKeyAlgorithm) throws -> Bool {
        let pkcs1 = try rsaKey(fromSPKI: spki)
        let attrs: [CFString: Any] = [kSecAttrKeyType: kSecAttrKeyTypeRSA, kSecAttrKeyClass: kSecAttrKeyClassPublic]
        guard let key = SecKeyCreateWithData(pkcs1 as CFData, attrs as CFDictionary, nil) else { throw CRXError.invalidSignature }
        return SecKeyVerifySignature(key, algorithm, data as CFData, signature as CFData, nil)
    }

    /// Security wants the PKCS#1 RSAPublicKey inside the X.509 SubjectPublicKeyInfo.
    static func rsaKey(fromSPKI spki: Data) throws -> Data {
        var cursor = 0
        func element(_ tag: UInt8, in data: Data) throws -> Data {
            guard cursor + 2 <= data.count, data[cursor] == tag else { throw CRXError.invalidSignature }
            cursor += 1
            var size = Int(data[cursor]); cursor += 1
            if size & 0x80 != 0 {
                let n = size & 0x7f
                guard (1...4).contains(n), cursor + n <= data.count else { throw CRXError.invalidSignature }
                size = 0
                for _ in 0..<n { size = (size << 8) | Int(data[cursor]); cursor += 1 }
            }
            guard size <= data.count - cursor else { throw CRXError.invalidSignature }
            defer { cursor += size }
            return data.subdata(in: cursor..<(cursor + size))
        }
        let spki = Data(spki)
        let seq = try element(0x30, in: spki)
        cursor = 0
        let algorithm = try element(0x30, in: seq)
        guard algorithm == Data([0x06, 0x09, 0x2a, 0x86, 0x48, 0x86, 0xf7, 0x0d, 0x01, 0x01, 0x01, 0x05, 0x00]) else {
            throw CRXError.invalidSignature
        }
        let bits = try element(0x03, in: seq)
        guard bits.first == 0 else { throw CRXError.invalidSignature }
        return bits.dropFirst()
    }
}

/// Chrome extension IDs: 32 chars in a–p, the hex of the first 16 bytes of
/// SHA-256(public key) with 0–f mapped to a–p.
public enum ChromeExtensionID {
    public static func isValid(_ id: String) -> Bool {
        id.utf8.count == 32 && id.utf8.allSatisfy { (97...112).contains($0) }
    }

    public static func from(idBytes: some Collection<UInt8>) -> String {
        String(decoding: idBytes.flatMap { [97 + ($0 >> 4), 97 + ($0 & 15)] }, as: UTF8.self)
    }

    public static func from(publicKey: Data) -> String {
        from(idBytes: Data(SHA256.hash(data: publicKey)).prefix(16))
    }

    /// The ID from a store page: `https://chromewebstore.google.com/detail/<slug>/<id>`,
    /// `.../detail/<id>`, or legacy `https://chrome.google.com/webstore/detail/<slug>/<id>`.
    public static func fromWebStoreURL(_ url: URL) -> String? {
        guard url.scheme == "https" || url.scheme == "http", let host = url.host()?.lowercased() else { return nil }
        let parts = url.pathComponents.filter { $0 != "/" }
        let detail: ArraySlice<String>
        switch host {
        case "chromewebstore.google.com":
            guard parts.first == "detail" else { return nil }
            detail = parts.dropFirst()
        case "chrome.google.com":
            guard parts.count >= 2, parts[0] == "webstore", parts[1] == "detail" else { return nil }
            detail = parts.dropFirst(2)
        default:
            return nil
        }
        // The ID is the first path component after "detail" that looks like one
        // (slug first in the usual form; some links put the ID first).
        return detail.prefix(2).reversed().first(where: isValid)
    }

    /// Strings too: accepts a bare ID or any store URL.
    public static func fromWebStoreURL(_ string: String) -> String? {
        if isValid(string) { return string }
        return URL(string: string).flatMap { fromWebStoreURL($0) }
    }
}

// MARK: - Helpers

enum Protobuf {
    /// Length-delimited fields only; scalar fields are skipped.
    static func fields(_ input: Data) throws -> [Int: [Data]] {
        let data = Data(input)
        var cursor = 0
        func varint() throws -> UInt64 {
            var value: UInt64 = 0
            for shift in stride(from: 0, to: 70, by: 7) {
                guard cursor < data.count else { throw CRXError.malformedHeader }
                let byte = data[cursor]; cursor += 1
                guard shift < 63 || byte <= 1 else { throw CRXError.malformedHeader }
                value |= UInt64(byte & 0x7f) << shift
                if byte & 0x80 == 0 { return value }
            }
            throw CRXError.malformedHeader
        }
        var out: [Int: [Data]] = [:]
        while cursor < data.count {
            let tag = try varint()
            let field = tag >> 3
            guard field > 0, field <= 536_870_911 else { throw CRXError.malformedHeader }
            switch tag & 7 {
            case 0: _ = try varint()
            case 1, 5:
                let n = tag & 7 == 1 ? 8 : 4
                guard n <= data.count - cursor else { throw CRXError.malformedHeader }
                cursor += n
            case 2:
                let n = try varint()
                guard n <= UInt64(data.count - cursor) else { throw CRXError.malformedHeader }
                out[Int(field), default: []].append(data.subdata(in: cursor..<(cursor + Int(n))))
                cursor += Int(n)
            default: throw CRXError.malformedHeader
            }
        }
        return out
    }
}

extension Data {
    func u32(at offset: Int) -> UInt32 {
        (0..<4).reduce(0) { $0 | UInt32(self[startIndex + offset + $1]) << ($1 * 8) }
    }
    func u16(at offset: Int) -> UInt16 {
        UInt16(self[startIndex + offset]) | UInt16(self[startIndex + offset + 1]) << 8
    }
}

private extension Array {
    var only: Element? { count == 1 ? first : nil }
}
