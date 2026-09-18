import Foundation

/// JSON / YAML の構造比較。**`LineDiff` を配列にも使い回す** ―― 要素ごとに正準化した
/// バイト列をハッシュにして渡せば、行の増減で鍛えた同じアルゴリズム（共通の先頭・末尾を
/// 落とす、アンカーで挟む）がそのまま「途中に 1 個挿した」を「全部ずれた」と誤読せずに拾う。
///
/// **キーの並び替えは差分に出さない。**`StructuredValue.object` が `[String: _]` である
/// 時点で並びは捨ててある。README が挙げていた穴（「キーの並びだけ違う」）はここで閉じる。

// MARK: - 結果

public struct StructuredChange: Equatable {
    public enum Kind: String, Equatable, Sendable { case added, removed, changed }
    public let path: String   // ルート直下の変化は "" になりうる（表示側で "(root)" に読み替える）
    public let kind: Kind
    /// その場所に A 側にあった値。`added` には無い（nil）。
    public let before: StructuredValue?
    /// その場所に B 側にあった値。`removed` には無い（nil）。
    public let after: StructuredValue?
    public init(path: String, kind: Kind, before: StructuredValue? = nil, after: StructuredValue? = nil) {
        self.path = path
        self.kind = kind
        self.before = before
        self.after = after
    }
}

public struct StructuredDiff {
    public let changes: [StructuredChange]
    public init(changes: [StructuredChange]) { self.changes = changes }

    public var isIdentical: Bool { changes.isEmpty }
    public var changed: Int { changes.reduce(0) { $0 + ($1.kind == .changed ? 1 : 0) } }
    public var added: Int { changes.reduce(0) { $0 + ($1.kind == .added ? 1 : 0) } }
    public var removed: Int { changes.reduce(0) { $0 + ($1.kind == .removed ? 1 : 0) } }
}

// MARK: - 比較

public func compareStructured(_ a: StructuredValue, _ b: StructuredValue) -> StructuredDiff {
    var changes: [StructuredChange] = []
    diffValues(a, b, path: "", into: &changes)
    return StructuredDiff(changes: changes)
}

private func diffValues(_ a: StructuredValue, _ b: StructuredValue, path: String, into changes: inout [StructuredChange]) {
    if a == b { return }
    switch (a, b) {
    case let (.object(oa), .object(ob)):
        for key in oa.keys.sorted() where ob[key] == nil {
            changes.append(StructuredChange(path: appendKey(path, key), kind: .removed, before: oa[key]))
        }
        for key in ob.keys.sorted() where oa[key] == nil {
            changes.append(StructuredChange(path: appendKey(path, key), kind: .added, after: ob[key]))
        }
        for key in oa.keys.sorted() where ob[key] != nil {
            diffValues(oa[key]!, ob[key]!, path: appendKey(path, key), into: &changes)
        }
    case let (.array(aa), .array(ab)):
        diffArrays(aa, ab, path: path, into: &changes)
    default:
        // 種類そのものが変わった（object → array、string → number、…）。
        // 中を掘っても意味が無いので、その場所 1 件の "changed" とだけ言う。
        changes.append(StructuredChange(path: path, kind: .changed, before: a, after: b))
    }
}

/// 配列は**位置に意味がある**ので、行 diff と同じ「並びを保ったまま挿し引きを探す」を当てる。
private func diffArrays(_ a: [StructuredValue], _ b: [StructuredValue], path: String, into changes: inout [StructuredChange]) {
    let ha = a.map(canonicalHash)
    let hb = b.map(canonicalHash)
    for op in LineDiff.compute(ha, hb) {
        switch op {
        case .equal:
            continue
        case let .delete(left, count):
            for i in 0..<count { changes.append(StructuredChange(path: appendIndex(path, left + i), kind: .removed, before: a[left + i])) }
        case let .insert(right, count):
            for i in 0..<count { changes.append(StructuredChange(path: appendIndex(path, right + i), kind: .added, after: b[right + i])) }
        case let .replace(left, leftCount, right, rightCount):
            // **`changed` は左右の多いほう**（`TextDiff.changed` と同じ定義 ―― README で
            // 一度揃えた数え方を、種類が増えたからと崩さない）。共通する頭からペアで再帰し、
            // 余った側を増減として言う。
            let common = min(leftCount, rightCount)
            for i in 0..<common {
                diffValues(a[left + i], b[right + i], path: appendIndex(path, right + i), into: &changes)
            }
            if leftCount > rightCount {
                for i in common..<leftCount { changes.append(StructuredChange(path: appendIndex(path, left + i), kind: .removed, before: a[left + i])) }
            } else if rightCount > leftCount {
                for i in common..<rightCount { changes.append(StructuredChange(path: appendIndex(path, right + i), kind: .added, after: b[right + i])) }
            }
        }
    }
}

/// module 内どこからでも呼べるようにしてある ── `StructuredValue.prettyPrintWithPaths` が
/// 同じ組み方でパスを作る（`StructuredChange.path` と文字列で突き合わせられるようにするため）。
func appendKey(_ path: String, _ key: String) -> String {
    path.isEmpty ? key : "\(path).\(key)"
}

func appendIndex(_ path: String, _ index: Int) -> String {
    "\(path)[\(index)]"
}

// MARK: - 配列の要素を「行」として扱うための正準化ハッシュ

/// 値 1 つを決定的なバイト列にしてから `hashBytes`（`TextDiff.swift`、行のハッシュと同じ
/// 関数）へ渡す。オブジェクトはキーをソートしてから詰める ―― 並び替えを「違う要素」と
/// 読ませないため（`diffValues` がキーの並びを見ないのと同じ理由）。
private func canonicalHash(_ v: StructuredValue) -> LineHash {
    var buf: [UInt8] = []
    buf.reserveCapacity(32)
    appendCanonical(v, to: &buf)
    return buf.withUnsafeBufferPointer { hashBytes($0.baseAddress!, buf.count) }
}

private func appendCanonical(_ v: StructuredValue, to buf: inout [UInt8]) {
    switch v {
    case .null:
        buf.append(0)
    case .bool(let b):
        buf.append(b ? 2 : 1)
    case .number(let n):
        buf.append(3)
        withUnsafeBytes(of: n.bitPattern) { buf.append(contentsOf: $0) }
    case .string(let s):
        buf.append(4)
        appendLengthPrefixed(Array(s.utf8), to: &buf)
    case .array(let items):
        buf.append(5)
        appendUInt32(UInt32(items.count), to: &buf)
        for item in items { appendCanonical(item, to: &buf) }
    case .object(let entries):
        buf.append(6)
        let keys = entries.keys.sorted()
        appendUInt32(UInt32(keys.count), to: &buf)
        for key in keys {
            appendLengthPrefixed(Array(key.utf8), to: &buf)
            appendCanonical(entries[key]!, to: &buf)
        }
    }
}

private func appendUInt32(_ n: UInt32, to buf: inout [UInt8]) {
    withUnsafeBytes(of: n) { buf.append(contentsOf: $0) }
}

private func appendLengthPrefixed(_ bytes: [UInt8], to buf: inout [UInt8]) {
    appendUInt32(UInt32(bytes.count), to: &buf)
    buf.append(contentsOf: bytes)
}
