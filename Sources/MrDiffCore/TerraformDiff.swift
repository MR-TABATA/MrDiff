import Foundation

/// Terraform の state（`.tfstate`）と plan（`terraform show -json plan` の JSON）の比較。
///
/// ## なぜ別の経路か
///
/// tfstate は JSON なので、これを足す前から、JSON の構造比較に乗って**パスワードが旧・新ともそのまま
/// 画面に出ていた**（実測）。state には DB のパスワード・秘密鍵・トークンが平文で入る。CI のログや
/// 画面共有に出てよい値ではない。そこで、**Terraform の state / plan と判定できたときだけ**、
///
///   1. 資源の単位（`aws_db_instance.main`）で、足された・消えた・変わったを言い、
///   2. 秘密の値は**値を出さず「変わった」とだけ言う**
///
/// 経路に乗せる。普通の JSON はこれまでどおり（キー名で伏せると、ただの `password` という名前の項目まで
/// 伏せてしまうため、判定できたときだけに限る ―― 2026-10-06 決定）。
///
/// ## 何を秘密とするか（案 A）
///
///   - **Terraform 自身の印**: state の `sensitive_attributes`、plan の `before_sensitive` / `after_sensitive`、
///     output の `sensitive`。
///   - **キー名**: 印が付いていなくても漏れうる（古い state、provider が印を付け忘れたもの）ので、
///     名前に `password` / `secret` / `token` / `private_key` などを含むものも伏せる。
///   - 資源まるごと足された・消えたときは、属性を**1 つも出さない**（名前と種類だけ）。
///   - 見たいときだけ `--show-secrets`。
public enum TerraformKind: String {
    case state = "terraform-state"
    case plan = "terraform-plan"
}

/// 1 つの資源（state なら 1 インスタンス、plan なら 1 つの `resource_changes`）。
public struct TFResource {
    public let address: String
    public let type: String
    /// 比べる中身。state は `attributes`、plan は `after`（消すだけなら `before`）。
    public let attributes: StructuredValue
    /// 秘密と印の付いたパス（`attributes` の根からの相対。`StructuredChange.path` と同じ組み方）。
    public let sensitive: Set<String>
    /// plan のとき: `["delete"]`、`["delete","create"]`（置き換え）など。state は nil。
    public let actions: [String]?

    public var destroys: Bool { actions?.contains("delete") ?? false }
}

public struct TerraformDocument {
    public let kind: TerraformKind
    public let resources: [String: TFResource]
}

// MARK: - 読む

/// Terraform の state / plan なら読む。**違えば nil**（普通の JSON は、これまでの経路へ）。
/// 先に安いほうの確認（Terraform 以外のファイルで、全体を JSON として読まない）。
public func parseTerraform(_ data: Data) -> TerraformDocument? {
    // 最初の空白でない 1 バイトが `{` で、`terraform_version` を含むものだけが候補。
    guard let first = data.first(where: { $0 != 0x20 && $0 != 0x0A && $0 != 0x0D && $0 != 0x09 }),
          first == UInt8(ascii: "{"),
          data.range(of: Data("\"terraform_version\"".utf8)) != nil,
          let (value, _) = parseStructured(data),
          case .object(let root) = value else { return nil }

    if case .number(let v)? = root["version"], v == 4 || v == 3, case .array(let rs)? = root["resources"] {
        return parseState(root: root, resources: rs)
    }
    if case .string? = root["format_version"], case .array(let rcs)? = root["resource_changes"] {
        return parsePlan(rcs)
    }
    // `terraform show -json` が出す state の形（`values.root_module`）。値は平文で、`sensitive_values` が印。
    if case .string? = root["format_version"], case .object(let values)? = root["values"] {
        return parseShownState(values)
    }
    return nil
}

