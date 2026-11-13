# Spec: Cozy Mail

> 複数の Gmail と、Gmail 以外のメールアカウントを 1 つの受信トレイで扱える、**Mac 専用**のメールアプリ。
> Apple の Liquid Glass デザインで、色はティファニーブルー。ライト/ダークを切り替えられる。

- 状態: **承認済み (2026-11-12)** — 実装計画は [`tasks/plan.md`](tasks/plan.md)
- デザインの見本: [`sample-img-light.png`](sample-img-light.png) / [`sample-img-dark.png`](sample-img-dark.png)
- 書き方: [agent-skills の spec-driven-development](https://github.com/addyosmani/agent-skills) に沿う (仕様 → 計画 → タスク → 実装。各段階でオーナーが確認する)

---

## 0. 前提にしていること (違っていたら教えてください)

1. **Mac のネイティブアプリ**にする。Web アプリや Electron ではない。
2. **macOS 26 (Tahoe) 以降だけ**に対応する。Liquid Glass の API がこのバージョンからのため。
3. **Mac 専用**。iPhone / iPad 版は作らない。ただし、あとで足せるように、画面以外の部分は Mac に依存しない作りにしておく (「12. 将来の iPhone 版」)。
4. **使うのはオーナー本人だけ**。App Store での公開はしない。自分の Mac でビルドして使う。
5. **自前のサーバーは置かない**。Mac が Gmail や Yahoo! のサーバーと直接やりとりする。
6. **Gmail 以外で最低限つなぎたいのは Yahoo!メール**。iCloud・Outlook・独自ドメインは「つながれば良い」程度。
7. オーナーは **Mac と Xcode 26 以降を持っている**、または用意できる。
8. **Apple Developer Program (年 99 ドル) には加入しない**。自分の Mac で使うだけなら不要。

---

## 1. 目的 (Objective)

**誰のためか:** Gmail アカウント 3 つ (仕事・プライベート・副業) と Yahoo!メールを毎日 Mac で使う人。

**困っていること:** アカウントごとにブラウザのタブを切り替えるのが面倒。Apple 純正のメールアプリは見た目と検索が物足りない。

**作るもの:** 全アカウントを 1 つの「統合受信トレイ」で、読む・書く・送る・整理するができる、見た目が心地よい Mac アプリ。

### ユーザーストーリーと受け入れ条件

優先度: **P0** = 最初に動く版 (v0.1) / **P1** = v1.0 / **P2** = それ以降

| ID | こうしたい | 受け入れ条件 | 優先度 |
|---|---|---|---|
| US-1 | Gmail アカウントを何個でも追加したい | メールアドレスとアプリパスワードを入れると、30 秒以内に受信トレイが表示される。3 つ追加しても、それぞれ別に表示・送信できる。「Google でログイン」は P2 | P0 |
| US-2 | Yahoo! など Gmail 以外も追加したい | メールアドレスとアプリパスワードを入れるだけで、サーバー設定は自動で入る。独自ドメインはサーバー名を手で入れられる (P1) | P0 |
| US-3 | 全アカウントのメールを 1 つの一覧で見たい | 統合受信トレイに全アカウントのメールが新しい順に並ぶ。各行にどのアカウント宛てかが分かる印がある | P0 |
| US-4 | アカウントやフォルダを選んで絞り込みたい | サイドバーでアカウント・フォルダを選ぶと一覧が切り替わる。「すべて / 未読 / スター付き」で絞れる | P0 |
| US-5 | メールを読みたい | HTML メールが崩れずに表示される。スクリプトは動かず、外部画像は押すまで読み込まない。添付ファイルを Quick Look でプレビューでき、Finder に保存・ドラッグできる | P0 |
| US-6 | 新規作成・返信・転送したい | 宛先・件名・本文・添付を入れて送れる。差出人のアカウントを選べる。返信は受け取ったアカウントから送られる。送ったメールはそのアカウントの「送信済み」に入る。新規作成は別ウィンドウでも開ける | P0 |
| US-7 | 整理したい | 既読/未読・スター・アーカイブ・削除・迷惑メールが、ツールバーのボタン・右クリックメニュー・キーボードでできる。操作は 0.1 秒以内に画面に反映され、Gmail の Web 画面にも反映される | P0 |
| US-8 | キーボードだけで操作したい | `⌘N` 新規、`⌘R` 返信、`⇧⌘R` 全員に返信、`⇧⌘F` 転送、`⌫` 削除、`E` アーカイブ、`⌘F` 検索、`↑` `↓` で前後のメール。すべてメニューバーにも項目がある | P0 |
| US-9 | 未読がいくつあるか知りたい | アカウント別・フォルダ別・Dock のアイコンに未読数が出て、サーバーの数と一致する | P0 |
| US-10 | メールを検索したい | 差出人・件名・本文で Mac 内を検索でき、オフラインでも使える (P0)。Mac にない古いメールもサーバー側で探せる (P1) | P0 / P1 |
| US-11 | ライト/ダークを切り替えたい | 「ライト / ダーク / システムに合わせる」を選べて、すぐ切り替わる | P0 |
| US-12 | 新着をすぐ知りたい | アプリが起動していれば、サーバーに届いてから 10 秒以内に一覧に出て、Mac の通知が出る。ウィンドウを閉じてもメニューバーに常駐して受け取り続けられる。ログイン時に自動で起動するかを選べる | P1 |
| US-13 | 電波がなくても読みたい | 一度開いたメールはオフラインで読める。オフライン中の操作は、つながったらサーバーに反映される | P1 |
| US-14 | 下書きを残したい | 下書きは自動保存され、サーバーの下書きフォルダにも保存される (Gmail の Web 画面から続きが書ける) | P1 |
| US-15 | 送ったあとで取り消したい | 送信後、設定した秒数 (5〜30 秒) は取り消せる | P1 |
| US-16 | アカウントごとに署名を使いたい | 新規作成・返信のときに、差出人アカウントの署名が自動で入る | P1 |
| US-17 | 複数のメールをまとめて操作したい | `⌘` / `⇧` + クリックで複数選んで、まとめて既読・アーカイブ・削除・移動できる | P1 |

### やらないこと

- iPhone / iPad 版 (あとで足せる作りにはしておく)
- 自前のサーバー
- App Store での公開、Windows・Android・Web 版
- カレンダー、連絡先管理、AI による要約や自動返信

---

## 2. 技術スタック (Tech Stack)

| 項目 | 選んだもの | 理由 |
|---|---|---|
| 言語 | Swift 6 (strict concurrency を有効) | |
| UI | SwiftUI の macOS アプリ。必要な所だけ AppKit を使う | Liquid Glass を本物の質感で出せるのは Apple 純正 UI だけ |
| 対応 OS | macOS 26.0+ | `glassEffect` / `GlassEffectContainer` を使うため |
| Xcode プロジェクト | [XcodeGen](https://github.com/yonaskolb/XcodeGen) の `project.yml` から生成 | `.xcodeproj` を手で編集せずに済み、差分が読みやすい |
| 受信 | IMAP (全アカウント共通)。新着は IMAP IDLE ですぐ受け取る。Gmail は独自拡張 `X-GM-LABELS` / `X-GM-THRID` / `X-GM-MSGID` / `X-GM-RAW` も使う | 1 つの仕組みで Gmail 以外にも対応できる |
| 送信 | SMTP (全アカウント共通) | 同上 |
| IMAP / SMTP 実装 | Apple の [`swift-nio-imap`](https://github.com/apple/swift-nio-imap) を土台に、薄いクライアントを自作。SMTP は SwiftNIO 上に自作 | Apple が保守していて Swift Concurrency と合う |
| ログイン | **全アカウントでアプリパスワード** (Gmail も)。キーチェーンに保存する。Gmail の「Google でログイン」(OAuth 2.0 + XOAUTH2、仕組みは T9 で作成済み) は P2 | Google Cloud の「本番環境」にはホームページとプライバシーポリシーの URL が要り、「テスト」のままだと 7 日ごとに再ログインになるため (2026-11-13 決定)。アプリパスワードなら設定も費用も要らない |
| Mac 内の保存 | SwiftData。添付ファイルはファイルとして保存 | オフラインで読む・検索するため |
| 秘密情報 | macOS のキーチェーン | |
| HTML 表示 | `WKWebView` (JavaScript 無効、外部読み込みを制御) | |
| 常駐と通知 | `MenuBarExtra` (メニューバー)、`UserNotifications` (通知)、`SMAppService` (ログイン時に起動) | |
| テスト | Swift Testing (`import Testing`) | |
| 書式とチェック | SwiftFormat、SwiftLint | |

### 2.1 署名と配布

- 自分の Mac で使うだけなので、Xcode の「Sign to Run Locally」(または無料の Apple ID) で署名する。**期限はない。**
- App Sandbox は有効にし、ネットワーク (送受信と、Google ログインの結果を受け取る 127.0.0.1 の待ち受け) とユーザーが選んだファイル (添付の保存) の権限だけを付ける。
- (P2 で「Google でログイン」を使うとき) Google の OAuth クライアント ID とクライアント シークレットは `Local.xcconfig` に書き、Git に入れない (デスクトップ アプリのシークレットは秘密として扱えないと Google も明言しているが、それでもリポジトリには置かない)。
- iCloud など、有料の署名が要る機能 (Capability) は使わない。
- 署名の設定 (チーム ID) は `project.yml` に直接書かず、各自の `Local.xcconfig` (Git に入れない) から読む。

---

## 3. コマンド (Commands)

※ まだコードがないので予定。土台を作るときにこのとおり動くようにする。

```bash
# Xcode プロジェクトを生成 (project.yml を変えたら毎回)
xcodegen generate

# UI に依存しない部分のテスト (Linux でも Mac でも動く。Apple 専用のターゲットは Mac でだけビルドされる)
swift test --package-path Packages/MailCore
swift test --package-path Packages/MailStore
swift test --package-path Packages/AccountKit

# アプリのビルド
xcodebuild -scheme CozyMail -destination 'platform=macOS' build

# アプリ全体のテスト
xcodebuild test -scheme CozyMail -destination 'platform=macOS'

# 書式とチェック
swiftformat .
swiftlint lint --strict
```

---

## 4. プロジェクト構成 (Project Structure)

```
cozy-mail/
├── project.yml              → XcodeGen の設定 (ここから .xcodeproj を作る)
├── App/                     → SwiftUI の Mac アプリ本体
│   ├── CozyMailApp.swift    → ウィンドウ、メニュー、MenuBarExtra の定義
│   ├── Features/            → 画面ごとのフォルダ (Inbox, Reader, Compose, Settings, Accounts)
│   ├── DesignSystem/        → 色のトークン、ガラスの部品、背景
│   └── Resources/           → アセット、ローカライズ (日本語が基本)
├── Packages/                → ここは Mac に依存しない (将来 iPhone 版でも使う)
│   ├── MailCore/            → IMAP / SMTP / MIME。UI と OS に依存しない
│   │   ├── Sources/MailCore/
│   │   └── Tests/MailCoreTests/   → Fixtures/ に匿名化した実メールを置く
│   ├── MailStore/           → 同期、オフラインの待ち行列、保存先の型 (`MessageStore` プロトコル) とメモリ上の実装
│   │                          SwiftData の実装は Apple 専用のターゲット `MailStoreSwiftData` に分ける
│   └── AccountKit/          → OAuth、事業者ごとのサーバー設定、秘密情報の型 (`SecretStore` プロトコル)
│                              キーチェーンの実装は Apple 専用のターゲット `AccountKitKeychain` に分ける
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
- `Packages/` の中で `AppKit` を import しない (将来の iPhone 版のため)。
- 画面に出す文字は `String(localized:)` を通す (日本語を基本にする)。
- 1 ファイル 1 つの主な型。400 行を超えたら分ける。
- インデント 4 スペース、1 行 120 文字まで。SwiftFormat の結果を正とする。

---

## 6. テストの方針 (Testing Strategy)

| 何を | どの層で | どこに | 目標 |
|---|---|---|---|
| IMAP 応答の解析、MIME の解析と生成 (日本語の件名、`ISO-2022-JP`、添付、HTML と本文の両方を持つメール) | 単体テスト | `Packages/MailCore/Tests` | 行カバレッジ 80% 以上 |
| 同期 (新着・IDLE・削除・フラグ変更・`UIDVALIDITY` の変化・接続切れからの復帰・スリープからの復帰・オフライン中の操作) | 結合テスト (テスト用の偽 IMAP サーバー相手) | `Packages/MailStore/Tests` | 各シナリオに 1 つ以上 |
| Gmail 特有の動き (ラベル = フォルダ、アーカイブ = 受信トレイから外す、同じメールが複数フォルダに出る) | 結合テスト | 同上 | 各動きに 1 つ以上 |
| 画面 | SwiftUI プレビュー (ライト/ダーク × 文字サイズ大 × 透明度を下げる) と、主な流れの UI テスト | `App/` 内のプレビュー、`AppTests/` | 主な流れ (追加 → 読む → 返信 → アーカイブ) |
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
- 対応 OS のバージョンを変える、iPhone / iPad 版を足す。
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

- **背景の波の上に、角の丸いガラスのパネルを 3 枚浮かべる** (サイドバー、メール一覧、本文)。パネルどうしとウィンドウの端は少し空ける。標準の `NavigationSplitView` は列に不透明な背景を敷いて波を隠すので使わない (2026-11-13、オーナーの「高級感がない」という指摘を受けて変更)。
- ガラス (`glassEffect`) にするのは **パネルだけ**。ガラスの上にガラスを重ねると濁るので、パネルの中の選択中の行・タブ・ボタン・検索欄は「つやのある膨らみ」(半透明の白、または上に艶のあるティファニーブルー + 縁の光 + 小さな影) で表す。
- パネルには、縁の光 (左上が明るく右下に消える細い線) と、やわらかい影を付ける。
- タイトルバーは消し、ウィンドウの赤・黄・緑のボタンはサイドバーのパネルの上に乗せる。ツールバーと検索欄は本文パネルの中に置く (返信と全員に返信は 1 つのカプセル)。
- 背景は、ガラス越しに形と明暗がはっきり見える、立体的な液体の波 (網目グラデーション + ぼかした艶のあるしずく)。ゆっくり動かす。
- 本文の読む部分は、文字がはっきり読めるようにする。
- OS の「透明度を下げる」「視差効果を減らす」が有効なら、ガラスと動きを控えめにする。

### 8.2 色のトークン

基準色はティファニーブルー **#81D8D0**。白い背景の上で文字が読めるよう、役割ごとに濃さを変える。

| トークン | ライト | ダーク | 使う場所 |
|---|---|---|---|
| `brand` | #81D8D0 | #81D8D0 | ロゴ、背景の波、ガラスの色付け |
| `accent` | #08736D | #6FD3CA | ボタンの文字、リンク、未読の点 |
| `accentFill` | #81D8D0 | #1F7A74 | 選択中の行、メインのボタン |
| `onAccentFill` | #0B2E2C | #FFFFFF | `accentFill` の上の文字 |
| `background` | #E6F6F4 → #CFEFEB | #071C1C → #0D2B2A | 一番奥の背景 (グラデーション) |
| `textPrimary` | #0F1F1E | #EAF6F5 | 件名、本文 |
| `textSecondary` | #4A5F5D | #9DB5B2 | 書き出し、時刻 |
| `panel` | #F4FBFA | #0F2827 | 「透明度を下げる」のときにガラスの代わりに使う面 |
| `destructive` | システムの赤 | システムの赤 | 削除 |

- 文字と背景の明るさの差は WCAG AA (普通の文字で 4.5:1 以上)。T2 で測り、`accent` (ライト) と `accentFill` (ダーク) を濃くした。アプリのテスト (`AppTests/ColorTokenTests.swift`) で毎回確かめる。
- 色だけで意味を伝えない (未読は太字にもする)。

### 8.3 画面の形

- **メインウィンドウ:** 見本のとおり 3 列 (`NavigationSplitView`)。
  1. サイドバー: アプリ名、アカウント一覧 (未読数つき)、統合受信トレイ、フォルダ一覧、アカウント追加ボタン
  2. メール一覧: 見出しと未読数、新規作成ボタン、絞り込みタブ、メールの行
  3. 本文: ツールバー (返信・全員に返信・削除・アーカイブ・フラグ・その他・検索欄)、件名、差出人、宛先、日時、本文、添付
- **作成ウィンドウ:** 新規作成・返信は別ウィンドウで開く (メインウィンドウ内のシートにも切り替えられる: P2)。
- **メニューバー:** 未読数のアイコン。押すと最新の未読数件と「新規作成」「Cozy Mail を開く」。
- **設定ウィンドウ:** `⌘,` で開く。アカウント、見た目 (テーマ)、通知、署名。
- 最小のウィンドウ幅は 900pt。狭くなったら本文の列を一覧の上に重ねて表示する。
- 角丸は大きめ (パネル 24pt、行 16pt、ボタンはカプセル形)。アイコンは SF Symbols。文字はシステムフォント。

---

## 9. 機能マップ (Capability Map) — 承認済み

この仕様は、別々に作ってテストできる機能をいくつも含んでいるため、モジュールに分けて順に作る。各モジュールの詳しい仕様は、このマップが承認されたあと `SPEC-<モジュール id>.md` として書く。

| モジュール id | 受け持つこと | 依存先 | 主な US |
|---|---|---|---|
| `design-system` | 色のトークン、ガラスの部品、背景、ライト/ダーク切り替え | — | US-11 |
| `mail-protocol` | IMAP (IDLE を含む) / SMTP の接続、MIME の解析と生成 (`Packages/MailCore`) | — | (土台) |
| `account-auth` | アカウントの追加と削除、Google OAuth、アプリパスワード、キーチェーン、事業者ごとのサーバー設定 | `mail-protocol` | US-1, US-2 |
| `mail-store` | Mac 内の保存、同期、オフラインの待ち行列、未読数 | `mail-protocol`, `account-auth` | US-9, US-13 |
| `mail-ui` | サイドバー、統合受信トレイ、一覧、本文表示、整理の操作、キーボード操作 | `mail-store`, `design-system` | US-3, US-4, US-5, US-7, US-8, US-17 |
| `compose` | 新規作成、返信、転送、添付、下書き、署名、送信取り消し | `mail-store`, `design-system` | US-6, US-14, US-15, US-16 |
| `search` | Mac 内の全文検索、サーバー側検索 | `mail-store` | US-10 |
| `notifications` | 新着の通知、Dock とメニューバーの未読数、メニューバー常駐、ログイン時の起動 | `mail-store` | US-12 |

**作る順番:**
`design-system`, `mail-protocol` (同時に進められる) → `account-auth` → `mail-store` → `mail-ui` → `compose`, `search`, `notifications`

- `mail-ui` は `mail-store` の型だけに依存させ、仮データでも動くようにする。これで `design-system` ができた直後に、見本どおりの画面を仮データで確認できる。

### マイルストーン

| 版 | 含むモジュール | 終わりの条件 |
|---|---|---|
| v0.0 | `design-system` + `mail-ui` (仮データ) | 見本と並べて見た目がほぼ同じ。ライト/ダークが切り替わる |
| v0.1 | `mail-protocol`, `account-auth`, `mail-store`, `mail-ui`, `compose` の P0 | 実際の Gmail 3 つと Yahoo! 1 つをつないで、P0 の US の受け入れ条件を満たす |
| v1.0 | 全モジュールの P1 | オーナーが 2 週間、ほかのメールアプリやブラウザの Gmail を使わずに過ごせる |

---

## 10. 成功の条件 (Success Criteria)

- [ ] Gmail 3 アカウントと Yahoo! 1 アカウントを追加でき、統合受信トレイに全部のメールが出る
- [ ] どのアカウントからも送信でき、相手に届き、そのアカウントの「送信済み」に入る
- [ ] アプリでの既読・スター・アーカイブ・削除が、1 分以内に Gmail / Yahoo! の Web 画面に反映される
- [ ] アプリの起動中は、新着がサーバーに届いてから 10 秒以内に一覧と通知に出る
- [ ] Mac のスリープから戻ったあと、1 分以内に新着の受け取りが再開する
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
| ~~Gmail をどうつなぐか~~ | **決定 (2026-11-13):** アプリパスワード。Google Cloud の OAuth を「本番」にするにはホームページとプライバシーポリシーの URL が必要で用意できず、「テスト」のままでは 7 日ごとに再ログインになるため。OAuth の仕組み (T9) は残してあり、URL を用意すれば (例: GitHub Pages) P2 で「Google でログイン」を足せる。手順は `docs/app-passwords.md`。 |
| Gmail を Gmail API でつなぐか | IMAP で足りれば IMAP のまま。足りなければ Gmail だけ API に替えられるよう、事業者ごとの差は `mail-protocol` / `account-auth` の中に閉じこめる。 |
| Yahoo! 以外に必ず使うアカウントはあるか | 前提 6 のとおり、まずは Yahoo! だけを必須にしている。 |
| アプリ名 | 仮に「Cozy Mail」。 |

---

## 12. 将来の iPhone 版

いまは作らない。欲しくなったときに足しやすいよう、次のことだけ守っておく。

- `Packages/` (メールの送受信・保存・ログイン) は Mac に依存させない (`AppKit` を使わない)。
- 色のトークンやガラスの部品は SwiftUI だけで書く。
- iPhone 版を足すときは、iOS 用のアプリターゲットと iPhone 向けの画面を追加する。無料の Apple ID では 7 日ごとに入れ直しが必要になる点 (SideStore で自動化できる) は、そのときに改めて決める。
