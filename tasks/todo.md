# タスク一覧: Cozy Mail (Mac 版)

計画の全体は [`plan.md`](plan.md)、仕様は [`SPEC.md`](../SPEC.md)。
大きさ: **S** = 1〜2 ファイル / **M** = 3〜5 ファイル / **L** = 5 ファイル以上 (分けることを検討する)

確認の書き方:
- 🐧 = この作業環境 (Linux) で Claude が確認できる
- 🍎 = オーナーの Mac で確認する

---

## フェーズ 0: 土台

### T1: プロジェクトの土台

> 状態: ✅ 済 (Linux で `swift test`、GitHub Actions の macOS 26 でアプリのビルドとテストが通過)

**説明:** XcodeGen の `project.yml`、空のウィンドウが出るだけの Mac アプリ、3 つの Swift パッケージ (`MailCore`、`MailStore`、`AccountKit`) を作る。各パッケージには何もしないテストを 1 つ置く。書式とチェックの設定、`.gitignore`、署名の設定の見本 (`Local.xcconfig.sample`) も作る。あわせて、この作業環境に Swift の Linux 版を入れられるか試す。

**受け入れ条件:**
- [x] `xcodegen generate` で `.xcodeproj` ができ、ビルドできる (CI で確認。ウィンドウの表示は未確認)
- [x] 3 つのパッケージの `swift test` が通る
- [x] 署名のチーム ID が Git に入っていない (`Local.xcconfig` は `.gitignore` 済み)

**確認:**
- [x] 🐧 `swift test --package-path Packages/MailCore` (Linux 版の Swift 6.2.3 で確認)
- [x] 🍎 `xcodegen generate && xcodebuild -scheme CozyMail -destination 'platform=macOS' build` (CI の macOS 26 で確認)
- [ ] 🍎 アプリを起動して、空のウィンドウが出る

**依存:** なし
**触るファイル:** `project.yml`、`App/CozyMailApp.swift`、`Packages/*/Package.swift`、`Packages/*/Tests/*`、`.gitignore`、`.swiftformat`、`.swiftlint.yml`、`Local.xcconfig.sample`
**大きさ:** M (ファイル数は多いが、どれも中身は小さい)

### T2: 色のトークン、背景、テーマの切り替え

> 状態: 🐧 CI の macOS でビルドとコントラストのテストが通過 / 🍎 見た目の確認待ち。`accent` (ライト) と `accentFill` (ダーク) は AA を満たさなかったので濃くした (SPEC 8.2 も更新)

**説明:** SPEC 8.2 の色をトークンとして定義し、ティファニーブルーの波の背景 (ライト用・ダーク用) と、ガラスの部品 (カプセル形のボタン、色付きガラスの行) を作る。設定で「ライト / ダーク / システムに合わせる」を切り替えられるようにする。

**受け入れ条件:**
- [ ] 画面のコードに色の値を直接書かず、すべてトークン経由になっている
- [ ] テーマの切り替えが、アプリを再起動せずにすぐ反映される (US-11)
- [ ] 「透明度を下げる」が有効なとき、ガラスの代わりに不透明な面になる

**確認:**
- [ ] 🍎 SwiftUI プレビューで、ライト/ダーク × 透明度を下げる の 4 通りを見る
- [x] 🍎 文字と背景の明るさの差を測り、WCAG AA (4.5:1 以上) を満たす。満たさない色はトークンを直して SPEC も更新する (`AppTests/ColorTokenTests.swift`)

**依存:** T1
**触るファイル:** `App/DesignSystem/Colors.swift`、`App/DesignSystem/GlassComponents.swift`、`App/DesignSystem/AppBackground.swift`、`App/Resources/Assets.xcassets`、`App/Features/Settings/AppearanceSettings.swift`
**大きさ:** M

---

## フェーズ 1: v0.0 見た目 (仮データ)

### T3: メールの型と、仮データの `MailRepository`

> 状態: ✅ 済 (テスト 10 件)

**説明:** 画面が使う型 (`Account`、`Mailbox`、`MessageSummary`、`MessageBody`、`Attachment`) と、画面がデータを取りに行く窓口の `MailRepository` プロトコルを `MailStore` に作る。見本の画像と同じ内容 (山田 さくら、Google、田中 健一 など) を返す仮の実装も作る。