/// `terraform show -json <state>` の形。`values.root_module.resources[]` と `child_modules[]`（入れ子）、
/// `values.outputs`。各資源は `address` / `type` / `values` / `sensitive_values`（値と同じ形で、秘密が `true`）。
private func parseShownState(_ values: [String: StructuredValue]) -> TerraformDocument {
    var out: [String: TFResource] = [:]
    func walk(_ module: StructuredValue?) {
        guard case .object(let m)? = module else { return }
        if case .array(let rs)? = m["resources"] {
            for r in rs {
                guard case .object(let o) = r, let address = str(o["address"]), let type = str(o["type"]) else { continue }
                out[address] = TFResource(address: address, type: type, attributes: o["values"] ?? .object([:]),
                                          sensitive: sensitivePaths(inTree: o["sensitive_values"] ?? .bool(false)), actions: nil)
            }
        }
        if case .array(let children)? = m["child_modules"] { for c in children { walk(c) } }
    }
    walk(values["root_module"])
    if case .object(let outputs)? = values["outputs"] {
        for (name, v) in outputs {
            guard case .object(let o) = v else { continue }
            var sens = Set<String>()
            if case .bool(true)? = o["sensitive"] { sens.insert("value") }
            out["output.\(name)"] = TFResource(address: "output.\(name)", type: "output",
                                                attributes: .object(["value": o["value"] ?? .null]), sensitive: sens, actions: nil)
        }
    }
    return TerraformDocument(kind: .state, resources: out)
}

private func str(_ v: StructuredValue?) -> String? {
    if case .string(let s)? = v { return s }
    return nil
}

private func parseState(root: [String: StructuredValue], resources: [StructuredValue]) -> TerraformDocument {
    var out: [String: TFResource] = [:]
    for r in resources {
        guard case .object(let o) = r, let type = str(o["type"]), let name = str(o["name"]),
              case .array(let instances)? = o["instances"] else { continue }
        let module = str(o["module"]).map { $0 + "." } ?? ""
        let data = str(o["mode"]) == "data" ? "data." : ""
        for inst in instances {
            guard case .object(let io) = inst else { continue }
            var address = "\(module)\(data)\(type).\(name)"
            switch io["index_key"] {
            case .number(let n)?: address += "[\(Int(n))]"
            case .string(let s)?: address += "[\"\(s)\"]"
            default: break
            }
            let attrs = io["attributes"] ?? .object([:])
            var sensitive = Set<String>()
            if case .array(let paths)? = io["sensitive_attributes"] {
                for p in paths { if let s = sensitivePath(from: p) { sensitive.insert(s) } }
            }
            out[address] = TFResource(address: address, type: type, attributes: attrs, sensitive: sensitive, actions: nil)
        }
    }
    // output。`sensitive: true` のものは `value` を伏せる。
    if case .object(let outputs)? = root["outputs"] {
        for (name, v) in outputs {
            guard case .object(let o) = v else { continue }
            let address = "output.\(name)"
            var sens = Set<String>()
            if case .bool(true)? = o["sensitive"] { sens.insert("value") }
            out[address] = TFResource(address: address, type: "output", attributes: .object(["value": o["value"] ?? .null]),
                                      sensitive: sens, actions: nil)
        }
    }
    return TerraformDocument(kind: .state, resources: out)
}

/// state の `sensitive_attributes` の 1 本（`[{"type":"get_attr","value":"password"}, {"type":"index",…}]`）を
/// `StructuredChange.path` と同じ組み方の文字列にする。読めなければ nil。
private func sensitivePath(from v: StructuredValue) -> String? {
    guard case .array(let steps) = v else { return nil }
    var path = ""
    for step in steps {
        guard case .object(let o) = step else { return nil }
        switch str(o["type"]) {
        case "get_attr"?:
            guard let name = str(o["value"]) else { return nil }
            path = appendKey(path, name)
        case "index"?:
            // 値は `{"value": <キー or 添字>, "type": "string"|"number"}`
            guard case .object(let iv)? = o["value"] else { return nil }
            switch iv["value"] {
            case .string(let k)?: path = appendKey(path, k)
            case .number(let n)?: path = appendIndex(path, Int(n))
            default: return nil
            }
        default: return nil
        }
    }
    return path.isEmpty ? nil : path
}

private func parsePlan(_ changes: [StructuredValue]) -> TerraformDocument {
    var out: [String: TFResource] = [:]
    for c in changes {
        guard case .object(let o) = c, let address = str(o["address"]), let type = str(o["type"]),
              case .object(let change)? = o["change"] else { continue }
        var actions: [String] = []
        if case .array(let a)? = change["actions"] { actions = a.compactMap { str($0) } }
        let destroysOnly = actions == ["delete"]
        let attrs = (destroysOnly ? change["before"] : change["after"]) ?? .object([:])
        let marks = (destroysOnly ? change["before_sensitive"] : change["after_sensitive"]) ?? .bool(false)
        out[address] = TFResource(address: address, type: type, attributes: attrs,
                                  sensitive: sensitivePaths(inTree: marks), actions: actions)
    }
    return TerraformDocument(kind: .plan, resources: out)
}

