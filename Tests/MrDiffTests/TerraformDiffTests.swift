import XCTest
@testable import MrDiffCore

/// Terraform の state / plan の比較。**秘密の値が、どの出力にも出ないこと**が、いちばん大事な約束。
final class TerraformDiffTests: XCTestCase {

    private func state(_ resources: String, outputs: String = "{}") -> Data {
        Data("""
        {"version":4,"terraform_version":"1.8.0","serial":1,"lineage":"x","outputs":\(outputs),"resources":[\(resources)]}
        """.utf8)
    }

    private func db(password: String, cls: String = "db.t3.micro", extra: String = "") -> String {
        """
        {"mode":"managed","type":"aws_db_instance","name":"main","provider":"p","instances":[{"attributes":{"id":"db-1","instance_class":"\(cls)","password":"\(password)"\(extra)},"sensitive_attributes":[[{"type":"get_attr","value":"password"}]]}]}
        """
    }

    private func doc(_ d: Data) throws -> TerraformDocument { try XCTUnwrap(parseTerraform(d)) }

    /// 出力（人向け・JSON）を全部まとめて、秘密が 1 文字も入っていないことを確かめるための文字列。
    private func everything(_ d: TerraformDiff) -> String {
        var s = JSONOutput.encode(JSONOutput.terraform(d))
        for r in d.rows { for c in r.changes { s += " \(c.path) \(String(describing: c.before)) \(String(describing: c.after))" } }
        return s
    }

    // MARK: - 判定