**受け入れ条件:**
- [x] 型と `MailRepository` が `MailStore` にあり、`AppKit` / `SwiftData` を import していない
- [x] 仮の実装が、見本と同じアカウント 4 つ・メール 6 通・未読数を返す

**確認:**
- [x] 🐧 `swift test --package-path Packages/MailStore` (仮の実装の件数と未読数のテスト)

**依存:** T1
**触るファイル:** `Packages/MailStore/Sources/MailStore/Models.swift`、`MailRepository.swift`、`PreviewMailRepository.swift`、`Tests/MailStoreTests/PreviewMailRepositoryTests.swift`
**大きさ:** S

### T4: サイドバー

> 状態: 🐧 CI の macOS でビルドと `InboxModel` のテストが通過 / 🍎 見本との見比べ待ち

**説明:** 3 列の `NavigationSplitView` を作り、左の列に、アプリ名、アカウント一覧 (未読数つき)、統合受信トレイ、フォルダ一覧、アカウント追加ボタン (押しても何もしない) を出す。データは T3 の仮の実装から取る。

**受け入れ条件:**
- [ ] 見本と同じ並びで、アカウントとフォルダが出る
- [ ] 項目を選ぶと選択中の見た目 (色付きガラス) になる
- [ ] 未読数がアカウント別・フォルダ別に出る (US-9 の見た目)

**確認:**
- [ ] 🍎 アプリを起動して、見本の左の列と並べて比べる (ライト/ダーク)

**依存:** T2, T3
**触るファイル:** `App/Features/Inbox/MainWindow.swift`、`App/Features/Inbox/SidebarView.swift`、`App/Features/Inbox/SidebarRow.swift`
**大きさ:** S

### T5: メール一覧と絞り込みタブ

> 状態: 🐧 CI の macOS でビルドと `InboxModel` のテストが通過 / 🍎 見本との見比べ待ち

**説明:** 真ん中の列に、見出し (「受信トレイ」「すべてのアカウント・22 件の未読」)、新規作成ボタン、「すべて / 未読 / スター付き」のタブ、メールの行 (差出人のアイコン、名前、件名、書き出し、時刻、未読の点、スター) を出す。

**受け入れ条件:**
- [ ] サイドバーで選んだアカウント・フォルダに合わせて、一覧が切り替わる (US-4)
- [ ] タブで絞り込める
- [ ] 未読のメールは点と太字の両方で分かる

**確認:**
- [ ] 🍎 見本の真ん中の列と並べて比べる (ライト/ダーク)
- [ ] 🍎 タブとサイドバーを切り替えて、一覧が変わる

**依存:** T4
**触るファイル:** `App/Features/Inbox/MessageListView.swift`、`App/Features/Inbox/MessageRow.swift`、`App/Features/Inbox/FilterTabs.swift`、`App/DesignSystem/AvatarView.swift`
**大きさ:** M

### T6: 本文の列とツールバー

> 状態: 🐧 CI の macOS でビルドと `InboxModel` のテストが通過 / 🍎 見本との見比べ待ち

**説明:** 右の列に、ツールバー (返信・全員に返信・削除・アーカイブ・フラグ・その他・検索欄)、件名、差出人、宛先、日時、本文 (このタスクではプレーンテキストだけ)、添付ファイルのカードを出す。ボタンは押しても何もしない。

**受け入れ条件:**
- [ ] 一覧でメールを選ぶと、右の列にそのメールが出る
- [ ] ツールバーのボタンと検索欄がガラスの見た目になっている
- [ ] ウィンドウを 900pt まで狭めても崩れない

**確認:**
- [ ] 🍎 見本の右の列と並べて比べる (ライト/ダーク)

**依存:** T5
**触るファイル:** `App/Features/Reader/ReaderView.swift`、`App/Features/Reader/ReaderHeader.swift`、`App/Features/Reader/AttachmentCard.swift`、`App/Features/Reader/ReaderToolbar.swift`
**大きさ:** M

### ✅ チェックポイント v0.0 — 🍎 オーナーの見比べ待ち
- [ ] 🍎 アプリの画面を見本の 2 枚と並べて、オーナーが「ほぼ同じ」と判断する
- [ ] 🍎 ライト / ダーク / システムに合わせる が切り替わる
- [ ] 🐧 すべてのパッケージのテストが通る
- [ ] **オーナーと確認してから次に進む**

---

## フェーズ 2: 危険の確認 (フェーズ 1 と同時に進めてよい)