/// plan の `*_sensitive`（値と同じ形で、秘密の場所が `true`）から、パスの集合を作る。
func sensitivePaths(inTree v: StructuredValue, at path: String = "") -> Set<String> {
    switch v {
    case .bool(true): return path.isEmpty ? [] : [path]
    case .object(let o): return o.reduce(into: Set<String>()) { $0.formUnion(sensitivePaths(inTree: $1.value, at: appendKey(path, $1.key))) }
    case .array(let a): return a.enumerated().reduce(into: Set<String>()) { $0.formUnion(sensitivePaths(inTree: $1.element, at: appendIndex(path, $1.offset))) }
    default: return []
    }
}

// MARK: - 比べる

/// 値を出さない印（出力にはこの形で渡す）。
public struct TFChange {
    public let path: String
    public let kind: StructuredChange.Kind
    /// 秘密のとき nil（値を持たない）。`--show-secrets` なら値が入る。
    public let before: StructuredValue?
    public let after: StructuredValue?
    public let sensitive: Bool
}

public struct TFRow {
    public enum Status: String { case added, removed, changed }
    public let address: String
    public let type: String
    public let status: Status
    public let changes: [TFChange]
    /// plan のとき、A と B の actions（違いを言うため）。
    public let actionsA: [String]?
    public let actionsB: [String]?
}

public struct TerraformDiff {
    public let kind: TerraformKind
    public let rows: [TFRow]
    /// 伏せた値の数（人向けの注記に使う）。
    public let hiddenCount: Int
    /// 消えた資源（state: A にあって B に無い）、または plan で `delete` を含むもの（A / B それぞれ）。
    public let destroyedInB: [String]      // state: A にあり B に無い
    public let plannedDestroysA: [String]  // plan: A の plan が消すもの
    public let plannedDestroysB: [String]

    public var isIdentical: Bool { rows.isEmpty }
    public var changed: Int { rows.filter { $0.status == .changed }.count }
    public var added: Int { rows.filter { $0.status == .added }.count }
    public var removed: Int { rows.filter { $0.status == .removed }.count }
}

/// キー名による伏せ。**印が付いていなくても漏れうる**ので、名前に次を含むものを伏せる（大小無視）。
let secretKeyFragments = ["password", "passwd", "secret", "token", "private_key", "privatekey",
                          "access_key", "api_key", "apikey", "credential", "connection_string"]

func looksSecretByName(_ path: String) -> Bool {
    // 最後のキーだけを見る（`tags.token_count` のような、親の名前までは見ない）
    var last = path
    if let dot = path.lastIndex(of: ".") { last = String(path[path.index(after: dot)...]) }
    if let br = last.firstIndex(of: "[") { last = String(last[..<br]) }
    let lower = last.lowercased()
    return secretKeyFragments.contains { lower.contains($0) }
}

func isCovered(_ path: String, by sensitive: Set<String>) -> Bool {
    if sensitive.contains(path) { return true }
    // 印が付いたパスの下（`secret_map` の中の全部）も秘密
    for s in sensitive where path.hasPrefix(s + ".") || path.hasPrefix(s + "[") { return true }
    return false
}

/// 値の**中**にある秘密を伏せる。`(root): null → {…}` や、`tags` ごと足されたときのように、変化が
/// かたまり（オブジェクト・配列）の単位で来ると、中に入っている `password` がそのまま出てしまう。
/// 秘密のところは `"(sensitive)"` に置き換え、置き換えた数も返す。
func redact(_ v: StructuredValue, at path: String, sensitive: Set<String>) -> (StructuredValue, Int) {
    switch v {
    case .object(let o):
        var out: [String: StructuredValue] = [:]
        var n = 0
        for (k, child) in o {
            let childPath = appendKey(path, k)
            if isCovered(childPath, by: sensitive) || looksSecretByName(childPath) {
                out[k] = .string("(sensitive)"); n += 1
            } else {
                let (r, m) = redact(child, at: childPath, sensitive: sensitive)
                out[k] = r; n += m
            }
        }
        return (.object(out), n)
    case .array(let a):
        var out: [StructuredValue] = [], n = 0
        for (i, child) in a.enumerated() {
            let childPath = appendIndex(path, i)
            if isCovered(childPath, by: sensitive) {
                out.append(.string("(sensitive)")); n += 1
            } else {
                let (r, m) = redact(child, at: childPath, sensitive: sensitive)
                out.append(r); n += m
            }
        }
        return (.array(out), n)
    default:
        return (v, 0)
    }
}

