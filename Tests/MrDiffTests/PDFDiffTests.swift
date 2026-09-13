import XCTest
import CoreGraphics
import CoreText
import PDFKit
@testable import MrDiffCore

/// PDF はここで作る（フィクスチャを置かない）。**CoreGraphics で描いた PDF を PDFKit で
/// 描き直して比べる**ので、同じ絵は 1 画素も違わないはず ―― それが最初のテスト。
///
/// 紙は A4（595 × 842 pt）。場所の答えは mm で返るので、pt → mm の換算も
/// ここで固定する（1 pt = 25.4 / 72 mm）。
final class PDFDiffTests: XCTestCase {

    private let a4 = CGRect(x: 0, y: 0, width: 595, height: 842)

    /// ページごとの描き手を渡して PDF を作る。座標は CoreGraphics（左下が原点）。
    private func pdf(pages: [(CGRect, (CGContext) -> Void)]) -> Data {
        let data = NSMutableData()
        let consumer = CGDataConsumer(data: data as CFMutableData)!
        var box = a4
        let ctx = CGContext(consumer: consumer, mediaBox: &box, nil)!
        for (rect, draw) in pages {
            var r = rect
            let info = [kCGPDFContextMediaBox as String: Data(bytes: &r, count: MemoryLayout<CGRect>.size)]
            ctx.beginPDFPage(info as CFDictionary)
            draw(ctx)
            ctx.endPDFPage()
        }
        ctx.closePDF()
        return data as Data
    }

    /// 黒い矩形を 1 つ描く。`y` は**紙の下から**（CoreGraphics の向き）。
    private func black(_ x: CGFloat, _ y: CGFloat, _ w: CGFloat, _ h: CGFloat) -> (CGContext) -> Void {
        return { ctx in
            ctx.setFillColor(CGColor(srgbRed: 0, green: 0, blue: 0, alpha: 1))
            ctx.fill(CGRect(x: x, y: y, width: w, height: h))
        }
    }

    private var one: (CGContext) -> Void { black(100, 700, 200, 20) }

    // MARK: - 見分け

    func test_PDFを見分ける() {
        XCTAssertTrue(looksLikePDF(pdf(pages: [(a4, one)])))
        XCTAssertFalse(looksLikePDF(Data("%PDF-1.4 but not really".utf8)), "頭だけでは足りない。開けること")
        XCTAssertFalse(looksLikePDF(Data("hello".utf8)))
    }

    func test_ImageIOも読んでしまうから先に聞く() {
        // ここが「1 ページ目だけの画像」に落ちていた理由。順番を変えたら気づけるように固定する。
        let d = pdf(pages: [(a4, one), (a4, one)])
        XCTAssertTrue(looksLikeImage(d), "ImageIO は PDF を画像として読む（この前提が変われば順番の理由も消える）")
        XCTAssertTrue(looksLikePDF(d))
    }

    // MARK: - 比較

    func test_同じ絵は1画素も違わない() throws {
        let a = pdf(pages: [(a4, one), (a4, black(50, 50, 10, 10))])
        let b = pdf(pages: [(a4, one), (a4, black(50, 50, 10, 10))])
        let d = try comparePDFs(a, b)
        XCTAssertEqual(d.pagesA, 2)
        XCTAssertEqual(d.pagesB, 2)
        XCTAssertTrue(d.isIdentical)
        XCTAssertEqual(d.differingPages, [])
    }

    func test_違うページの番号と_紙の上の場所をmmで言う() throws {
        // 2 ページ目だけ、矩形を 1 つ足す。紙の下から 742 pt、左から 100 pt、200 × 20 pt。
        // 上からは 842 − 742 − 20 = 80 pt = 28.2 mm。左 100 pt = 35.3 mm。
        let a = pdf(pages: [(a4, one), (a4, one)])
        let b = pdf(pages: [(a4, one), (a4, { ctx in self.one(ctx); self.black(100, 742, 200, 20)(ctx) })])
        let d = try comparePDFs(a, b)
        XCTAssertFalse(d.isIdentical)
        XCTAssertEqual(d.differingPages, [2])
        guard case .differ(let pd) = d.pages[1] else { return XCTFail("2 ページ目が違うはず") }
        XCTAssertEqual(pd.regions.count, 1)
        let r = pd.regions[0]
        XCTAssertEqual(r.top, 80 * 25.4 / 72, accuracy: 0.6, "上から（1 px ≈ 0.35 mm の丸めを許す）")
        XCTAssertEqual(r.left, 100 * 25.4 / 72, accuracy: 0.6)
        XCTAssertEqual(r.width, 200 * 25.4 / 72, accuracy: 0.8)
        XCTAssertEqual(r.height, 20 * 25.4 / 72, accuracy: 0.8)
        XCTAssertEqual(pd.pixels.total, 595 * 842, "72 dpi で 1 pt = 1 px")
    }

    func test_離れた2か所は2つの塊() throws {
        let a = pdf(pages: [(a4, one)])
        let b = pdf(pages: [(a4, { ctx in self.one(ctx); self.black(300, 100, 30, 30)(ctx); self.black(100, 400, 30, 30)(ctx) })])
        let d = try comparePDFs(a, b)
        guard case .differ(let pd) = d.pages[0] else { return XCTFail() }
        XCTAssertEqual(pd.regions.count, 2)
        // 左上から読む順: 上にあるほう（下から 400 pt）が先。
        XCTAssertLessThan(pd.regions[0].top, pd.regions[1].top)
    }