### T7: IMAP で Yahoo! にログインして見出しを取る

> 状態: 🐧 済 (偽サーバー相手のテスト 8 件) / 🍎 **2026-11-13 オーナーの Mac で、実際の Gmail にアプリパスワードで接続し、件数と件名を確認済み**。Yahoo! は未確認。`swift-nio-imap` 0.4.0 は使いやすく、使い続けて問題なさそう

**説明:** `swift-nio-imap` を使って、TLS で接続し、ログインし、フォルダ一覧 (`LIST`、`SPECIAL-USE`) を取り、受信トレイの最新 20 通の見出し (`UID FETCH`) を取る最小のクライアントを `MailCore` に作る。確認用のコマンドラインのツール `cozymail-probe` からこれを呼べるようにする。パスワードはコマンドの引数ではなく、環境変数か入力で受け取る。

**受け入れ条件:**
- [x] 偽の IMAP サーバー相手のテストで、ログイン・フォルダ一覧・見出しの取得が通る
- [x] 暗号化なしの接続はできない
- [x] ログにパスワードが出ない

**確認:**
- [x] 🐧 `swift test --package-path Packages/MailCore`
- [ ] 🍎 オーナーが Yahoo! のアプリパスワードで `swift run --package-path Packages/MailCore cozymail-probe imap.mail.yahoo.co.jp <メールアドレス>` を実行し、受信トレイの件名が 20 件出る

**依存:** T1
**触るファイル:** `Packages/MailCore/Package.swift`、`Sources/MailCore/IMAP/IMAPSession.swift`、`Sources/MailCore/IMAP/IMAPModels.swift`、`Sources/cozymail-probe/main.swift`、`Tests/MailCoreTests/IMAPSessionTests.swift` (偽サーバーを含む)
**大きさ:** M (新しいライブラリを使うので、時間がかかったらここで相談する)

### T8: MIME の解析

> 状態: ✅ 済 (テスト 17 件、見本メール 12 通)。EUC-JP は Linux の Foundation が対応していないため、Mac でだけ読める (テストは未作成)

**説明:** メールの生データを、件名・差出人・宛先・日時・本文 (テキストと HTML)・添付ファイルに分ける解析器を `MailCore` に作る。RFC 2047 の件名 (`=?ISO-2022-JP?B?...?=` など)、`quoted-printable` / `base64`、`multipart/alternative` と `multipart/mixed` に対応する。

**受け入れ条件:**
- [x] 日本語の件名と本文 (`UTF-8`、`ISO-2022-JP`、`Shift_JIS`) が文字化けしない
- [x] HTML とテキストの両方を持つメールで、両方を取り出せる
- [x] 添付ファイルの名前 (日本語を含む) と中身を取り出せる

**確認:**
- [x] 🐧 `swift test --package-path Packages/MailCore` (匿名化したサンプルを `Tests/MailCoreTests/Fixtures/` に 10 通以上)

**依存:** T1
**触るファイル:** `Sources/MailCore/MIME/MIMEParser.swift`、`Sources/MailCore/MIME/EncodedWord.swift`、`Sources/MailCore/MIME/Charset.swift`、`Tests/MailCoreTests/MIMEParserTests.swift`、`Tests/MailCoreTests/Fixtures/*.eml`
**大きさ:** M

### T9: Gmail の OAuth と XOAUTH2 でのログイン

> 状態: 🐧 済 (AccountKit のテスト 19 件、XOAUTH2 のテスト 3 件)。**2026-11-13: Gmail はアプリパスワードでつなぐことにしたので、実際の Google での確認は P2 に回した** (「本番環境」に URL が必要なため)。方式は「デスクトップ アプリ」用クライアント + ブラウザ + 127.0.0.1 で受け取る形に決めた (SPEC 2 章)。アプリのログイン画面は T12 で作る

**説明:** Google Cloud での OAuth の設定手順を `docs/google-oauth-setup.md` に書く (「本番」状態にする手順を含む)。`AccountKit` に、PKCE を使った認可 URL の組み立て、トークンの取得と更新、`SecretStore` プロトコルを作る。キーチェーンの実装 (`AccountKitKeychain`) と、`ASWebAuthenticationSession` でログイン画面を出す処理も作る。`MailCore` の IMAP は XOAUTH2 でもログインできるようにする。