public func compareTerraform(_ a: TerraformDocument, _ b: TerraformDocument, showSecrets: Bool = false) -> TerraformDiff {
    var rows: [TFRow] = []
    var hidden = 0
    for address in Set(a.resources.keys).union(b.resources.keys).sorted() {
        switch (a.resources[address], b.resources[address]) {
        case let (ra?, nil):
            rows.append(TFRow(address: address, type: ra.type, status: .removed, changes: [], actionsA: ra.actions, actionsB: nil))
        case let (nil, rb?):
            rows.append(TFRow(address: address, type: rb.type, status: .added, changes: [], actionsA: nil, actionsB: rb.actions))
        case let (ra?, rb?):
            let diff = compareStructured(ra.attributes, rb.attributes)
            let sens = ra.sensitive.union(rb.sensitive)
            var changes: [TFChange] = []
            for c in diff.changes {
                let secret = !showSecrets && (isCovered(c.path, by: sens) || looksSecretByName(c.path))
                if secret { hidden += 1 }
                var before = secret ? nil : c.before, after = secret ? nil : c.after
                // かたまりの中の秘密も伏せる（`--show-secrets` のときは、何も触らない）
                if !secret && !showSecrets {
                    if let b = before { let (r, n) = redact(b, at: c.path, sensitive: sens); before = r; hidden += n }
                    if let a = after { let (r, n) = redact(a, at: c.path, sensitive: sens); after = r; hidden += n }
                }
                changes.append(TFChange(path: c.path, kind: c.kind, before: before, after: after, sensitive: secret))
            }
            let actionsDiffer = a.kind == .plan && ra.actions != rb.actions
            if !changes.isEmpty || actionsDiffer {
                rows.append(TFRow(address: address, type: ra.type, status: .changed, changes: changes,
                                  actionsA: ra.actions, actionsB: rb.actions))
            }
        default: break
        }
    }
    let destroyedInB = a.kind == .state ? rows.filter { $0.status == .removed }.map(\.address) : []
    let pda = a.kind == .plan ? a.resources.values.filter(\.destroys).map(\.address).sorted() : []
    let pdb = a.kind == .plan ? b.resources.values.filter(\.destroys).map(\.address).sorted() : []
    return TerraformDiff(kind: a.kind, rows: rows, hiddenCount: hidden,
                         destroyedInB: destroyedInB, plannedDestroysA: pda, plannedDestroysB: pdb)
}

// MARK: - JSON

extension JSONOutput {
    /// Terraform の state / plan の比較。**秘密の値は、キーごと出さない**（`sensitive: true` だけ）。
    public static func terraform(_ d: TerraformDiff, redirects: [Redirect] = []) -> [String: Any] {
        var o: [String: Any] = ["kind": d.kind.rawValue]
        if d.isIdentical {
            o["result"] = "identical"
        } else {
            o["result"] = "differ"
            o["changed"] = d.changed
            o["added"] = d.added
            o["removed"] = d.removed
            o["hidden_sensitive"] = d.hiddenCount
            if d.kind == .state { o["destroyed"] = d.destroyedInB }
            else { o["planned_destroys"] = ["a": d.plannedDestroysA, "b": d.plannedDestroysB] }
            o["resources"] = d.rows.map { r -> [String: Any] in
                var row: [String: Any] = ["address": r.address, "type": r.type, "status": r.status.rawValue]
                if r.actionsA != nil || r.actionsB != nil {
                    row["actions"] = ["a": r.actionsA ?? [], "b": r.actionsB ?? []]
                }
                row["changes"] = r.changes.map { c -> [String: Any] in
                    var ch: [String: Any] = ["path": c.path, "status": c.kind.rawValue]
                    if c.sensitive { ch["sensitive"] = true }
                    else {
                        if let b = c.before { ch["before"] = toJSONObject(b) }
                        if let a = c.after { ch["after"] = toJSONObject(a) }
                    }
                    return ch
                }
                return row
            }
        }
        addRedirects(&o, redirects)
        return o
    }
}