    func testRecognisesStatePlanAndNothingElse() throws {
        XCTAssertEqual(try doc(state(db(password: "a"))).kind, .state)
        let plan = Data(#"{"format_version":"1.2","terraform_version":"1.8.0","resource_changes":[]}"#.utf8)
        XCTAssertEqual(try doc(plan).kind, .plan)
        XCTAssertNil(parseTerraform(Data(#"{"user":"x","password":"visible"}"#.utf8)), "普通の JSON は Terraform ではない")
        XCTAssertNil(parseTerraform(Data(#"{"version":4,"resources":[]}"#.utf8)), "terraform_version が無ければ候補にしない")
        XCTAssertNil(parseTerraform(Data("plain text".utf8)))
        XCTAssertNil(parseTerraform(Data()))
    }

    func testAddressesIncludeModuleDataAndIndex() throws {
        let d = state("""
        {"module":"module.app","mode":"managed","type":"aws_instance","name":"web","instances":[{"index_key":0,"attributes":{}},{"index_key":"blue","attributes":{}}]},
        {"mode":"data","type":"aws_ami","name":"base","instances":[{"attributes":{}}]}
        """)
        let keys = try doc(d).resources.keys.sorted()
        XCTAssertEqual(Set(keys), ["data.aws_ami.base", "module.app.aws_instance.web[0]", "module.app.aws_instance.web[\"blue\"]"])
    }

    // MARK: - 秘密を伏せる

    func testSensitiveMarkIsHiddenAndTheRestIsShown() throws {
        let a = try doc(state(db(password: "FAKE-old-111")))
        let b = try doc(state(db(password: "FAKE-new-222", cls: "db.t3.small")))
        let d = compareTerraform(a, b)
        XCTAssertEqual(d.changed, 1)
        XCTAssertEqual(d.hiddenCount, 1)
        let row = try XCTUnwrap(d.rows.first)
        let pw = try XCTUnwrap(row.changes.first { $0.path == "password" })
        XCTAssertTrue(pw.sensitive); XCTAssertNil(pw.before); XCTAssertNil(pw.after)
        let cls = try XCTUnwrap(row.changes.first { $0.path == "instance_class" })
        XCTAssertFalse(cls.sensitive)
        XCTAssertEqual(cls.before, .string("db.t3.micro"))
        XCTAssertFalse(everything(d).contains("FAKE"), "秘密がどこかに出ている")
    }

    /// 印が無くても、名前で伏せる（古い state、印の付け忘れ）。ただし `key_name` や `kms_key_id` は秘密ではない。
    func testKeyNameHeuristicCatchesUnmarkedSecretsButNotKeyNames() throws {
        XCTAssertTrue(looksSecretByName("api_token"))
        XCTAssertTrue(looksSecretByName("settings.DB_PASSWORD"))
        XCTAssertTrue(looksSecretByName("private_key"))
        XCTAssertTrue(looksSecretByName("creds[0].secret_value"))
        XCTAssertFalse(looksSecretByName("key_name"))
        XCTAssertFalse(looksSecretByName("kms_key_id"))
        XCTAssertFalse(looksSecretByName("instance_class"))
        XCTAssertFalse(looksSecretByName(""))
        let a = try doc(state(db(password: "x", extra: #","api_token":"FAKE-t-1""#)))
        let b = try doc(state(db(password: "x", extra: #","api_token":"FAKE-t-2""#)))
        let d = compareTerraform(a, b)
        XCTAssertEqual(d.hiddenCount, 1)
        XCTAssertFalse(everything(d).contains("FAKE"))
    }

    /// かたまり（オブジェクト）の単位で変化が来ても、中の秘密を出さない。
    func testSecretsInsideAWholeObjectAreRedacted() throws {
        let plan = { (after: String) in Data("""
        {"format_version":"1.2","terraform_version":"1.8.0","resource_changes":[{"address":"aws_db_instance.main","type":"aws_db_instance",
        "change":{"actions":["create"],"before":null,"after":\(after),"after_sensitive":{"password":true}}}]}
        """.utf8) }
        let a = try doc(plan("null"))
        let b = try doc(plan(#"{"name":"main","password":"FAKE-deep-9","tags":{"api_key":"FAKE-key-7","env":"prod"}}"#))
        let d = compareTerraform(a, b)
        XCTAssertGreaterThanOrEqual(d.hiddenCount, 2)
        XCTAssertFalse(everything(d).contains("FAKE"))
        XCTAssertTrue(everything(d).contains("prod"), "秘密でない値までは伏せない")
    }

    func testSensitiveOutputsAreHidden() throws {
        let a = try doc(state("", outputs: #"{"url":{"value":"postgres://FAKE-1","type":"string","sensitive":true},"region":{"value":"a","type":"string"}}"#))
        let b = try doc(state("", outputs: #"{"url":{"value":"postgres://FAKE-2","type":"string","sensitive":true},"region":{"value":"b","type":"string"}}"#))
        let d = compareTerraform(a, b)
        XCTAssertEqual(d.changed, 2)
        XCTAssertFalse(everything(d).contains("FAKE"))
        XCTAssertTrue(everything(d).contains("\"a\"") || everything(d).contains("string(\"a\")") || everything(d).contains("a"))
    }

    func testShowSecretsRevealsThem() throws {
        let a = try doc(state(db(password: "FAKE-old-111")))
        let b = try doc(state(db(password: "FAKE-new-222")))
        let d = compareTerraform(a, b, showSecrets: true)
        XCTAssertEqual(d.hiddenCount, 0)
        XCTAssertTrue(everything(d).contains("FAKE-new-222"))
    }

    /// `terraform show -json` の state の形も Terraform と判定し、秘密を伏せる（これを見落とすと、普通の JSON として
    /// 比べられ、平文のパスワードが出る）。子モジュールの資源も拾う。
    func testShowJSONStateFormIsRecognisedAndMasked() throws {
        func shown(_ pw: String, cls: String) -> Data { Data("""
        {"format_version":"1.0","terraform_version":"1.8.0","values":{"outputs":{"u":{"sensitive":true,"value":"FAKE-out-\(pw)"}},
        "root_module":{"resources":[{"address":"aws_db_instance.main","type":"aws_db_instance","values":{"instance_class":"\(cls)","password":"\(pw)"},"sensitive_values":{"password":true}}],
        "child_modules":[{"address":"module.app","resources":[{"address":"module.app.aws_instance.web","type":"aws_instance","values":{"ami":"a","user_token":"FAKE-tok-\(pw)"},"sensitive_values":{}}]}]}}}
        """.utf8) }
        let a = try doc(shown("FAKE-1", cls: "db.t3.micro")), b = try doc(shown("FAKE-2", cls: "db.t3.small"))
        XCTAssertEqual(a.kind, .state)
        XCTAssertEqual(Set(a.resources.keys), ["aws_db_instance.main", "module.app.aws_instance.web", "output.u"])
        let d = compareTerraform(a, b)
        XCTAssertEqual(d.changed, 3)
        XCTAssertFalse(everything(d).contains("FAKE"))
        XCTAssertTrue(everything(d).contains("db.t3.small"))
    }

    // MARK: - 資源の単位

    func testAddedAndRemovedResourcesCarryNoAttributes() throws {
        let a = try doc(state(db(password: "FAKE-a")))
        let b = try doc(state(#"{"mode":"managed","type":"aws_s3_bucket","name":"logs","instances":[{"attributes":{"id":"logs","password":"FAKE-b"}}]}"#))
        let d = compareTerraform(a, b)
        XCTAssertEqual(d.added, 1); XCTAssertEqual(d.removed, 1); XCTAssertEqual(d.changed, 0)
        XCTAssertTrue(d.rows.allSatisfy { $0.changes.isEmpty }, "丸ごと足された・消えた資源の属性は出さない")
        XCTAssertEqual(d.destroyedInB, ["aws_db_instance.main"])
        XCTAssertFalse(everything(d).contains("FAKE"))
    }

    func testIdenticalStatesAreIdentical() throws {
        let a = try doc(state(db(password: "same")))
        XCTAssertTrue(compareTerraform(a, a).isIdentical)
    }

    func testPlanDestroysAreListedPerSide() throws {
        func plan(_ actions: String) -> Data { Data("""
        {"format_version":"1.2","terraform_version":"1.8.0","resource_changes":[{"address":"aws_instance.web","type":"aws_instance",
        "change":{"actions":\(actions),"before":{"ami":"a"},"after":null}}]}
        """.utf8) }
        let d = compareTerraform(try doc(plan(#"["update"]"#)), try doc(plan(#"["delete"]"#)))
        XCTAssertEqual(d.plannedDestroysA, [])
        XCTAssertEqual(d.plannedDestroysB, ["aws_instance.web"])
        XCTAssertEqual(d.changed, 1, "動作が違うだけでも、変わったと言う")
    }

    // MARK: - JSON

    func testJSONCarriesSensitiveFlagInsteadOfValues() throws {
        let a = try doc(state(db(password: "FAKE-old-111")))
        let b = try doc(state(db(password: "FAKE-new-222")))
        let o = JSONOutput.terraform(compareTerraform(a, b))
        XCTAssertEqual(o["kind"] as? String, "terraform-state")
        XCTAssertEqual(o["hidden_sensitive"] as? Int, 1)
        let rows = try XCTUnwrap(o["resources"] as? [[String: Any]])
        let changes = try XCTUnwrap(rows[0]["changes"] as? [[String: Any]])
        let pw = try XCTUnwrap(changes.first { $0["path"] as? String == "password" })
        XCTAssertEqual(pw["sensitive"] as? Bool, true)
        XCTAssertNil(pw["before"]); XCTAssertNil(pw["after"])
    }
}