**受け入れ条件:**
- [x] トークンの更新とエラー (取り消された、期限切れ) の扱いを、テストで確認できる
- [x] トークンはキーチェーンにだけ保存され、ログに出ない
- [ ] 「テスト」状態ではなく「本番」状態で、1 週間後もログインし直さずに使える

**確認:**
- [x] 🐧 `swift test --package-path Packages/AccountKit`
- [ ] 🍎 オーナーが手順書どおりに Google Cloud を設定し、`cozymail-probe --gmail` で Gmail の受信トレイの件名が 20 件出る
- [ ] 🍎 キーチェーンへの保存 (`KeychainSecretStore`) が Mac で動く (CI の macOS でビルドは確認)

**依存:** T7
**触るファイル:** `docs/google-oauth-setup.md`、`Packages/AccountKit/Sources/AccountKit/OAuth.swift`、`SecretStore.swift`、`Packages/AccountKit/Sources/AccountKitKeychain/KeychainSecretStore.swift`、`Packages/MailCore/Sources/MailCore/IMAP/XOAuth2.swift`
**大きさ:** M

### ✅ チェックポイント: 危険の確認
- [ ] 🍎 Gmail と Yahoo! の両方で、アプリパスワードを使って受信トレイの見出しが取れる (`docs/app-passwords.md`) — Gmail は確認済み (2026-11-13)、Yahoo! は未確認
- [ ] 🐧 すべてのパッケージのテストが通る
- [x] `swift-nio-imap` を使い続けるか、オーナーと確認する — 実際の Gmail で動いたので使い続ける (0.4.x に固定。0.5.0 は API が変わったので、上げるときは別の作業)

---

## フェーズ 3: v0.1 実際に使える

### T10: 保存と同期

> 状態 (2026-11-13): 🐧 **同期処理とメモリ上の保存先は済** (テスト 12 件)。SwiftData の保存先 (`MailStoreSwiftData`) は次の段階。
> - Gmail は「すべてのメール」「迷惑メール」「ゴミ箱」だけを同期し、受信トレイなどの区別はラベルで決める (二重に出ない)。
> - SPECIAL-USE のないサーバー (Yahoo! など) は、フォルダ名 (Sent / Draft / Bulk Mail / 送信済み など) から役割を推し量る。
> - 受信トレイの未読数は、同期のたびにサーバーに直接聞く (`STATUS (UNSEEN)`)。保存外の古い未読も含めて、サーバーの数と一致する。
> - 画面への窓口 `LiveMailRepository` も作成済み (テスト 8 件)。仮データの `PreviewMailRepository` と差し替えて使う (T11)。
> - **未解決:** 一覧の書き出し (preview) は空のまま。本文を取る T14 で埋める。

**説明:** `MailStore` に `MessageStore` プロトコル、メモリ上の実装、同期処理を作る。同期処理は、初回に 30 日分の見出しを取り、2 回目以降は新しい UID だけを取ってフラグをまとめて確認する。`UIDVALIDITY` が変わったら取り直す。Gmail の同じメールは `X-GM-MSGID` で 1 通にまとめる。SwiftData の実装 (`MailStoreSwiftData`) も作る。

**受け入れ条件:**
- [x] 偽の IMAP サーバー相手に、初回の同期・新着・削除・フラグ変更・`UIDVALIDITY` の変化を正しく扱える
- [x] Gmail で「受信トレイ」と「スター付き」の両方にあるメールが、統合受信トレイに 1 通だけ出る
- [x] 未読数がサーバー側の数と一致する (受信トレイ。`STATUS (UNSEEN)`)

**確認:**
- [ ] 🐧 `swift test --package-path Packages/MailStore`

**依存:** T7, T8
**触るファイル:** `Packages/MailStore/Sources/MailStore/MessageStore.swift`、`InMemoryMessageStore.swift`、`SyncEngine.swift`、`Sources/MailStoreSwiftData/SwiftDataMessageStore.swift`、`Tests/MailStoreTests/SyncEngineTests.swift`
**大きさ:** L → 着手時に「同期処理」と「SwiftData の実装」の 2 つに分ける

### T11: Yahoo! アカウントを追加すると、本物のメールが一覧に出る

> 状態 (2026-11-13): ✅ アカウント管理 (`AccountDirectory`、テスト 11 件)、画面 (追加シート、設定のアカウント一覧、受信ボタン) ともに済。CI の macOS でビルドとテストが通過。**オーナーの Mac で、実際の Gmail アカウントを追加し、本物のメールが一覧に出ることを確認** (2026-11-13)。保存先はまだメモリ上 (起動のたびに 30 日分を取り直す)

