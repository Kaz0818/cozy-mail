# CLAUDE.md — Cozy Mail で作業する Claude へ

このプロジェクトは、オーナーの Mac (ローカル) と、クラウド (claude.ai/code の Linux) の 2 か所で作業する。
このファイルは、どちらの Claude も守る作業のやり方。仕様は [SPEC.md](SPEC.md)、計画は [tasks/plan.md](tasks/plan.md)、タスクは [tasks/todo.md](tasks/todo.md)。

**作業を始める前に、必ず [docs/handoff.md](docs/handoff.md) (引き継ぎ書) を読む。** 今の状況・次にやること・ローカルとクラウドの受け渡し方が書いてある。
作業を終えるときは、引き継ぎ書の「今の状況」と「作業の記録」を書き直してから終える。

## オーナーとのやりとり

- **返事は日本語で、やさしい言葉で書く。** 専門用語はできるだけ避け、使うときは短く説明する。
- オーナーは「ミスしないでね」と何度も言っている。**急がず、確かめてから報告する。**
  - 「できました」と言うのは、テストとビルドが通ったのを自分の目で見たあとだけ。
  - 失敗・飛ばした手順・確かめられなかったことは、そのまま正直に書く。
- 選ぶことがあるときは、おすすめを 1 つ挙げて理由を書き、オーナーに決めてもらう。
- 「お願い」と言われてから作業を始める。提案だけのときは、勝手に進めない。
- SPEC.md の「先に相談する」に当たることは、作る前に必ず聞く (例: 保存の仕組みを変える、外部ライブラリを足す)。

## 進め方 (毎回)

1. tasks/todo.md で、今のタスクの「受け入れ条件」と「確認」を読む。
2. **テストを先に書く** (TDD)。不具合を直すときは、先に再現するテストを書く。
3. 作る。仕様が変わるなら、先に SPEC.md を直す。
4. テストとビルドを通す (下の「コマンド」)。警告も残さない (Swift 6 の厳しい並行処理チェックが有効)。
5. tasks/todo.md と tasks/plan.md のチェックを更新する。
   - 🐧 = 自動テストで確かめられること、🍎 = オーナーが Mac で手で確かめること。
   - 🍎 は、オーナーが「確認した」と言うまでチェックしない。
6. コミット → プッシュ → プルリクエスト (下の「Git」)。CI が通ったのを見てから報告する。
7. 報告には「何をしたか」「どう確かめたか (テスト件数など)」「オーナーに Mac で見てほしいこと」を書く。

## コマンド

```bash
# Xcode プロジェクトを作る (project.yml を変えたら毎回。.xcodeproj は Git に入れない)
xcodegen generate

# パッケージのテスト (Linux でも Mac でも動く)
swift test --package-path Packages/MailCore
swift test --package-path Packages/MailStore
swift test --package-path Packages/AccountKit

# アプリのビルドと、単体テスト + UI テスト (Mac だけ)
xcodebuild test -scheme CozyMail -destination 'platform=macOS'
```

- UI テストは `-ui-testing` で起動し、メモリ上だけで動く (本物のアカウントやキーチェーンに触れない)。
- 2026-11-14 時点のテスト件数: MailCore 82 件、MailStore 113 件 (うち SwiftData 17 件は Mac だけ。Linux では 96 件)、アプリ 59 件 + UI テスト 6 件。減っていたら理由を調べる。

## CI (GitHub Actions、`.github/workflows/ci.yml`)

- プルリクエストでは **Linux のパッケージのテストだけ** が自動で回る (macOS は無料時間を 10 倍の速さで使うため)。
- macOS のビルドとテストは、main に取り込んだときと、手動実行 (Actions の「Run workflow」でブランチを選ぶ) のときだけ。
- ローカルで `xcodebuild test` が通っていれば、プルリクエストでの macOS の手動実行は省いてよい。通ったことは報告に書く。
- クラウドでは `xcodebuild` が使えないので、アプリや SwiftData のコードを変えたら、CI の macOS を手動で動かして結果を確かめる。

## 作りの決まりごと

- **`Packages/` (MailCore、MailStore、AccountKit) は Linux でもビルドとテストができる状態を保つ。** CI の Linux がこれを確かめている。
  - Mac にしかないもの (キーチェーン、SwiftData など) は、Apple 専用のターゲットに分ける。例: `AccountKitKeychain`。
  - SwiftData で保存先を作るなら、`MailStore` 本体ではなく Apple 専用のターゲット (例: `MailStoreSwiftData`) に置き、
    Linux の `swift test --package-path Packages/MailStore` が壊れないようにする。
- 保存先は `MessageStore` プロトコルで隠す。テストはメモリ上の `InMemoryMessageStore` で行う。
- 画面の色・余白は `App/DesignSystem` のトークンを使う。コードのコメントは日本語。
- Swift 6 (`SWIFT_STRICT_CONCURRENCY: complete`)、macOS 26 以降、XcodeGen (`project.yml`)。

## 絶対にやらない

- パスワード・トークン・実際のメールの中身を、コミットしたりログに出したりする。アプリ用パスワードはキーチェーンにだけ置く。
- `Local.xcconfig` (チーム ID・クライアント ID など) をコミットする (`.gitignore` 済み)。
- テストで本物のアカウントやネットワークを使う。オーナーの許可なく、実際のアカウントからメールを送る・消す。
- 失敗するテストを消したり飛ばしたりして通す。
- force push する。main に直接プッシュする。

## Git

- main から作業用のブランチを作り、そこにコミットする。プルリクエストは下書き (draft) で作り、マージはオーナーがする。
- コミットするファイルは `git add -A` ではなく、名前を指定して足す (関係ないファイルを入れないため)。
- マージされたら、main を取り込んでから次の作業を始める。
- ローカルとクラウドで、同時に同じブランチを触らない。受け渡しは main を通す (引き継ぎ書の 1 章)。
- 参考用のブランチ `claude/file-message-store` は **マージしない** (引き継ぎ書を参照)。

## 今の状況

[docs/handoff.md](docs/handoff.md) に書く (ここには書かない。情報を 1 か所にまとめるため)。
署名とキーチェーンの確認を減らす方法は [docs/signing.md](docs/signing.md)。
