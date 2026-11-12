# Spec: Cozy Mail

> 複数の Gmail と、Gmail 以外のメールアカウントを 1 つの受信トレイで扱える、iPhone と Mac 向けのメールアプリ。
> Apple の Liquid Glass デザインで、色はティファニーブルー。ライト/ダークを切り替えられる。

- 状態: **下書き — オーナーの承認待ち**
- デザインの見本: [`sample-img-light.png`](sample-img-light.png) / [`sample-img-dark.png`](sample-img-dark.png)
- 書き方: [agent-skills の spec-driven-development](https://github.com/addyosmani/agent-skills) に沿う (仕様 → 計画 → タスク → 実装。各段階でオーナーが確認する)

---

## 0. 前提にしていること (違っていたら教えてください)

1. **Mac と iPhone のネイティブアプリ**にする。Web アプリや Electron ではない。
2. **iOS 26 / macOS 26 以降だけ**に対応する。Liquid Glass の API がこのバージョンからのため。
3. **使うのはまずオーナー本人だけ**。App Store での公開も TestFlight での配布もしない。自分の Mac と iPhone に直接入れる。
4. **自前のサーバーは置かない**。端末が Gmail や Yahoo! のサーバーと直接やりとりする。
5. **Gmail 以外で最低限つなぎたいのは Yahoo!メール**。iCloud・Outlook・独自ドメインは「つながれば良い」程度。
6. オーナーは **Mac と Xcode を持っている**、または用意できる。
7. **Apple Developer Program (年 99 ドル) には加入しない**。無料の Apple ID で署名する (詳しくは「2.1 配布と無料署名の制約」)。あとで加入しても、コードは変えずにそのまま使えるようにしておく。

---

## 1. 目的 (Objective)

**誰のためか:** Gmail アカウント 3 つ (仕事・プライベート・副業) と Yahoo!メールを毎日使う人。

**困っていること:** アカウントごとにアプリやタブを切り替えるのが面倒。Gmail の純正アプリは Gmail 以外に弱く、Apple 純正のメールアプリは見た目と検索が物足りない。

**作るもの:** 全アカウントを 1 つの「統合受信トレイ」で、読む・書く・送る・整理するができる、見た目が心地よいアプリ。

### ユーザーストーリーと受け入れ条件

優先度: **P0** = 最初に動く版 (v0.1) / **P1** = v1.0 / **P2** = それ以降

| ID | こうしたい | 受け入れ条件 | 優先度 |
|---|---|---|---|
| US-1 | Gmail アカウントを何個でも追加したい | Google ログイン画面からアカウントを選ぶと、30 秒以内に受信トレイが表示される。3 つ追加しても、それぞれ別に表示・送信できる | P0 |
| US-2 | Yahoo! など Gmail 以外も追加したい | メールアドレスとアプリパスワードを入れるだけで、サーバー設定は自動で入る。独自ドメインはサーバー名を手で入れられる (P1) | P0 |
| US-3 | 全アカウントのメールを 1 つの一覧で見たい | 統合受信トレイに全アカウントのメールが新しい順に並ぶ。各行にどのアカウント宛てかが分かる印がある | P0 |
| US-4 | アカウントやフォルダを選んで絞り込みたい | サイドバーでアカウント・フォルダを選ぶと一覧が切り替わる。「すべて / 未読 / スター付き」で絞れる | P0 |
| US-5 | メールを読みたい | HTML メールが崩れずに表示される。スクリプトは動かず、外部画像は押すまで読み込まない。添付ファイルをプレビュー・保存できる | P0 |
| US-6 | 新規作成・返信・転送したい | 宛先・件名・本文・添付を入れて送れる。差出人のアカウントを選べる。返信は受け取ったアカウントから送られる。送ったメールはそのアカウントの「送信済み」に入る | P0 |
| US-7 | 整理したい | 既読/未読・スター・アーカイブ・削除・迷惑メールが、iPhone ではスワイプ、Mac ではボタンとキーボードでできる。操作は 0.1 秒以内に画面に反映され、Gmail の Web 画面にも反映される | P0 |
| US-8 | 未読がいくつあるか知りたい | アカウント別・フォルダ別・アプリアイコンに未読数が出て、サーバーの数と一致する | P0 |
| US-9 | メールを検索したい | 差出人・件名・本文で端末内を検索でき、オフラインでも使える (P0)。端末にない古いメールもサーバー側で探せる (P1) | P0 / P1 |
| US-10 | ライト/ダークを切り替えたい | 「ライト / ダーク / システムに合わせる」を選べて、すぐ切り替わる | P0 |
| US-11 | 電波がなくても読みたい | 一度開いたメールは機内モードで読める。オフライン中の操作は、つながったらサーバーに反映される | P1 |
| US-12 | 新着を通知で知りたい | アプリを開いている間はすぐ、閉じている間は iOS のバックグラウンド更新のタイミングで通知が来る | P1 |
| US-13 | 下書きを別の端末で続けたい | 下書きは自動保存され、サーバーの下書きフォルダ経由で Mac と iPhone の両方に出る | P1 |
| US-14 | 送ったあとで取り消したい | 送信後、設定した秒数 (5〜30 秒) は取り消せる | P1 |
| US-15 | アカウントごとに署名を使いたい | 新規作成・返信のときに、差出人アカウントの署名が自動で入る | P1 |

### やらないこと

- 自前のサーバー、すぐ届くプッシュ通知 (サーバーが必要なため)
- App Store での一般公開、Windows・Android・Web 版
- カレンダー、連絡先管理、AI による要約や自動返信

---

## 2. 技術スタック (Tech Stack)

| 項目 | 選んだもの | 理由 |
|---|---|---|
| 言語 | Swift 6 (strict concurrency を有効) | |
| UI | SwiftUI、iOS と macOS 共通の 1 つのアプリターゲット | Liquid Glass を本物の質感で出せるのは Apple 純正 UI だけ |
| 対応 OS | iOS 26.0+ / macOS 26.0+ | `glassEffect` / `GlassEffectContainer` を使うため |
| Xcode プロジェクト | [XcodeGen](https://github.com/yonaskolb/XcodeGen) の `project.yml` から生成 | `.xcodeproj` を手で編集せずに済み、差分が読みやすい |
| 受信 | IMAP (全アカウント共通)。Gmail は独自拡張 `X-GM-LABELS` / `X-GM-THRID` / `X-GM-MSGID` / `X-GM-RAW` も使う | 1 つの仕組みで Gmail 以外にも対応できる |
| 送信 | SMTP (全アカウント共通) | 同上 |
| IMAP / SMTP 実装 | Apple の [`swift-nio-imap`](https://github.com/apple/swift-nio-imap) を土台に、薄いクライアントを自作。SMTP は SwiftNIO 上に自作 | Apple が保守していて Swift Concurrency と合う |
| ログイン | Gmail: OAuth 2.0 (PKCE) + XOAUTH2、`ASWebAuthenticationSession`。その他: アプリパスワード | パスワードを預からずに済む |
| 端末内の保存 | SwiftData。添付ファイルはファイルとして保存 | オフラインで読む・検索するため |
| 秘密情報 | キーチェーン (その端末だけに保存。同期しない) | 無料署名では iCloud の機能を使えないため |
| 設定の同期 | しない。アカウントや設定は Mac と iPhone でそれぞれ登録する | 同上。有料の署名に切り替えたら iCloud での同期を足す (P2) |
| HTML 表示 | `WKWebView` (JavaScript 無効、外部読み込みを制御) | |
| テスト | Swift Testing (`import Testing`) | |
| 書式とチェック | SwiftFormat、SwiftLint | |

### 2.1 配布と無料署名の制約

無料の Apple ID (Xcode の「Personal Team」) で署名する。

| | Mac | iPhone |
|---|---|---|
| 入れ方 | Xcode でビルドして、自分の Mac で起動する | Xcode から USB または Wi-Fi で入れる |
| 期限 | 実質なし | **7 日で起動しなくなる**。[SideStore](https://sidestore.io) を使い、iPhone だけで自動で入れ直す |

この方法に合わせて、次のことを守る。

- **iCloud・プッシュ通知など、有料の署名が要る機能 (Capability) は使わない。** 使うと無料の署名でビルドできなくなる。
- **アプリの拡張機能 (ウィジェット、共有メニューなど) は作らない (P2)。** 拡張機能 1 つごとにアプリ ID を 1 つ使い、無料の署名ではアプリ ID の数に上限があるため。
- **バンドル ID は最初に決めたら変えない** (例: `com.<オーナーの名前>.cozymail`)。変えるたびにアプリ ID を新しく使ってしまう。
- 新着の確認は、iOS のバックグラウンド更新 (`BGAppRefreshTask`) と、端末内で出す通知 (ローカル通知) で行う。どちらも無料の署名で使える。
- Gmail の OAuth は `ASWebAuthenticationSession` と独自の URL スキームで戻ってくる方式にする。これも無料の署名で使える。
- 署名の設定 (チーム ID) は `project.yml` に直接書かず、各自の `Local.xcconfig` (Git に入れない) から読む。有料の署名に切り替えるときは、ここを変えるだけにする。

---

## 3. コマンド (Commands)

※ まだコードがないので予定。土台を作るときにこのとおり動くようにする。

```bash
# Xcode プロジェクトを生成 (project.yml を変えたら毎回)
xcodegen generate

# UI に依存しない部分のテスト (Linux でも Mac でも動く)
swift test --package-path Packages/MailCore
swift test --package-path Packages/MailStore

# アプリのビルド
xcodebuild -scheme CozyMail -destination 'platform=macOS' build
xcodebuild -scheme CozyMail -destination 'platform=iOS Simulator,name=iPhone 17' build

# アプリ全体のテスト
xcodebuild test -scheme CozyMail -destination 'platform=iOS Simulator,name=iPhone 17'

# 書式とチェック
swiftformat .
swiftlint lint --strict
```

---

## 4. プロジェクト構成 (Project Structure)

```
cozy-mail/
├── project.yml              → XcodeGen の設定 (ここから .xcodeproj を作る)
├── App/                     → SwiftUI アプリ本体 (iOS / macOS 共通)
│   ├── CozyMailApp.swift
│   ├── Features/            → 画面ごとのフォルダ (Inbox, Reader, Compose, Settings, Accounts)
│   ├── DesignSystem/        → 色のトークン、ガラスの部品、背景
│   └── Resources/           → アセット、ローカライズ (日本語が基本)
├── Packages/
│   ├── MailCore/            → IMAP / SMTP / MIME。UI と OS に依存しない
│   │   ├── Sources/MailCore/
│   │   └── Tests/MailCoreTests/   → Fixtures/ に匿名化した実メールを置く
│   ├── MailStore/           → SwiftData のモデル、同期、オフラインの待ち行列
│   └── AccountKit/          → OAuth、キーチェーン、事業者ごとのサーバー設定
├── AppTests/                → 画面の動きのテスト
├── docs/                    → 実機確認の手順書など
├── SPEC.md                  → この仕様書
└── tasks/                   → 計画 (plan.md) とタスク一覧 (todo.md)
```

---

## 5. コードの書き方 (Code Style)

```swift
/// 1 つのメールアカウントへの IMAP 接続。
/// 画面からは直接使わず、MailStore の同期処理だけが使う。
public actor IMAPSession {
    private let account: AccountID
    private let credentials: any CredentialProvider

    public init(account: AccountID, credentials: any CredentialProvider) {
        self.account = account
        self.credentials = credentials
    }

    /// `since` より新しい UID のメールの見出しを取得する。
    public func fetchHeaders(in mailbox: MailboxName, since uid: UID) async throws(IMAPError) -> [MessageHeader] {
        guard uid.isValid else { return [] }
        // ...
    }
}
```

- 型は `UpperCamelCase`、それ以外は `lowerCamelCase`。略語も単語として扱う (`imapSession`、`IMAPSession`)。
- 並行処理は `async/await` と `actor`。`DispatchQueue` やコールバックは使わない。
- エラーは型付き `throws(...)` で、何が起きたかが分かる名前にする。`try!` と `fatalError` は使わない (テストは除く)。
- 画面のコードに色・余白・角丸の数値を直接書かない。必ず `DesignSystem` のトークンを使う。
- 画面に出す文字は `String(localized:)` を通す (日本語を基本にする)。
- 1 ファイル 1 つの主な型。400 行を超えたら分ける。
- インデント 4 スペース、1 行 120 文字まで。SwiftFormat の結果を正とする。

---

## 6. テストの方針 (Testing Strategy)

| 何を | どの層で | どこに | 目標 |
|---|---|---|---|
| IMAP 応答の解析、MIME の解析と生成 (日本語の件名、`ISO-2022-JP`、添付、HTML と本文の両方を持つメール) | 単体テスト | `Packages/MailCore/Tests` | 行カバレッジ 80% 以上 |
| 同期 (新着・削除・フラグ変更・`UIDVALIDITY` の変化・接続切れからの復帰・オフライン中の操作) | 結合テスト (テスト用の偽 IMAP サーバー相手) | `Packages/MailStore/Tests` | 各シナリオに 1 つ以上 |
| Gmail 特有の動き (ラベル = フォルダ、アーカイブ = 受信トレイから外す、同じメールが複数フォルダに出る) | 結合テスト | 同上 | 各動きに 1 つ以上 |
| 画面 | SwiftUI プレビュー (ライト/ダーク × 文字サイズ最大 × 透明度を下げる) と、主な流れの UI テスト | `App/` 内のプレビュー、`AppTests/` | 主な流れ (追加 → 読む → 返信 → アーカイブ) |
| 実際のアカウント | 手動 | `docs/manual-test.md` の手順書 | リリースのたびに実施 |

- 不具合を直すときは、先にその不具合を再現するテストを書く。
- テストで本物のアカウントやネットワークを使わない (手動テストは除く)。

---

## 7. 守ること (Boundaries)

**いつもやる**
- コミットの前に `swift test` (と、Mac ならアプリのビルド) を通す。
- 色・余白は `DesignSystem` のトークンを使う。
- 仕様が変わったら、先にこの SPEC.md を直してから実装する。
- PR には、どの US / 機能マップのモジュールを実装したかを書く。

**先に相談する**
- 新しい外部ライブラリを追加する。
- SwiftData のモデルを変える (保存済みデータの移行が必要になるため)。
- 対応 OS のバージョンを変える。
- Google Cloud の設定が必要な変更。
- 有料の署名 (Apple Developer Program) が必要になる機能を足す。
- メールを外部に送る機能や、サーバーを置く案。

**絶対にやらない**
- パスワード・トークン・実際のメールの中身をコミットする、ログに出す。
- 暗号化なしで IMAP / SMTP に接続する。
- 失敗するテストを消したり飛ばしたりして通す。
- オーナーの許可なく、実際のアカウントからメールを送る・消す。

---

## 8. デザイン

### 8.1 Liquid Glass の使い方

- ガラスにするのは **操作する部品だけ**: ツールバー、ボタン、絞り込みタブ、検索欄、選択中の行、サイドバーの枠。本文の読む部分は文字がはっきり読める面にする (Apple の指針でも、ガラスは操作の層に使う)。
- 標準の部品 (ツールバー、`NavigationSplitView` のサイドバー、シート) は OS が自動でガラスにするので、それを活かす。独自部品には `.glassEffect()` を付け、並ぶものは `GlassEffectContainer` でまとめる。
- 選択中の行やメインのボタンは、ティファニーブルーで色を付けたガラス (`.glassEffect(.regular.tint(...))`)。
- 背景は見本のような、ティファニーブルーの柔らかい波の抽象画像 (ライト用とダーク用)。
- OS の「透明度を下げる」「視差効果を減らす」が有効なら、ガラスと動きを控えめにする。

### 8.2 色のトークン

基準色はティファニーブルー **#81D8D0**。白い背景の上で文字が読めるよう、役割ごとに濃さを変える。

| トークン | ライト | ダーク | 使う場所 |
|---|---|---|---|
| `brand` | #81D8D0 | #81D8D0 | ロゴ、背景の波、ガラスの色付け |
| `accent` | #0A8F88 | #6FD3CA | ボタンの文字、リンク、未読の点 |
| `accentFill` | #81D8D0 | #2A8C85 | 選択中の行、メインのボタン |
| `onAccentFill` | #0B2E2C | #FFFFFF | `accentFill` の上の文字 |
| `background` | #E6F6F4 → #CFEFEB | #071C1C → #0D2B2A | 一番奥の背景 (グラデーション) |
| `textPrimary` | #0F1F1E | #EAF6F5 | 件名、本文 |
| `textSecondary` | #4A5F5D | #9DB5B2 | 書き出し、時刻 |
| `destructive` | システムの赤 | システムの赤 | 削除 |

- 文字と背景の明るさの差は WCAG AA (普通の文字で 4.5:1 以上)。上の値は目安で、実装時に測って調整する。
- 色だけで意味を伝えない (未読は太字にもする)。

### 8.3 画面の形

- **Mac / iPad:** 見本のとおり 3 列 (`NavigationSplitView`)。サイドバー (アカウント・統合受信トレイ・フォルダ) → メール一覧 → 本文。ショートカット: `⌘N` 新規、`⌘R` 返信、`⇧⌘R` 全員に返信、`⌫` 削除、`E` アーカイブ、`⌘F` 検索。
- **iPhone:** 同じ構成を画面の重なりで見せる。起動すると統合受信トレイ。下にガラスのツールバー、新規作成は下から出るシート、一覧はスワイプで操作。
- 角丸は大きめ (パネル 24pt、行 16pt、ボタンはカプセル形)。アイコンは SF Symbols。文字はシステムフォント。

---

## 9. 機能マップ (Capability Map) — 承認待ち

この仕様は、別々に作ってテストできる機能をいくつも含んでいるため、モジュールに分けて順に作る。各モジュールの詳しい仕様は、このマップが承認されたあと `SPEC-<モジュール id>.md` として書く。

| モジュール id | 受け持つこと | 依存先 | 主な US |
|---|---|---|---|
| `design-system` | 色のトークン、ガラスの部品、背景、ライト/ダーク切り替え | — | US-10 |
| `mail-protocol` | IMAP / SMTP の接続、MIME の解析と生成 (`Packages/MailCore`) | — | (土台) |
| `account-auth` | アカウントの追加と削除、Google OAuth、アプリパスワード、キーチェーン、事業者ごとのサーバー設定 | `mail-protocol` | US-1, US-2 |
| `mail-store` | 端末内の保存、同期、オフラインの待ち行列、未読数 | `mail-protocol`, `account-auth` | US-8, US-11 |
| `mail-ui` | サイドバー、統合受信トレイ、一覧、本文表示、整理の操作 | `mail-store`, `design-system` | US-3, US-4, US-5, US-7 |
| `compose` | 新規作成、返信、転送、添付、下書き、署名、送信取り消し | `mail-store`, `design-system` | US-6, US-13, US-14, US-15 |
| `search` | 端末内の全文検索、サーバー側検索 | `mail-store` | US-9 |
| `notifications` | 新着の確認と通知、アイコンのバッジ | `mail-store` | US-12 |

**作る順番:**
`design-system`, `mail-protocol` (同時に進められる) → `account-auth` → `mail-store` → `mail-ui` → `compose`, `search`, `notifications`

- `mail-ui` は `mail-store` の型だけに依存させ、仮データでも動くようにする。これで `design-system` ができた直後に、見本どおりの画面を仮データで確認できる。

### マイルストーン

| 版 | 含むモジュール | 終わりの条件 |
|---|---|---|
| v0.0 | `design-system` + `mail-ui` (仮データ) | Mac と iPhone シミュレーターで、見本と並べて見た目がほぼ同じ。ライト/ダークが切り替わる |
| v0.1 | `mail-protocol`, `account-auth`, `mail-store`, `mail-ui`, `compose` の P0 | 実際の Gmail 3 つと Yahoo! 1 つをつないで、US-1〜US-10 の受け入れ条件を満たす |
| v1.0 | 全モジュールの P1 | Mac と iPhone (SideStore で自動の入れ直し) に入れて、オーナーが 2 週間、ほかのメールアプリを使わずに過ごせる |

---

## 10. 成功の条件 (Success Criteria)

- [ ] Gmail 3 アカウントと Yahoo! 1 アカウントを追加でき、統合受信トレイに全部のメールが出る
- [ ] どのアカウントからも送信でき、相手に届き、そのアカウントの「送信済み」に入る
- [ ] アプリでの既読・スター・アーカイブ・削除が、1 分以内に Gmail / Yahoo! の Web 画面に反映される
- [ ] 未読数がサーバー側の数と一致する
- [ ] 日本語のメール (`ISO-2022-JP` を含む) が文字化けしない
- [ ] 1 万通あるアカウントでも、一覧のスクロールが引っかからない (60fps を保つ)
- [ ] ライト/ダーク両方で、文字と背景の明るさの差が WCAG AA を満たす
- [ ] 「透明度を下げる」が有効なとき、ガラスの代わりに不透明な面になる
- [ ] パスワード・トークンがキーチェーン以外 (データベース、ログ、リポジトリ) に一切ない

---

## 11. 決まっていないこと (Open Questions)

| 問い | いまの考え |
|---|---|
| Gmail の OAuth をどう用意するか | Google の分類で Gmail の全権限は「制限付き」。Google Cloud で OAuth を「テスト」状態にすると 7 日ごとに再ログインになる。自分用なら「本番」状態 (審査なし、ログイン時に「確認されていないアプリ」の警告が出る、利用者は 100 人まで) で使う。予備として、Gmail もアプリパスワードでつなげるようにする。**これで良いか確認したい。** |
| 閉じている間の新着通知 | すぐ届けるには中継サーバーとプッシュ通知 (有料の署名が必要) が要る。v1.0 までは iOS のバックグラウンド更新 (数十分おき) で様子を見る。 |
| 7 日ごとの入れ直しに耐えられるか | SideStore で自動化してみて、それでも面倒なら Apple Developer Program への加入を考える。加入してもコードは変えず、署名の設定を変えるだけで済む。 |
| Gmail を Gmail API でつなぐか | IMAP で足りれば IMAP のまま。足りなければ Gmail だけ API に替えられるよう、事業者ごとの差は `mail-protocol` / `account-auth` の中に閉じこめる。 |
| Yahoo! 以外に必ず使うアカウントはあるか | 前提 5 のとおり、まずは Yahoo! だけを必須にしている。 |
| アプリ名 | 仮に「Cozy Mail」。 |