**説明:** アカウント追加の画面を作る (メールアドレス、アプリパスワード、表示名、色)。Yahoo!、iCloud、Outlook のサーバー設定は自動で入れる。追加したら接続を確かめ、同期を始め、T5 の一覧に本物のメールが出るようにする (仮の `MailRepository` を本物に差し替える)。

**受け入れ条件:**
- [ ] メールアドレスとアプリパスワードを入れるだけで追加できる (US-2)
- [ ] パスワードが違うときは、何が悪いか分かる文で知らせる
- [ ] 追加したアカウントのメールが統合受信トレイに出る (US-3)
- [ ] アカウントを削除すると、そのメールとパスワードも消える

**確認:**
- [ ] 🐧 サーバー設定の自動入力のテスト
- [ ] 🍎 Yahoo! アカウントを追加して、受信トレイが Web 版と同じ件数・同じ未読数になる

**依存:** T6, T10
**触るファイル:** `App/Features/Accounts/AddAccountView.swift`、`App/Features/Accounts/AccountsSettings.swift`、`Packages/AccountKit/Sources/AccountKit/ProviderPresets.swift`、`Packages/MailStore/Sources/MailStore/LiveMailRepository.swift`
**大きさ:** M

### T12: Gmail アカウントを追加すると、本物のメールが一覧に出る

> 状態 (2026-11-13): ✅ T11 と同じ画面で、Gmail (Google Workspace を含む) もアプリパスワードで追加できる。オーナーの Mac で Gmail の追加と一覧の表示を確認済み。残りの 2 アカウントと Yahoo! は未確認

**説明:** T11 のアカウント追加の画面で、Gmail をアプリパスワードで追加できるようにする (サーバー設定 `imap.gmail.com` / `smtp.gmail.com` を自動で入れる。ラベルなど Gmail 特有の扱いを有効にする)。3 つ追加しても、それぞれ別のアカウントとして扱う。「Google でログイン」(T9 の OAuth) は P2 に回した (SPEC 11 章)。

**受け入れ条件:**
- [ ] メールアドレスとアプリパスワードを入れると、30 秒以内に受信トレイが出る (US-1)
- [ ] Gmail 3 アカウントと Yahoo! 1 アカウントのメールが、統合受信トレイに混ざって新しい順に出る

**確認:**
- [ ] 🍎 Gmail 3 アカウントを追加して、それぞれの未読数が Web 版と一致する

**依存:** T11
**触るファイル:** `App/Features/Accounts/AddAccountView.swift`、`Packages/AccountKit/Sources/AccountKit/ProviderPresets.swift`、`Packages/MailStore/Sources/MailStore/LiveMailRepository.swift`
**大きさ:** S

### T13: フォルダとラベルで絞り込める

**説明:** IMAP の `SPECIAL-USE` で、受信トレイ・送信済み・下書き・アーカイブ・迷惑メール・ゴミ箱を見分け、サイドバーのフォルダに対応させる。Gmail のラベルは、アカウントの下にフォルダとして出す。スター付き・未読は全アカウントをまとめた仮想フォルダにする。

**受け入れ条件:**
- [ ] サイドバーの各フォルダを選ぶと、全アカウント分のそのフォルダのメールが出る (US-4)
- [ ] アカウントを選ぶと、そのアカウントのフォルダとラベルだけが出る
- [ ] Gmail の「すべてのメール」がアーカイブとして扱われる

**確認:**
- [ ] 🐧 `SPECIAL-USE` の判定と、Gmail のラベルの扱いのテスト
- [ ] 🍎 各フォルダの件数が Web 版と一致する

**依存:** T12
**触るファイル:** `Packages/MailStore/Sources/MailStore/MailboxRole.swift`、`SyncEngine.swift`、`App/Features/Inbox/SidebarView.swift`、`Tests/MailStoreTests/MailboxRoleTests.swift`
**大きさ:** M

### ✅ チェックポイント: 受信
- [ ] 🍎 4 アカウントの受信トレイが統合受信トレイに出て、未読数がサーバーと一致する
- [ ] 🐧 すべてのパッケージのテストが通る
- [ ] **オーナーと確認してから次に進む**

### T14: 本文を開いて読める