    func test_ページ数が違えば余りは比べず_数だけ言う() throws {
        let a = pdf(pages: [(a4, one)])
        let b = pdf(pages: [(a4, one), (a4, one), (a4, one)])
        let d = try comparePDFs(a, b)
        XCTAssertEqual(d.pagesA, 1)
        XCTAssertEqual(d.pagesB, 3)
        XCTAssertEqual(d.pages.count, 1, "共通の 1 ページだけ")
        XCTAssertEqual(d.pages[0], .identical)
        XCTAssertFalse(d.isIdentical, "共通部分が同じでも、ページ数が違えば同じではない")
        XCTAssertEqual(d.differingPages, [], "共通部分に違いは無い、と分けて言える")
    }

    func test_紙の大きさが違えばそれ以上比べない() throws {
        let letter = CGRect(x: 0, y: 0, width: 612, height: 792)
        let a = pdf(pages: [(a4, one)])
        let b = pdf(pages: [(letter, one)])
        let d = try comparePDFs(a, b)
        guard case .sizeMismatch(let sa, let sb) = d.pages[0] else { return XCTFail() }
        XCTAssertEqual(sa.width, 210, accuracy: 0.1)
        XCTAssertEqual(sa.height, 297, accuracy: 0.1)
        XCTAssertEqual(sb.width, 215.9, accuracy: 0.1)
        XCTAssertEqual(sb.height, 279.4, accuracy: 0.1)
        XCTAssertEqual(d.differingPages, [1], "大きさ違いも「違うページ」に数える")
    }

    func test_PDFでないものは投げる() {
        XCTAssertThrowsError(try comparePDFs(Data("hello".utf8), Data("hello".utf8)))
    }

    // MARK: - 文字

    /// 文字を描いた PDF。CoreText で 1 行ずつ置く（座標は紙の下から）。
    private func textPDF(_ lines: [String], annotation: String? = nil) -> Data {
        let data = pdf(pages: [(a4, { ctx in
            var y: CGFloat = 780
            for line in lines {
                let attr = NSAttributedString(string: line, attributes: [
                    .font: CTFontCreateWithName("Helvetica" as CFString, 14, nil)])
                let ct = CTLineCreateWithAttributedString(attr)
                ctx.textPosition = CGPoint(x: 72, y: y)
                CTLineDraw(ct, ctx)
                y -= 24
            }
        })])
        guard let annotation else { return data }
        // 注釈は PDFKit で足す（CoreGraphics には注釈が無い）。
        let doc = PDFDocument(data: data)!
        let page = doc.page(at: 0)!
        let a = PDFAnnotation(bounds: CGRect(x: 100, y: 100, width: 120, height: 30), forType: .freeText, withProperties: nil)
        a.contents = annotation
        page.addAnnotation(a)
        return doc.dataRepresentation()!
    }

    func test_文字をページごとの行として抜く_境にページ番号() throws {
        let lines = try XCTUnwrap(PDFText.lines(in: textPDF(["Article 1  Delivery by 31 October.", "Article 2  Payment monthly."])))
        XCTAssertEqual(lines.first, "[p.1]")
        XCTAssertEqual(lines.count, 3)
        XCTAssertTrue(lines[1].hasPrefix("Article 1"))
    }

    func test_文言の違いは行diffで出る() throws {
        let a = textPDF(["Article 1  Delivery by 31 October.", "Article 2  Payment monthly."])
        let b = textPDF(["Article 1  Delivery by 30 November.", "Article 2  Payment monthly."])
        let d = compareText(try XCTUnwrap(PDFText.text(in: a)), try XCTUnwrap(PDFText.text(in: b)))
        XCTAssertEqual(d.changed, 1)
        XCTAssertEqual(d.added + d.removed, 0)
    }

    func test_注釈の文言も行になる() throws {
        let a = textPDF(["Body."], annotation: "check this")
        let lines = try XCTUnwrap(PDFText.lines(in: a))
        XCTAssertTrue(lines.contains("[FreeText] check this"), "\(lines)")
        let b = textPDF(["Body."])
        let d = compareText(try XCTUnwrap(PDFText.text(in: a)), try XCTUnwrap(PDFText.text(in: b)))
        XCTAssertEqual(d.removed, 1)
    }

    func test_文字の無いPDFはnil() throws {
        XCTAssertNil(PDFText.lines(in: pdf(pages: [(a4, one)])), "矩形だけ ── スキャンと同じ扱い")
    }

    // MARK: - JSON

    func test_JSONはページごとに並び_mmは小数1桁() throws {
        let a = pdf(pages: [(a4, one)])
        let b = pdf(pages: [(a4, { ctx in self.one(ctx); self.black(100, 742, 200, 20)(ctx) }), (a4, one)])
        let d = try comparePDFs(a, b)
        let o = JSONOutput.pdf(d, tolerance: 0)
        XCTAssertEqual(o["kind"] as? String, "pdf")
        XCTAssertEqual(o["result"] as? String, "differ")
        XCTAssertEqual(o["pages_a"] as? Int, 1)
        XCTAssertEqual(o["pages_b"] as? Int, 2)
        XCTAssertEqual(o["dpi"] as? Int, 72)
        let pages = try XCTUnwrap(o["pages"] as? [[String: Any]])
        XCTAssertEqual(pages.count, 1)
        XCTAssertEqual(pages[0]["page"] as? Int, 1)
        XCTAssertEqual(pages[0]["result"] as? String, "differ")
        let regions = try XCTUnwrap(pages[0]["regions"] as? [[String: Any]])
        XCTAssertEqual(regions.count, 1)
        let text = JSONOutput.encode(o)
        XCTAssertTrue(text.contains("\"top_mm\":28."), "小数 1 桁の mm: \(text)")
        XCTAssertNil(o["tolerance"], "緩めていなければ書かない")
    }
}
