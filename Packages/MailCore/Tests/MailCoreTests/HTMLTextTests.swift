import Testing
@testable import MailCore

/// HTML メールから、一覧の書き出しや検索に使う文章を取り出す。
@Suite struct HTMLTextTests {
    @Test func dropsTagsAndKeepsLineBreaks() {
        let html = "<html><body><p>こんにちは、<b>山田</b>さん。</p><p>資料を<br>送ります。</p></body></html>"
        #expect(HTMLText.plainText(from: html) == "こんにちは、山田さん。\n資料を\n送ります。")
    }

    @Test func ignoresHeadStyleAndScript() {
        let html = """
        <html><head><title>件名</title><style>p { color: red; }</style></head>
        <body><script>alert('x')</script><div>本文</div></body></html>
        """
        #expect(HTMLText.plainText(from: html) == "本文")
    }

    @Test func decodesEntities() {
        #expect(HTMLText.plainText(from: "A&amp;B &lt;tag&gt; &quot;q&quot; &#39;s&#39; &#x3042;&#12354;&nbsp;end") == "A&B <tag> \"q\" 's' ああ end")
    }

    @Test func collapsesWhitespaceAndBlankLines() {
        let html = "<div>  一行目   です  </div>\n\n\n<div></div><div></div><div>二行目</div>"
        #expect(HTMLText.plainText(from: html) == "一行目 です\n\n二行目")
    }

    @Test func tableCellsAreSeparated() {
        #expect(HTMLText.plainText(from: "<table><tr><td>商品</td><td>1,000円</td></tr></table>") == "商品 1,000円")
    }
}