> 状態 (2026-11-13): 🐧 本文の取得 (`BODY.PEEK[]`、既読にしない)・保存・組み立て (HTML の埋め込み画像は data: URL に置き換え) はテスト済み。画面 (安全な WebView、外部画像のブロックと「画像を表示」、添付のプレビューと保存) は CI の macOS で確認中 / 🍎 実メールでの確認待ち。
> - 安全策: JavaScript は WebView の設定と Content-Security-Policy の二重で止める。外部の画像・スタイル・フォントは押すまで読み込まない。リンクはふだんのブラウザで開く。Cookie は残さない。
> - 本文は 1 通ごとにサーバーへ接続して取る (少し時間がかかる)。接続の使い回しは後で改善する。

**説明:** メールを開いたときに本文を取得して、T8 の解析器で分ける。HTML は JavaScript を止めた `WKWebView` で表示し、外部画像は「画像を表示」を押すまで読み込まない。添付ファイルは Quick Look でプレビューし、保存・Finder へのドラッグができるようにする。取得した本文は保存し、2 回目からは通信しない。

**受け入れ条件:**
- [ ] HTML メールが崩れずに表示され、スクリプトは動かない (US-5)
- [ ] 外部画像は押すまで読み込まない
- [ ] 添付ファイルをプレビュー・保存できる

**確認:**
- [ ] 🐧 本文の取得と保存のテスト
- [ ] 🍎 ニュースレター、日本語のメール、添付つきのメールをそれぞれ開いて確認する

**依存:** T13
**触るファイル:** `App/Features/Reader/HTMLBodyView.swift`、`App/Features/Reader/ReaderView.swift`、`App/Features/Reader/AttachmentCard.swift`、`Packages/MailStore/Sources/MailStore/SyncEngine.swift`
**大きさ:** M

### T15: 既読・スター・アーカイブ・削除・迷惑メール

**説明:** ツールバーのボタンと右クリックメニューから、既読/未読、スター、フラグ、アーカイブ、削除、迷惑メールができるようにする。画面にはすぐ反映し、裏でサーバーに送る (失敗したら元に戻して知らせる)。Gmail では、アーカイブ = 受信トレイのラベルを外す、削除 = ゴミ箱へ移す、として扱う。

**受け入れ条件:**
- [ ] 操作が 0.1 秒以内に画面に反映される (US-7)
- [ ] 1 分以内に Gmail / Yahoo! の Web 画面にも反映される
- [ ] 失敗したら元の状態に戻り、知らせが出る

**確認:**
- [ ] 🐧 偽の IMAP サーバー相手に、各操作で正しい命令が送られるテスト (Gmail とそれ以外の両方)
- [ ] 🍎 Gmail と Yahoo! で各操作をして、Web 画面で確認する

**依存:** T14
**触るファイル:** `Packages/MailStore/Sources/MailStore/MessageActions.swift`、`Packages/MailCore/Sources/MailCore/IMAP/IMAPSession.swift`、`App/Features/Reader/ReaderToolbar.swift`、`App/Features/Inbox/MessageRow.swift`、`Tests/MailStoreTests/MessageActionsTests.swift`
**大きさ:** M

### T16: キーボード操作とメニュー

**説明:** SPEC の US-8 のショートカットと、メニューバーの「メッセージ」メニューを作る。

**受け入れ条件:**
- [ ] US-8 のショートカットがすべて動き、メニューにも項目がある
- [ ] `↑` `↓` で前後のメールに移り、本文が切り替わる

**確認:**
- [ ] 🍎 マウスを使わずに、メールを 10 通読んでアーカイブまでできる

**依存:** T15
**触るファイル:** `App/CozyMailApp.swift`、`App/Features/Inbox/MessageCommands.swift`
**大きさ:** S

### T17: SMTP 送信と、送信用のメールの組み立て

**説明:** `MailCore` に SMTP クライアント (TLS、ログイン、XOAUTH2) と、送信用のメールの組み立て (日本語の件名、本文、添付、返信のための `In-Reply-To` / `References`) を作る。

**受け入れ条件:**
- [ ] 偽の SMTP サーバー相手のテストで送信が通る
- [ ] 組み立てたメールを T8 の解析器で読むと、元の内容に戻る
- [ ] 暗号化なしの接続はできない

