import XCTest
@testable import MrDiffCore
@testable import MrDiffPostgres

final class PostgresErrorLocalizationTests: XCTestCase {
    func testDescriptionsFollowTheSelectedLanguage() {
        Lang.select("ja")
        defer { Lang.select("en") }

        XCTAssertEqual(
            PostgresDiffError.invalidConnection("理由").description,
            "PostgreSQL の接続 URL が正しくありません: 理由"
        )
        XCTAssertEqual(
            PostgresDiffError.invalidConfiguration("理由").description,
            "テーブル設定が正しくありません: 理由"
        )
        XCTAssertEqual(
            PostgresDiffError.queryFailed("理由").description,
            "PostgreSQL の比較に失敗しました: 理由"
        )
        XCTAssertEqual(
            PostgresDiffError.rowLimitExceeded("public.items").description,
            "テーブル public.items は比較上限の10,000行を超えています"
        )
    }
}
