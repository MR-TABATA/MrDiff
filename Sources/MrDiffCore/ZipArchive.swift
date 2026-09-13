import Foundation
import Compression

/// zip を**中身の一覧として**読む。展開はしない（要るときだけ、その 1 つを起こす）。
///
/// docx / xlsx / pptx / EPUB / Sketch / XD / jar ―― 拡張子は違っても中は zip で、
/// 「中のどのファイルが変わったか」はフォルダ比較（`TreeDiff`）そのもの。ここは
/// その入口で、**パス → 指紋**を central directory から拾うだけ。指紋は zip が
/// 持っている CRC-32 と長さ ―― 展開せずに済み、同じ中身は同じ指紋になる。
///
/// 依存を足さない。zip の骨組みは 30 年変わっておらず、central directory を読むのは
/// 100 行で足りる。展開は Apple の Compression（zip の method 8 ＝ 生の DEFLATE を
/// そのまま解く）。暗号化・zip64・それ以外の圧縮法は**読めるが起こせない**
/// （一覧と指紋は取れる。`extract` は nil を返す）。
public struct ZipArchive {

    public struct Entry: Equatable, Sendable {
        public let path: String
        /// CRC-32 と展開後の長さ。**中身の指紋**として使う（`TreeDiff` の hash）。
        public let crc32: UInt32
        public let size: Int
        let compressedSize: Int
        let method: UInt16
        let localHeaderOffset: Int

        public var fingerprint: String { String(format: "%08x:%d", crc32, size) }
    }

    public let entries: [Entry]
    private let data: Data

    /// 中身が zip か。**拡張子は見ない。**先頭の local header か、空の zip の
    /// end-of-central-directory で決める。
    public static func looksLikeZip(_ data: Data) -> Bool {
        guard data.count >= 4 else { return false }
        let sig = data.prefix(4)
        return sig == Data([0x50, 0x4B, 0x03, 0x04]) || sig == Data([0x50, 0x4B, 0x05, 0x06])
    }

    /// central directory を読む。zip でなければ nil。
    public init?(data: Data) {
        // 添字は 0 始まりで扱う（スライスが来ても）。
        let data = data.startIndex == 0 ? data : Data(data)
        guard ZipArchive.looksLikeZip(data), let eocd = ZipArchive.findEOCD(data) else { return nil }
        self.data = data
        let count = Int(data.u16(eocd + 10))
        let cdSize = Int(data.u32(eocd + 12))
        let cdOffset = Int(data.u32(eocd + 16))
        guard cdOffset + cdSize <= data.count else { return nil }

        var entries: [Entry] = []
        entries.reserveCapacity(count)
        var p = cdOffset
        for _ in 0..<count {
            guard p + 46 <= data.count, data.u32(p) == 0x0201_4B50 else { return nil }
            let method = data.u16(p + 10)
            let crc = data.u32(p + 16)
            let csize = Int(data.u32(p + 20))
            let usize = Int(data.u32(p + 24))
            let nameLen = Int(data.u16(p + 28))
            let extraLen = Int(data.u16(p + 30))
            let commentLen = Int(data.u16(p + 32))
            let local = Int(data.u32(p + 42))
            guard p + 46 + nameLen <= data.count else { return nil }
            let name = String(decoding: data[(p + 46)..<(p + 46 + nameLen)], as: UTF8.self)
            // ディレクトリの項目（末尾 /）は一覧に要らない。フォルダ比較もファイルしか見ない。
            if !name.hasSuffix("/") {
                entries.append(Entry(path: name, crc32: crc, size: usize,
                                     compressedSize: csize, method: method, localHeaderOffset: local))
            }
            p += 46 + nameLen + extraLen + commentLen
        }
        self.entries = entries
    }

    /// パス → 指紋。`TreeDiff.compare` にそのまま渡す形。
    public var fingerprints: [String: String] {
        var out: [String: String] = [:]
        for e in entries { out[e.path] = e.fingerprint }
        return out
    }

    /// 1 つだけ起こす。無い・起こせない（暗号化、未対応の圧縮法）なら nil。
    public func extract(_ path: String) -> Data? {
        guard let e = entries.first(where: { $0.path == path }) else { return nil }
        let h = e.localHeaderOffset
        guard h + 30 <= data.count, data.u32(h) == 0x0403_4B50 else { return nil }
        let flags = data.u16(h + 6)
        if flags & 0x1 != 0 { return nil }   // 暗号化
        let nameLen = Int(data.u16(h + 26)), extraLen = Int(data.u16(h + 28))
        let start = h + 30 + nameLen + extraLen
        guard start + e.compressedSize <= data.count else { return nil }
        let raw = data[start..<(start + e.compressedSize)]
        switch e.method {
        case 0:
            return Data(raw)
        case 8:
            return ZipArchive.inflate(Data(raw), size: e.size)
        default:
            return nil
        }
    }

    // MARK: - 内側

    /// end-of-central-directory は末尾から探す（コメントが付いていることがある）。
    private static func findEOCD(_ data: Data) -> Int? {
        let minEnd = max(0, data.count - 22 - 65_535)
        var p = data.count - 22
        while p >= minEnd {
            if data.u32(p) == 0x0605_4B50 { return p }
            p -= 1
        }
        return nil
    }

    /// 生の DEFLATE を解く。Compression の ZLIB は zlib ヘッダ無しの DEFLATE そのもの
    /// ―― zip の method 8 と同じ。
    private static func inflate(_ src: Data, size: Int) -> Data? {
        guard size > 0 else { return Data() }
        var dst = [UInt8](repeating: 0, count: size)
        let n = src.withUnsafeBytes { s -> Int in
            dst.withUnsafeMutableBytes { d -> Int in
                compression_decode_buffer(d.baseAddress!.assumingMemoryBound(to: UInt8.self), size,
                                          s.baseAddress!.assumingMemoryBound(to: UInt8.self), src.count,
                                          nil, COMPRESSION_ZLIB)
            }
        }
        guard n == size else { return nil }
        return Data(dst)
    }
}

private extension Data {
    func u16(_ at: Int) -> UInt16 {
        let i = startIndex + at
        return UInt16(self[i]) | UInt16(self[i + 1]) << 8
    }
    func u32(_ at: Int) -> UInt32 {
        let i = startIndex + at
        return UInt32(self[i]) | UInt32(self[i + 1]) << 8 | UInt32(self[i + 2]) << 16 | UInt32(self[i + 3]) << 24
    }
}