**確認:**
- [ ] 🐧 `swift test --package-path Packages/MailCore`
- [ ] 🍎 `cozymail-probe send` で、オーナー自身のアドレスにテストメールが届く

**依存:** T8, T9
**触るファイル:** `Sources/MailCore/SMTP/SMTPSession.swift`、`Sources/MailCore/MIME/MIMEBuilder.swift`、`Tests/MailCoreTests/SMTPSessionTests.swift`、`Tests/MailCoreTests/MIMEBuilderTests.swift`
**大きさ:** M

### T18: 新規作成・返信・全員に返信・転送のウィンドウ

**説明:** 作成ウィンドウ (宛先 To/Cc/Bcc、件名、本文、添付、差出人のアカウント選び) を作る。返信・全員に返信・転送では宛先と件名を自動で入れ、元のメールを引用する。送信後、Gmail 以外は「送信済み」フォルダに `APPEND` する。

**受け入れ条件:**
- [ ] どのアカウントからも送れて、相手に届く (US-6)
- [ ] 返信は、受け取ったアカウントから送られる
- [ ] 送ったメールがそのアカウントの「送信済み」に 1 通だけ入る

**確認:**
- [ ] 🐧 返信・全員に返信の宛先の組み立てのテスト
- [ ] 🍎 各アカウントから自分宛てに送って、届くことと「送信済み」を確認する

**依存:** T16, T17
**触るファイル:** `App/Features/Compose/ComposeWindow.swift`、`App/Features/Compose/RecipientField.swift`、`Packages/MailStore/Sources/MailStore/Composer.swift`、`Tests/MailStoreTests/ComposerTests.swift`
**大きさ:** M

### T19: Mac 内の検索

**説明:** ツールバーの検索欄から、保存済みのメールを差出人・件名・本文で検索する。オフラインでも使える。

**受け入れ条件:**
- [ ] 1 万通の中から、1 秒以内に結果が出る (US-10)
- [ ] 日本語の部分一致で見つかる

**確認:**
- [ ] 🐧 検索のテスト (日本語を含む)
- [ ] 🍎 実際のアカウントで検索する

**依存:** T14
**触るファイル:** `Packages/MailStore/Sources/MailStore/Search.swift`、`App/Features/Inbox/SearchField.swift`、`Tests/MailStoreTests/SearchTests.swift`
**大きさ:** S

### ✅ チェックポイント v0.1
- [ ] 🍎 SPEC の P0 のユーザーストーリー (US-1〜US-11) の受け入れ条件を、実際の 4 アカウントで確認する
- [ ] 🍎 `docs/manual-test.md` (このチェックポイントで作る) の手順をすべて通す
- [ ] 🐧 すべてのパッケージのテストが通る
- [ ] **オーナーと確認して、フェーズ 4 を細かく決め直す**

---

## フェーズ 4: v1.0 毎日使える (v0.1 のあとで細かく決め直す)

| ID | タスク | US | 依存 |
|---|---|---|---|
| T20 | IMAP IDLE で新着をすぐ受け取り、Mac の通知と Dock の未読数を出す。スリープから戻ったら 1 分以内に再開する | US-12 | T15 |
| T21 | メニューバー常駐 (`MenuBarExtra`) と、ログイン時の起動 (`SMAppService`) | US-12 | T20 |
| T22 | オフラインの待ち行列。オフライン中の操作を、つながったらサーバーに送る | US-13 | T15 |
| T23 | 下書きの自動保存と、サーバーの下書きフォルダへの保存 | US-14 | T18 |
| T24 | 送信の取り消し (5〜30 秒) | US-15 | T18 |
| T25 | アカウントごとの署名 | US-16 | T18 |
| T26 | 複数のメールを選んでまとめて操作 | US-17 | T15 |
| T27 | サーバー側の検索 (Gmail は `X-GM-RAW`) | US-10 | T19 |
| T28 | IMAP / SMTP のサーバー設定を手で入れる (独自ドメイン用) | US-2 | T11 |
| T29 (P2) | Gmail の「Google でログイン」。ホームページとプライバシーポリシーの URL を用意して (例: GitHub Pages)、Google Cloud を「本番環境」にする | US-1 | T9, T12 |

### ✅ チェックポイント v1.0
- [ ] 🍎 SPEC の成功の条件 (10 章) をすべて満たす
- [ ] 🍎 オーナーが 2 週間、ほかのメールアプリやブラウザの Gmail を使わずに過ごせる
