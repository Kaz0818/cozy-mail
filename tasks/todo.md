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
- [x] 🍎 アプリを起動して、空のウィンドウが出る (オーナーの Mac で起動して使用中)

**依存:** なし
**触るファイル:** `project.yml`、`App/CozyMailApp.swift`、`Packages/*/Package.swift`、`Packages/*/Tests/*`、`.gitignore`、`.swiftformat`、`.swiftlint.yml`、`Local.xcconfig.sample`
**大きさ:** M (ファイル数は多いが、どれも中身は小さい)

### T2: 色のトークン、背景、テーマの切り替え

> 状態: ✅ 済 (CI の macOS でビルドとコントラストのテストが通過、2026-11-13 オーナーが Mac で確認)。`accent` (ライト) と `accentFill` (ダーク) は AA を満たさなかったので濃くした (SPEC 8.2 も更新)

**説明:** SPEC 8.2 の色をトークンとして定義し、ティファニーブルーの波の背景 (ライト用・ダーク用) と、ガラスの部品 (カプセル形のボタン、色付きガラスの行) を作る。設定で「ライト / ダーク / システムに合わせる」を切り替えられるようにする。

**受け入れ条件:**
- [x] 画面のコードに色の値を直接書かず、すべてトークン経由になっている (2026-11-13 確認: `App/DesignSystem` の外に色の値なし)
- [x] テーマの切り替えが、アプリを再起動せずにすぐ反映される (US-11) (2026-11-13 オーナーが Mac で確認)
- [x] 「透明度を下げる」が有効なとき、ガラスの代わりに不透明な面になる (2026-11-13 オーナーが Mac で確認)

**確認:**
- [x] 🍎 SwiftUI プレビューで、ライト/ダーク × 透明度を下げる の 4 通りを見る (プレビューの代わりに、アプリの設定とシステム設定で確認。2026-11-13 オーナー)
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

> 状態: ✅ CI の macOS でビルドと `InboxModel` のテストが通過 / 🍎 2026-11-13 オーナーがライト・ダークの画面で確認し、デザインを直した

**説明:** 3 列の `NavigationSplitView` を作り、左の列に、アプリ名、アカウント一覧 (未読数つき)、統合受信トレイ、フォルダ一覧、アカウント追加ボタン (押しても何もしない) を出す。データは T3 の仮の実装から取る。

**受け入れ条件:**
- [x] 見本と同じ並びで、アカウントとフォルダが出る (`InboxModelTests`)
- [x] 項目を選ぶと選択中の見た目 (色付きガラス) になる
- [x] 未読数がアカウント別・フォルダ別に出る (US-9 の見た目) (`InboxModelTests`)

**確認:**
- [x] 🍎 アプリを起動して、見本の左の列と並べて比べる (ライト/ダーク) (2026-11-13 オーナーがライト・ダークの画面で確認し、デザインを直した)

**依存:** T2, T3
**触るファイル:** `App/Features/Inbox/MainWindow.swift`、`App/Features/Inbox/SidebarView.swift`、`App/Features/Inbox/SidebarRow.swift`
**大きさ:** S

### T5: メール一覧と絞り込みタブ

> 状態: ✅ CI の macOS でビルドと `InboxModel` のテストが通過 / 🍎 2026-11-13 オーナーがライト・ダークの画面で確認し、デザインを直した

**説明:** 真ん中の列に、見出し (「受信トレイ」「すべてのアカウント・22 件の未読」)、新規作成ボタン、「すべて / 未読 / スター付き」のタブ、メールの行 (差出人のアイコン、名前、件名、書き出し、時刻、未読の点、スター) を出す。

**受け入れ条件:**
- [x] サイドバーで選んだアカウント・フォルダに合わせて、一覧が切り替わる (US-4) (`InboxModelTests`)
- [x] タブで絞り込める (`InboxModelTests`)
- [x] 未読のメールは点と太字の両方で分かる

**確認:**
- [x] 🍎 見本の真ん中の列と並べて比べる (ライト/ダーク) (2026-11-13 オーナーが確認)
- [x] 🍎 タブとサイドバーを切り替えて、一覧が変わる (オーナーの Mac で使用中)

**依存:** T4
**触るファイル:** `App/Features/Inbox/MessageListView.swift`、`App/Features/Inbox/MessageRow.swift`、`App/Features/Inbox/FilterTabs.swift`、`App/DesignSystem/AvatarView.swift`
**大きさ:** M

### T6: 本文の列とツールバー

> 状態: ✅ CI の macOS でビルドと `InboxModel` のテストが通過 / 🍎 2026-11-13 オーナーがライト・ダークの画面で確認し、デザインを直した

**説明:** 右の列に、ツールバー (返信・全員に返信・削除・アーカイブ・フラグ・その他・検索欄)、件名、差出人、宛先、日時、本文 (このタスクではプレーンテキストだけ)、添付ファイルのカードを出す。ボタンは押しても何もしない。

**受け入れ条件:**
- [x] 一覧でメールを選ぶと、右の列にそのメールが出る (CI の画面テスト `testClickingARowSelectsIt`)
- [x] ツールバーのボタンと検索欄がガラスの見た目になっている
- [x] ウィンドウを 1000pt まで狭めても崩れない (2026-11-13 オーナーと決定: 900pt から 1000pt に変更。3 列を保つため。もっと狭く使うときは「サイドバーを隠す」を後で足す)

**確認:**
- [x] 🍎 見本の右の列と並べて比べる (ライト/ダーク) (2026-11-13 オーナーが確認)

**依存:** T5
**触るファイル:** `App/Features/Reader/ReaderView.swift`、`App/Features/Reader/ReaderHeader.swift`、`App/Features/Reader/AttachmentCard.swift`、`App/Features/Reader/ReaderToolbar.swift`
**大きさ:** M

### ✅ チェックポイント v0.0
- [x] 🍎 アプリの画面を見本の 2 枚と並べて、オーナーが「ほぼ同じ」と判断する (2026-11-14 オーナーが Mac で確認。docs/manual-test.md の 7)
- [x] 🍎 ライト / ダーク / システムに合わせる が切り替わる (2026-11-13 オーナーが Mac で確認)
- [x] 🐧 すべてのパッケージのテストが通る (CI で通過)
- [x] **オーナーと確認してから次に進む** (2026-11-14 オーナーが Mac で確認)

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
- [x] 🐧 すべてのパッケージのテストが通る (CI で通過)
- [x] `swift-nio-imap` を使い続けるか、オーナーと確認する — 実際の Gmail で動いたので使い続ける (0.4.x に固定。0.5.0 は API が変わったので、上げるときは別の作業)

---

## フェーズ 3: v0.1 実際に使える

### T10: 保存と同期

> 状態 (2026-11-14): 🐧 **同期処理、メモリ上の保存先、SwiftData の保存先 (`SwiftDataMessageStore`) は済**。アプリの保存先は SwiftData に差し替えた (開けないときだけメモリ上に切り替わる)。Mac の `xcodebuild test -scheme MailStore-Package` で全 113 件が通過 (うち SwiftData のテスト 17 件)。アプリのテストは単体 59 件 + UI 6 件。メールがたまると画面が重くなる問題も直した (下)。**残り:** 🍎 オーナーの確認。
> - Gmail は「すべてのメール」「迷惑メール」「ゴミ箱」だけを同期し、受信トレイなどの区別はラベルで決める (二重に出ない)。
> - SPECIAL-USE のないサーバー (Yahoo! など) は、フォルダ名 (Sent / Draft / Bulk Mail / 送信済み など) から役割を推し量る。
> - 受信トレイの未読数は、同期のたびにサーバーに直接聞く (`STATUS (UNSEEN)`)。保存外の古い未読も含めて、サーバーの数と一致する。
> - 画面への窓口 `LiveMailRepository` も作成済み (テスト 8 件)。仮データの `PreviewMailRepository` と差し替えて使う (T11)。
> - ~~**未解決:** 一覧の書き出し (preview) は空のまま~~ → T14 で、本文を初めて開いたときに埋めるようにした。
> - 2026-11-14: ファイルで保存する案と比べ、オーナーが **SwiftData** を選んだ (古いメールも何年分も Mac に置けるように)。SwiftData のテストは Mac でしか動かないので、オーナーの Mac (ローカル) で作った。
>   ファイルで保存する案は、参考のブランチ `claude/file-message-store` に残してある (マージしない。テスト 10 件は `SwiftDataMessageStoreTests` に流用した)。
> - **SwiftData での保存:** 見出し (`MailRecord`、索引つき)、本文の生データ (`RawMessageRecord`、大きいものはデータベースの外のファイル)、同期の進み具合、アカウントごとの未読数とフォルダ名を保存する。アプリを終了しても残り、次の起動は前回の一覧がすぐ出て、受信は新着だけで済む。モデルは `MailSchemaV1` で、形を変えるときは `MailSchemaV2` と移行の手順を足す。
> - **何年分も置く:** 5 年分 (3 アカウント・6,000 通) を保存して開き直すテストが通る。
> - ~~**未解決:** たまると画面が重くなる~~ → 2026-11-14 に直した (オーナーの承認を得て `MessageStore` に操作を足した)。
>   前は `LiveMailRepository` が一覧と未読数 (約 11 か所) のたびに `allSummaries()` で全件を読み直していた。いまは、フォルダ・絞り込み・アカウントの条件 (`MessageQuery`) を保存先に渡し、SwiftData はデータベースの中で絞り込んで並べる (`summaries(matching:)`)、未読は数だけを聞く (`unreadCount(matching:)`)。SwiftData のモデルは変えていない。
>   画面の更新 1 回 (一覧 + 未読数 11 か所、全部が受信トレイにある場合): 1,000 通 0.4 秒 → 0.04 秒、1 万通 4 秒 → 0.38 秒、3 万通 12 秒 → 1.3 秒。
>   残る時間は、開いたフォルダの一覧を全部読み込む分 (3 万通で約 1 秒)。1 つのフォルダに何万通もためる使い方で気になったら、一覧を少しずつ読み込む形 (スクロールに合わせて続きを読む) にする。画面の作りが変わるので、そのときにオーナーと相談する。
> - **注意:** 同期は初回に最近 30 日分だけを取る (SPEC 6.2)。それより古いメールは取りに行かないので、Mac にたまるのは使い始めてから先のメール。
> - **起動直後の一覧:** 受信がキーチェーンの確認 (アプリを作り直すたびに出る) で止まっていても、保存してあるメールはすぐ出るようにした (`MailServiceStartupTests`)。前は確認に答えるまで画面が空だった。
> - **テストが本物のデータに触れない:** アプリの単体テストも、アプリの中で動くときはメモリ上だけで動くようにした (`LaunchModeTests`)。前は単体テストのたびに本物のアカウントで受信していた。
> - **保存ファイルが壊れたとき:** 開けないとアプリはメモリ上の保存先に切り替わり、その起動では毎回 30 日分を取り直す。壊れたファイルの自動修復はまだない。
> - Linux の CI では SwiftData のテストは空になるので、macOS の CI に `xcodebuild test` を足した。

**説明:** `MailStore` に `MessageStore` プロトコル、メモリ上の実装、同期処理を作る。同期処理は、初回に 30 日分の見出しを取り、2 回目以降は新しい UID だけを取ってフラグをまとめて確認する。`UIDVALIDITY` が変わったら取り直す。Gmail の同じメールは `X-GM-MSGID` で 1 通にまとめる。SwiftData の実装 (`MailStoreSwiftData`) も作る。古いメールも何年分も Mac に置けるようにする。

**受け入れ条件:**
- [x] 偽の IMAP サーバー相手に、初回の同期・新着・削除・フラグ変更・`UIDVALIDITY` の変化を正しく扱える
- [x] Gmail で「受信トレイ」と「スター付き」の両方にあるメールが、統合受信トレイに 1 通だけ出る
- [x] 未読数がサーバー側の数と一致する (受信トレイ。`STATUS (UNSEEN)`)
- [x] アプリを終了して開き直しても、メール・同期の進み具合・未読数・本文が残り、開き直したあとは新着だけを受信する (`SwiftDataMessageStoreTests`)
- [x] 何年分 (5 年・6,000 通) 置いても、フォルダごとの取り出しと件数が合う (`yearsOfMailStayQueryable`)
- [x] 何年分たまっても、画面がもたつかない — 1 万通で画面の更新 0.38 秒 (前は 4 秒)。一覧と未読数が画面の決まりと同じになることは `MessageQueryTests` で、すべてのフォルダと絞り込みの組み合わせを確かめている
- [x] メールやアカウントを消すと、ディスク上の本文のファイルも消える (`deletingRemovesBodyFilesFromDisk`)

**確認:**
- [x] 🐧 `swift test --package-path Packages/MailStore` (2026-11-13 時点で 87 件すべて通過。SwiftData のテストは Linux では空)
- [x] 🐧 `cd Packages/MailStore && xcodebuild test -scheme MailStore-Package -destination 'platform=macOS'` (Mac で実行。2026-11-14 に 113 件すべて通過)
- [x] 🐧 `xcodebuild test -scheme CozyMail -destination 'platform=macOS'` (2026-11-14 に単体 59 件 + UI 6 件すべて通過。重さの修正のあとも、単体 59 件 + UI 6 件すべて通過)
- [x] 🍎 アプリを閉じて開き直すと、前回の一覧がすぐ出て、開いたことのあるメールは本文も出る (2026-11-14 オーナーが Mac で確認)

**依存:** T7, T8
**触るファイル:** `Packages/MailStore/Sources/MailStore/MessageStore.swift` (メモリ上の実装 `InMemoryMessageStore` もここ)、`SyncEngine.swift`、`LiveMailRepository.swift`、`Sources/MailStoreSwiftData/SwiftDataMessageStore.swift`、`Package.swift`、`App/Services/MailService.swift`、`App/CozyMailApp.swift`、`project.yml`、`Tests/MailStoreTests/SyncEngineTests.swift`、`Tests/MailStoreTests/SwiftDataMessageStoreTests.swift`、`Tests/MailStoreTests/MessageQueryTests.swift`、`AppTests/MailServiceStartupTests.swift`、`AppTests/CozyMailAppTests.swift`
**大きさ:** L → 「同期処理」と「SwiftData の実装」の 2 つに分けて進めた (どちらも済)

### T11: Yahoo! アカウントを追加すると、本物のメールが一覧に出る

> 状態 (2026-11-13): ✅ アカウント管理 (`AccountDirectory`、テスト 11 件)、画面 (追加シート、設定のアカウント一覧、受信ボタン) ともに済。CI の macOS でビルドとテストが通過。**オーナーの Mac で、実際の Gmail アカウントを追加し、本物のメールが一覧に出ることを確認** (2026-11-13)。保存先は 2026-11-14 に SwiftData に替えた (T10)。この確認は保存先がメモリ上だったときのもの

**説明:** アカウント追加の画面を作る (メールアドレス、アプリパスワード、表示名、色)。Yahoo!、iCloud、Outlook のサーバー設定は自動で入れる。追加したら接続を確かめ、同期を始め、T5 の一覧に本物のメールが出るようにする (仮の `MailRepository` を本物に差し替える)。

**受け入れ条件:**
- [x] メールアドレスとアプリパスワードを入れるだけで追加できる (US-2) (Gmail で同じ画面を使って確認。Yahoo! は自動判定のテストのみ)
- [x] パスワードが違うときは、何が悪いか分かる文で知らせる (`AccountErrorMessageTests`、`wrongPasswordSavesNothing`)
- [x] 追加したアカウントのメールが統合受信トレイに出る (US-3) (オーナーの Mac で Gmail を確認)
- [x] アカウントを削除すると、そのメールとパスワードも消える (`removingAnAccountDeletesItsPasswordAndMail`)

**確認:**
- [x] 🐧 サーバー設定の自動入力のテスト (`automaticChoiceRecognisesCommonDomains` ほか)
- [x] 🍎 Yahoo! アカウントを追加して、受信トレイが Web 版と同じ件数・同じ未読数になる (Yahoo! のアドレスはないため、Gmail 以外のアカウントで代わりに確認。2026-11-13 オーナー)

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
- [x] 🍎 Gmail 3 アカウントを追加して、それぞれの未読数が Web 版と一致する (2026-11-13 オーナーが Mac で確認)

**依存:** T11
**触るファイル:** `App/Features/Accounts/AddAccountView.swift`、`Packages/AccountKit/Sources/AccountKit/ProviderPresets.swift`、`Packages/MailStore/Sources/MailStore/LiveMailRepository.swift`
**大きさ:** S

### T13: フォルダとラベルで絞り込める

> 状態 (2026-11-14): ✅ (PR #11 マージ済み、オーナーが Mac で確認) アカウントを選ぶと、そのアカウントの Gmail のラベル (自分で作ったもの) がサイドバーの「ラベル」に出て、選ぶとそのラベルのメールが出る。オーナーが実アカウントで確認済み。
> - ラベルの一覧は、同期のたびに Gmail のフォルダの一覧 (LIST) から覚え直す。`INBOX`、`[Gmail]/...` (`[Google Mail]/...`)、役割の決まったフォルダ、入れ物だけのフォルダは入れない。Gmail で消したラベルは次の同期で消える。
> - ラベルを開くと、そのラベルが付いたメールが出る。Gmail の Web 版と同じく、迷惑メールとゴミ箱のメールは出さない。「仕事」と「仕事/経理」は別のラベルとして扱い、入れ子は「仕事/経理」のように 1 行で並べる。ラベルごとに未読数を出す。
> - 開いていたラベルが Gmail で消されたら、そのアカウントの受信トレイに戻る。
> - **SwiftData のモデルを第 2 版にした** (2026-11-14 オーナー承認、案 A)。メールごとのラベルをデータベースで探せる形 (`labelKey`) と、アカウントごとのラベルの一覧 (`labelNames`) を足した。第 1 版で保存したメールは捨てずに移す (`MailMigrationPlan`、`mailSavedInTheFirstVersionIsKeptAndCanBeFoundByLabel`)。オーナーの Mac の保存ファイルも移った (212 通のまま。移す前の写しを `Mail-backup-v1-2026-11-14` に残した)。
> - Gmail 以外のアカウントの、自分で作ったフォルダは、まだ扱わない (同期していない。Yahoo! などのアカウントがなく確かめられないため)。

**説明:** IMAP の `SPECIAL-USE` で、受信トレイ・送信済み・下書き・アーカイブ・迷惑メール・ゴミ箱を見分け、サイドバーのフォルダに対応させる。Gmail のラベルは、アカウントの下にフォルダとして出す。スター付き・未読は全アカウントをまとめた仮想フォルダにする。

**受け入れ条件:**
- [x] サイドバーの各フォルダを選ぶと、全アカウント分のそのフォルダのメールが出る (US-4) (`filtersAndOtherFolders`)
- [x] アカウントを選ぶと、そのアカウントのフォルダとラベルだけが出る (`labelsAppearOnlyWhileAnAccountIsSelected`、`selectingALabelShowsThatAccountsMailWithTheLabel`) — Gmail のラベルのみ。Gmail 以外の自分で作ったフォルダはまだ
- [x] Gmail の「すべてのメール」がアーカイブとして扱われる (`gmailRolesComeFromLabelsSoNothingIsDuplicated`)

**確認:**
- [x] 🐧 `SPECIAL-USE` の判定と、Gmail のラベルの扱いのテスト (`specialUseWinsOverNames`、`foldersWithoutSpecialUseAreRecognisedByName`、`gmailLabelChangesMoveMessagesBetweenFolders`)
- [x] 🐧 ラベルの一覧と絞り込み (`gmailRemembersTheLabelsYouMade`、`gmailLabelListFollowsTheServer`、`MessageQueryTests`、`AccountLabelsTests`、`labelsSurviveReopening`)。Mac で MailStore 120 件、アプリ 62 件 + UI 6 件すべて通過 (2026-11-14)
- [x] 🍎 各フォルダの件数が Web 版と一致する (2026-11-14 オーナーが Mac で確認)
- [x] 🍎 Gmail のアカウントを選ぶと、自分で作ったラベルが出て、選ぶと Web 版のそのラベルと同じメールが出る (最近 30 日より前のメールは保存していないので、その分は出ない) (2026-11-14 オーナーが Mac で確認)

**依存:** T12
**触るファイル:** `Packages/MailStore/Sources/MailStore/Models.swift`、`MailRepository.swift`、`MessageStore.swift`、`LiveMailRepository.swift`、`SyncEngine.swift`、`Sources/MailStoreSwiftData/SwiftDataMessageStore.swift`、`App/Features/Inbox/InboxModel.swift`、`App/Features/Inbox/SidebarView.swift`、`Tests/MailStoreTests/SyncEngineTests.swift`、`MessageQueryTests.swift`、`AccountLabelsTests.swift`、`SwiftDataMessageStoreTests.swift`、`AppTests/InboxModelLabelTests.swift`
**大きさ:** M

### ✅ チェックポイント: 受信
- [x] 🍎 4 アカウントの受信トレイが統合受信トレイに出て、未読数がサーバーと一致する (2026-11-14 オーナーが Mac で確認。Gmail 3 アカウントで。Yahoo! はアドレスがないため、持ったときに)
- [x] 🐧 すべてのパッケージのテストが通る (CI で通過)
- [x] **オーナーと確認してから次に進む** (2026-11-14 オーナーが Mac で確認)

### T14: 本文を開いて読める

> 状態 (2026-11-13): ✅ 本文の取得 (`BODY.PEEK[]`、既読にしない)・保存・組み立て (HTML の埋め込み画像は data: URL に置き換え) はテスト済み。画面 (安全な WebView、外部画像のブロックと「画像を表示」、添付のプレビューと保存) は CI の macOS でビルドとテストが通過。**オーナーの Mac で、実メールの差出人・宛先・本文の表示、添付 PDF のプレビューと保存 (中身も正しい) を確認** (2026-11-13)。保存ボタンが最初は反応しなかった (`NSSavePanel.runModal()` を Task の中から呼んでいた) ので、SwiftUI の `fileExporter` に直した。
> - 安全策: JavaScript は WebView の設定と Content-Security-Policy の二重で止める。外部の画像・スタイル・フォントは押すまで読み込まない。リンクはふだんのブラウザで開く。Cookie は残さない。
> - 本文は 1 通ごとにサーバーへ接続して取る (少し時間がかかる)。接続の使い回しは後で改善する。

**説明:** メールを開いたときに本文を取得して、T8 の解析器で分ける。HTML は JavaScript を止めた `WKWebView` で表示し、外部画像は「画像を表示」を押すまで読み込まない。添付ファイルは Quick Look でプレビューし、保存・Finder へのドラッグができるようにする。取得した本文は保存し、2 回目からは通信しない。

**受け入れ条件:**
- [x] HTML メールが崩れずに表示され、スクリプトは動かない (US-5) (スクリプトは止めてある: `SafeHTMLTests`。オーナーが実際のメールを開いて確認)
- [x] 外部画像は押すまで読み込まない (`SafeHTMLTests`)
- [x] 添付ファイルをプレビュー・保存できる (2026-11-13 オーナーが PDF のプレビューと保存を確認)

**確認:**
- [x] 🐧 本文の取得と保存のテスト (`bodyIsFetchedOnceThenServedFromTheStore` ほか)
- [x] 🍎 ニュースレター、日本語のメール、添付つきのメールをそれぞれ開いて確認する (2026-11-13 オーナーが Mac で確認)

**依存:** T13
**触るファイル:** `App/Features/Reader/HTMLBodyView.swift`、`App/Features/Reader/ReaderView.swift`、`App/Features/Reader/AttachmentCard.swift`、`Packages/MailStore/Sources/MailStore/SyncEngine.swift`
**大きさ:** M

### T15: 既読・スター・アーカイブ・削除・迷惑メール

> 状態 (2026-11-13): 🐧 IMAP の命令 (フラグ・Gmail ラベル・移動、MOVE がなければ COPY+UIDPLUS、UIDPLUS もなければ EXPUNGE しない)、保存先の先行反映と失敗時の巻き戻し、未読数の調整はテスト済み。画面 (ツールバー、ヘッダーのスター、行の右クリックメニュー、開いたら既読) も済み。✅ 2026-11-13 オーナーが実アカウントで確認。
> - 「未読」で絞っているときに開いたメールを既読にしても、一覧を読み直さない (読み直すと次のメールが選ばれて既読になり、連鎖して全部既読になるため)。テストで確かめている。
> - ゴミ箱のメールの完全削除は、まだできない (P1 で検討)。
> - 削除の確認画面は付けない (2026-11-13 決定)。ゴミ箱に移すだけで戻せるため (Gmail・Apple のメールと同じ)。代わりに、操作の直後に「元に戻す」を出す (T26 と合わせて P1)。
> - 行の右クリックメニューが出なかった (行を `Button` にしていたため) ので、クリックと右クリックを別々に受ける作りに直した。
> - それでもオーナーの Mac で出なかったので、SwiftUI の `.contextMenu` をやめ、AppKit の `NSMenu` を直接出す透明な覆い (`RightClickMenu.swift`) にした。CI の画面テスト (`MessageListUITests`) で、行を右クリック →「アーカイブ」「削除」「迷惑メールにする」が出ることを確認 (2026-11-13)。
> - 「未読」で絞っているとき、開いたメールが一覧から消えていた (本文を取ったあと一覧を丸ごと読み直していたため)。書き出しの行だけを更新するように直した。

**説明:** ツールバーのボタンと右クリックメニューから、既読/未読、スター、フラグ、アーカイブ、削除、迷惑メールができるようにする。画面にはすぐ反映し、裏でサーバーに送る (失敗したら元に戻して知らせる)。Gmail では、アーカイブ = 受信トレイのラベルを外す、削除 = ゴミ箱へ移す、として扱う。

**受け入れ条件:**
- [x] 操作が 0.1 秒以内に画面に反映される (US-7) (画面を先に変えてからサーバーに送る作り。オーナーがアーカイブ・削除ですぐ消えることを確認)
- [x] 1 分以内に Gmail / Yahoo! の Web 画面にも反映される (2026-11-13 オーナーが Mac で確認)
- [x] 失敗したら元の状態に戻り、知らせが出る

**確認:**
- [x] 🐧 偽の IMAP サーバー相手に、各操作で正しい命令が送られるテスト (Gmail とそれ以外の両方)
- [x] 🍎 Gmail と Yahoo! で各操作をして、Web 画面で確認する (2026-11-13 オーナーが Mac で確認)

**依存:** T14
**触るファイル:** `Packages/MailStore/Sources/MailStore/MessageActions.swift`、`Packages/MailCore/Sources/MailCore/IMAP/IMAPSession.swift`、`App/Features/Reader/ReaderToolbar.swift`、`App/Features/Inbox/MessageRow.swift`、`Tests/MailStoreTests/MessageActionsTests.swift`
**大きさ:** M

### T16: キーボード操作とメニュー

> 状態: ✅ 済 (CI の画面テストと、2026-11-13 オーナーが Mac で確認)

**説明:** SPEC の US-8 のショートカットと、メニューバーの「メッセージ」メニューを作る。

**受け入れ条件:**
- [x] US-8 のショートカットがすべて動き、メニューにも項目がある (CI の画面テストと、2026-11-13 オーナーが Mac で確認)
- [x] `↑` `↓` で前後のメールに移り、本文が切り替わる (CI の画面テスト `testArrowKeysAndJMoveToTheNextMessage`)

**確認:**
- [x] 🍎 マウスを使わずに、メールを 10 通読んでアーカイブまでできる (CI の画面テストで ↑ ↓ J とメニューは確認済み) (2026-11-13 オーナーが Mac で確認)

> 状態 (2026-11-13): 「メッセージ」メニュー (返信 ⌘R・全員に返信 ⇧⌘R・転送 ⇧⌘F は T18 で動かす、既読/未読 ⇧⌘U、スター ⇧⌘L、アーカイブ ⌃⌘A、迷惑メール ⇧⌘J)、⌘F で検索欄へ、⌘N は「新規メッセージ」(T18 で動かす)、「新規ウィンドウ」は ⌥⌘N。
> 1 文字のショートカット (`↑` `↓` / `J` `K` 前後、`E` アーカイブ、`⌫` 削除、`S` スター) は、文字を打つ欄で誤って動かないよう、メール一覧にカーソルがあるときだけ受ける。
> 削除は文字を打つ欄で ⌘⌫ (行の始めまで消す) とぶつかるので、メニューにはショートカットを付けない。
> アーカイブ・削除のあとは、次のメールを選ぶ (先頭には戻らない)。

**依存:** T15
**触るファイル:** `App/CozyMailApp.swift`、`App/Features/Inbox/MessageCommands.swift`
**大きさ:** S

### T17: SMTP 送信と、送信用のメールの組み立て

**説明:** `MailCore` に SMTP クライアント (TLS、ログイン、XOAUTH2) と、送信用のメールの組み立て (日本語の件名、本文、添付、返信のための `In-Reply-To` / `References`) を作る。

**受け入れ条件:**
- [x] 偽の SMTP サーバー相手のテストで送信が通る
- [x] 組み立てたメールを T8 の解析器で読むと、元の内容に戻る
- [x] 暗号化なしの接続はできない

**確認:**
- [x] 🐧 `swift test --package-path Packages/MailCore` (80 件すべて通過、2026-11-13)
- [x] 🍎 `cozymail-probe send` で、オーナー自身のアドレスにテストメールが届く (代わりに、アプリの作成ウィンドウから送って届くことをオーナーが確認、2026-11-13)

> 状態 (2026-11-13): 🐧 済み。`SMTPSession` (465 は最初から TLS、587 は STARTTLS 必須。AUTH PLAIN / LOGIN / XOAUTH2。宛先が 1 つでも断られたら本文は送らない。「.」で始まる行の処理。返事と書き込みの時間切れ) と `MIMEBuilder` (日本語の件名・名前は RFC 2047、ファイル名は RFC 2231 で分割、本文は UTF-8 の Base64、1 行 78 文字まで、改行によるヘッダーの差し込みを防ぐ、Bcc はヘッダーに書かない)。
> - 作業中に見つけて直したこと: STARTTLS の暗号化の始まりで書き込みが終わらず止まることがあった → 書き込みにも時間切れを付けた。

**依存:** T8, T9
**触るファイル:** `Sources/MailCore/SMTP/SMTPSession.swift`、`Sources/MailCore/MIME/MIMEBuilder.swift`、`Tests/MailCoreTests/SMTPSessionTests.swift`、`Tests/MailCoreTests/MIMEBuilderTests.swift`
**大きさ:** M

### T18: 新規作成・返信・全員に返信・転送のウィンドウ

**説明:** 作成ウィンドウ (宛先 To/Cc/Bcc、件名、本文、添付、差出人のアカウント選び) を作る。返信・全員に返信・転送では宛先と件名を自動で入れ、元のメールを引用する。送信後、Gmail 以外は「送信済み」フォルダに `APPEND` する。

**受け入れ条件:**
- [x] どのアカウントからも送れて、相手に届く (US-6) (2026-11-13 オーナーが Mac で確認)
- [x] 返信は、受け取ったアカウントから送られる (`ComposerTests`、`ComposeModelTests`)
- [x] 送ったメールがそのアカウントの「送信済み」に 1 通だけ入る (2026-11-13 オーナーが Mac で確認)

**確認:**
- [x] 🐧 返信・全員に返信の宛先の組み立てのテスト (`ComposerTests` 13 件)
- [x] 🍎 各アカウントから自分宛てに送って、届くことと「送信済み」を確認する (2026-11-13 オーナーが Mac で確認)

> 状態 (2026-11-13): 🐧 宛先の組み立て (返信は Reply-To 優先、自分が送ったメールへの返信は元の宛先へ、全員に返信ではどのアカウントの自分のアドレスも除く)、件名の「Re:」「Fwd:」(重ねない)、日本語の引用、スレッドをつなぐヘッダー、送信 → Gmail 以外は「送信済み」に APPEND (Gmail は自動で入るので 2 通にしない)、送れたのに残せなかったときは「送れなかった」とは言わない、をテスト済み。
> 画面: 作成ウィンドウ (差出人の選択、宛先・Cc・Bcc、件名、本文、添付、⌘↩ で送信)。⌘N・⌘R・⇧⌘R・⇧⌘F、本文の上のボタン、一覧の右上の新規作成ボタンから開く。
> - 差出人の名前: アカウントごとに設定できるようにした (2026-11-14、PR #7)。名前のないメールはアドレスを出し、「送信済み」では宛先を出す。
> - ✅ 2026-11-13 オーナーが Mac で、送信・「送信済み」に 1 通だけ入ること・⌘↩ を確認。
> - まだのこと (フェーズ 4): 下書きの保存 (T23)、閉じるときの確認、署名 (US-14 / T25)、送信の取り消し (US-15 / T24)。

**依存:** T16, T17
**触るファイル:** `App/Features/Compose/ComposeWindow.swift`、`App/Features/Compose/RecipientField.swift`、`Packages/MailStore/Sources/MailStore/Composer.swift`、`Tests/MailStoreTests/ComposerTests.swift`
**大きさ:** M

### T19: Mac 内の検索

**説明:** ツールバーの検索欄から、保存済みのメールを差出人・件名・本文で検索する。オフラインでも使える。

**受け入れ条件:**
- [x] 1 万通の中から、1 秒以内に結果が出る (US-10) (`searchingTenThousandMessagesTakesUnderASecond`)
- [x] 日本語の部分一致で見つかる (`MessageQueryTests`: 「田中」「会議」「会議 資料 山田」など)
- [ ] 本文で見つかる — 一部だけ。いまは開いたことのあるメールの本文の書き出し (約 140 文字) まで。本文全体はオーナーと相談 (下)

**確認:**
- [x] 🐧 検索のテスト (日本語を含む)。メモリ上と SwiftData の保存先で、同じ結果になることを全フォルダ × 絞り込み × 12 個の言葉 (漢字・かな・英字) で比べる
- [x] 🍎 実際のアカウントで検索する (2026-11-14 オーナーが Mac で確認)

> 状態 (2026-11-14): ✅ (PR #12 マージ済み、オーナーが実アカウントで確認)。残りは本文全体で探すかの相談だけ。
> - 探す場所: 登録中のすべてのアカウントの、迷惑メールとゴミ箱を除くすべてのフォルダ (Gmail の検索と同じ)。選んでいるフォルダには関係なく探す。「未読」「スター付き」の絞り込みは検索の結果にも効く。
> - 探すもの: 差出人の名前・アドレス、件名、本文の書き出し。空白で区切った言葉は、すべてを含むもの。大文字と小文字、アクセント記号は区別しない。
> - 画面: 打つたびに探す。一覧の見出しが「検索」、その下に「「言葉」・n件」。esc か欄の × で検索をやめる。サイドバーでフォルダを選んでも検索をやめる。見つからないときは「見つかりませんでした」。
> - 検索中は、結果が変わっても一番上のメールを勝手に開かない (打っている途中に開くと、読んでいない未読メールがサーバーで既読になるため)。開いていたメールが結果にあれば開いたまま。削除などで消えたときは、ふだんどおり次のメールを開く。
> - 速さ: データベースの中で最初の言葉で絞り (`localizedStandardContains`)、残りの言葉はそのあとで確かめる。1 万通で 1 秒未満。
> - 決めたこと (あとから変えられる): 探す場所を「すべて」にした (いま開いているフォルダだけにする案もある)。宛先 (To/Cc) では探さない (保存の形が JSON のため、データベースの中で探せない)。
> - **相談が要ること (SPEC「先に相談する」):** 本文全体で探すには、開いたメールの本文の文字を別の列に保存する必要がある (SwiftData のモデルを第 3 版 `MailSchemaV3` にする)。まだ開いていないメールは本文を持っていないので、どちらにしても探せない (サーバー側の検索 T27 で補う)。

**依存:** T14
**触るファイル:** `Packages/MailStore/Sources/MailStore/MessageStore.swift` (`MessageQuery` の `searchText`)、`Sources/MailStoreSwiftData/SwiftDataMessageStore.swift`、`LiveMailRepository.swift`、`App/Features/Inbox/InboxModel.swift`、`App/Features/Reader/ReaderView.swift`、テスト (`MessageQueryTests`、`RepositorySearchTests`、`InboxModelSearchTests`、UI テスト)
**大きさ:** S

### T30: Dock のアイコンの未読数

**説明:** 統合受信トレイの未読数 (サイドバーの「統合受信トレイ」と同じ数) を Dock のアイコンのバッジに出す。0 のとき、見本のメールを出しているとき、数が分からないときは何も出さない。数を決める部分 (`DockBadge`) は画面と分けて `MailStore` に置き、Linux でもテストできるようにする。
オーナーの決定 (2026-11-14、チェックポイント v0.1): Dock の未読数は v0.1 に入れる。T20 からは外した (T20 は IMAP IDLE と通知だけ)。

**受け入れ条件:**
- [x] 未読数が 1 以上なら、その数が Dock のアイコンに出る。0 のときは何も出ない
- [x] 見本のメールを出しているときは出ない
- [x] 数はサイドバーの「統合受信トレイ」と同じ (メールを読むと減り、受信すると増える)
- [x] 1000 以上は「999+」(バッジが長くなりすぎないように)

**確認:**
- [x] 🐧 `DockBadgeTests` (0・見本・負の数・999+) と、`InboxModel` の `dockBadgeLabel` のテスト
- [x] 🍎 Dock に未読数が出て、読むと減る。全部読むと消える (2026-11-14 オーナーが Mac で確認)

> 状態 (2026-11-14): 🐧 済み。`DockBadge.label(unreadCount:isShowingSamples:)` (MailStore、Linux でもテスト可) で文字を決め、`InboxModel.dockBadgeLabel` が `unifiedUnreadCount` を渡す。`MainWindow` が `onChange` で `NSApplication.dockTile.badgeLabel` に付ける。(T21 で、付けるのはメニューバーの `MenuBarModel` に移した)
> - 決めたこと (あとから変えられる): 1000 以上は「999+」。ウィンドウをすべて閉じても、最後の数が残る (T20 のバックグラウンド同期のときに見直す)。
> - ✅ 2026-11-14 オーナーが Mac で確認。

**依存:** T15
**触るファイル:** `Packages/MailStore/Sources/MailStore/DockBadge.swift`、`Tests/MailStoreTests/DockBadgeTests.swift`、`App/Features/Inbox/InboxModel.swift`、`App/Features/Inbox/MainWindow.swift`、`AppTests/InboxModelTests.swift`
**大きさ:** S

### T31: 添付ファイルを Finder へドラッグ

**説明:** 本文の添付ファイルの欄 (`App/Features/Reader/`) から Finder へドラッグすると、そのファイルが保存される。サンドボックスのアプリなので、SwiftUI の `Transferable` (`FileRepresentation`) で、ドラッグを落としたときに中身を取って一時ファイルを渡す形にする。今ある保存ボタンと Quick Look はそのまま。
オーナーの決定 (2026-11-14、チェックポイント v0.1): 添付のドラッグは v0.1 に入れる。

**受け入れ条件:**
- [x] 添付のカードを Finder (やデスクトップ) にドラッグすると、元のファイル名で保存される
- [x] 保存されたファイルの中身が、メールの添付と同じ
- [x] 保存ボタンと、ダブルクリックの Quick Look は今までどおり動く
- [x] 取れなかったときは、エラーの表示が出る (黙って空のファイルを作らない)

**確認:**
- [x] 🐧 一時ファイルの書き出し (ファイル名、中身、危ない名前、取得の失敗) のテスト
- [x] 🍎 添付を Finder にドラッグすると保存され、中身が正しい (2026-11-14 オーナーが Mac で確認)

> 状態 (2026-11-14): 🐧 済み (`AttachmentDragTests` 5 件)。`DraggableAttachment` (`Transferable`、`FileRepresentation`) が、Finder に落とされたときに中身を取り、一時フォルダ/<UUID>/元の名前 に書いて渡す。ドラッグを始めただけでは通信しない。名前は `SafeHTML.safeFileName` で整える。取れなかったときは、既存の保存ボタンと同じエラーを出す。
> - 決めたこと (あとから変えられる): 種類は `.data` (どの種類のファイルも渡せる)。カード全体がドラッグできる (ボタンと Quick Look のダブルクリックはそのまま)。
> - ✅ 2026-11-14 オーナーが Mac で、Finder に落として保存されることを確認。ローカルの UI テストの実行は画面操作の許可がなくて止まったので、UI テストは CI の macOS で確かめる。

**依存:** T14
**触るファイル:** `App/Features/Reader/AttachmentDrag.swift` (新規)、`App/Features/Reader/ReaderView.swift`、`AppTests/AttachmentDragTests.swift`
**大きさ:** S

### ✅ チェックポイント v0.1
- [ ] 🍎 SPEC の P0 のユーザーストーリー (US-1〜US-11) の受け入れ条件を、実際の 4 アカウントで確認する — 作ったものは 2026-11-14 にオーナーが確認。Dock の未読数 (T30) と添付のドラッグ (T31) は v0.1 に入れると決め、作ってオーナーが確認した (2026-11-14)。残り: 本文全体の検索 (US-10) はあとで Mac で行う。Yahoo!
- [x] 🍎 `docs/manual-test.md` の手順をすべて通す (2026-11-14 オーナーが Mac で確認。Yahoo! の手順は除く)
- [x] 🐧 すべてのパッケージのテストが通る (CI で通過)
- [x] **フェーズ 4 を細かく決め直す** (2026-11-14 Claude が決めた。オーナーの指示で確認なし)

---

## フェーズ 4: v1.0 毎日使える

> 2026-11-14 Claude が決め直した (オーナーの指示: 確認はしないので、おすすめで決めて進める)。
> 順番の考え方: 毎日使うのにいちばん要る「新着がすぐ来る」(T20、T21) を先に。そのあと小さく安全なものから (T25 → T24 → T26 → T23)、最後に検索・設定 (T27、T28)。
> T22 は操作を保存する場所が要り、SwiftData のモデルを変えることになりそうなので、作る前に相談する。T29 は Google Cloud の設定が要るので保留のまま。
> 大きいもの (T20、T23) は 2 つに分けた。

### T20a: IMAP IDLE で新着をすぐ受け取る

**説明:** `MailCore` の `IMAPSession` に IDLE (サーバーが「新しいメールが来た」と知らせてくれる仕組み) を足す。`MailStore` に、アカウントごとに受信トレイを見張る `NewMailWatcher` を作る。知らせが来たらそのアカウントを同期する。IDLE ができないサーバーは 1 分ごとの確認にする。

**受け入れ条件:**
- [ ] サーバーに届いてから 10 秒以内に一覧に出る (US-12)
- [x] IDLE は 25 分ごとに入り直す (サーバーは 30 分で切ることがあるため)
- [x] つながらない・切れたときは、間をあけてつなぎ直す (1 秒 → 2 秒 → … 最大 5 分)
- [ ] スリープから戻ったら 1 分以内に見張りを再開する
- [x] IDLE に対応していないサーバーでは、1 分ごとに確認する

**確認:**
- [x] 🐧 IDLE の命令と、知らせ (EXISTS / EXPUNGE / FETCH) の読み取りのテスト (MailCore)
- [x] 🐧 `NewMailWatcher` のテスト (偽のサーバーで: 知らせ → 同期、25 分で入り直し、切れたらつなぎ直し、IDLE がないときの確認)
- [ ] 🍎 自分宛てに送って、10 秒以内に一覧に出る

> 状態 (2026-11-14): 🐧 済み。`IMAPSession.idle(in:timeout:)` (知らせ・時間切れ・中止のどれか、終わるときは DONE)、`supportsIdle()`、`noop()`。`NewMailWatcher` (MailStore) がアカウントごとに受信トレイを見張り、`MailService` が知らせを受けてそのアカウントだけ同期する。
> - テスト: `IMAPIdleTests` 9 件 (MailCore)、`NewMailWatcherTests` 8 件 (MailStore)、`MailServiceWatchTests` 3 件 (アプリ)。
> - 見直しで直したこと: (1) つながるのに IDLE がすぐ失敗するサーバーで、1 秒ごとに同期し続けていた → 一度ちゃんと見張れたときだけ待ち時間を 1 秒に戻す。(2) 回線が黙って切れていると DONE の返事を永遠に待っていた → 15 秒で諦めて接続を閉じる。
> - 同期中にまた知らせが来たら、同時には走らせず、終わってからもう 1 回だけ同期する (取りこぼさない)。
> - スリープから戻ったら、見張りをすぐつなぎ直して全体を同期する (`NSWorkspace.didWakeNotification`)。ここは自動テストがないので □ のまま。
> - テストと見本では見張らない (`watchesForNewMail` はアプリの `live()` だけ true)。本物のサーバーにはつながない。
> - 「10 秒以内に一覧に出る」は、実際に自分宛てに送る必要がある (実際のアカウントから送るのはオーナーの許可が要る) ので、Claude は確かめていない。
> - 決めたこと (あとから変えられる): IDLE は 25 分で入り直す。つなぎ直しは 1 秒から倍々で最大 5 分。IDLE がないサーバーは 1 分ごと。見張るのは受信トレイだけ。
> - 分かっている限界 (あとで直す): 知らせのたびに、そのアカウントの全フォルダを同期する (アプリ自身の既読・スターの知らせでも)。少し待ってまとめる仕組みはまだない。スリープなしで回線が変わったときは、切れたと分かる (25 分の入り直しか、通信の失敗) まで気づかない。回線の変化で見張りをつなぎ直すのは T21 以降で考える。

**依存:** T15
**触るファイル:** `Packages/MailCore/Sources/MailCore/IMAP/IMAPSession.swift`、`Packages/MailStore/Sources/MailStore/NewMailWatcher.swift`、`SyncEngine.swift` (`MailServerSession` に IDLE を足す)、`App/Services/MailService.swift`、テスト
**大きさ:** M

### T20b: 新着の Mac の通知

**説明:** 見張り (T20a) や同期で受信トレイに新しい未読メールが入ったら、Mac の通知を出す (差出人と件名)。通知を押すと、そのメールを開く。起動直後の最初の同期では出さない (たまっていた分で通知があふれないように)。

**受け入れ条件:**
- [ ] 新しい未読メールが受信トレイに入ると、差出人と件名の通知が出る (US-12)
- [x] 最初の同期・迷惑メール・すでに既読のメールでは出さない
- [x] 一度に 4 通以上来たら、「n 件の新着メール」の 1 つの通知にまとめる
- [ ] 通知を押すと、アプリが前に出てそのメールが開く
- [x] 設定で通知を切れる

**確認:**
- [x] 🐧 どのメールを通知するかを決める部分 (`NewMailNotifier`、画面と分ける) のテスト
- [ ] 🍎 新着で通知が出て、押すとそのメールが開く

> 状態 (2026-11-14): 🐧 済み。同期の結果 (`SyncEngine.Report.newInboxMessages`) に、前回の同期のあとに受信トレイに来た未読メールを入れる (初めての同期では空)。`NewMailNotifier` (MailStore) が通知の中身を決め、アプリの `NotificationService` が Mac の通知センターに出す。押すと `MailService.openRequest` → `InboxModel.show` で統合受信トレイのそのメールを開く。設定に「通知」タブを足した。
> - テスト: `NewInboxMailTests` 3 件・`NewMailNotifierTests` 7 件 (MailStore)、`MailServiceNotificationTests` 4 件・`InboxModelOpenFromNotificationTests` 2 件 (アプリ)。
> - □ のまま: 「通知が実際に Mac に出る」「押すとそのメールが開く」は、本物の新着が要るので Claude は確かめていない (中身を決める部分と、開く部分はテスト済み)。
> - 決めたこと (あとから変えられる): アプリが前にあっても通知を出す。起動直後の最初の一斉の同期では出さない。4 通以上は「n 件の新着メール」に (差出人を 3 人まで)。通知センターではアカウントごとにまとめる。
> - メインウィンドウを閉じているときに通知を押してもウィンドウが開かなかった点は、T21 で直した。

**依存:** T20a
**触るファイル:** `Packages/MailStore/Sources/MailStore/NewMailNotifier.swift`、`App/Services/NotificationService.swift` (新規、`UserNotifications`)、`App/Features/Settings/`、テスト
**大きさ:** M

### T21: メニューバー常駐とログイン時の起動

**説明:** メニューバーにアイコンを置き (`MenuBarExtra`)、未読数と最近の未読メールを出す。メインウィンドウを閉じてもアプリは終わらず、受け取り続ける。設定で「ログイン時に起動」を選べる (`SMAppService.mainApp`)。

**受け入れ条件:**
- [x] メニューバーに未読数が出る (Dock と同じ数)
- [ ] メニューから、最近の未読メール (5 通まで) を選ぶとメインウィンドウでそのメールが開く。「新着メールを受信」「Cozy Mail を開く」「終了」がある
- [ ] ウィンドウを閉じてもアプリは終わらず、新着の通知が出る (US-12)
- [ ] 設定で「ログイン時に起動」を選べ、今の状態が出る

**確認:**
- [x] 🐧 メニューに出す中身 (未読数・最近の未読) を決める部分のテスト
- [ ] 🍎 ウィンドウを閉じて、メニューバーから開ける。ログイン時の起動の切り替え

> 状態 (2026-11-14): 🐧 済み。`MenuBarSummary` (MailStore) が未読数と最近の未読 5 通を決め、アプリの `MenuBarModel` が読み直す。`MenuBarExtra` に封筒と未読数、メニューに未読メール・「新着メールを受信」・「Cozy Mail を開く」・「設定…」・「Cozy Mail を終了」。設定に「一般」タブ (ログイン時に開く、`SMAppService.mainApp`)。
> - Dock の未読数 (T30) は、メインウィンドウの `InboxModel` からメニューバーの `MenuBarModel` に移した (ウィンドウを閉じても数が古くならないように)。テストも `MenuBarModelTests` に移した。
> - 通知やメニューから開くメールは、`MailService.takePendingOpen()` でウィンドウが 1 回だけ受け取る。ウィンドウが閉じていたら、メニューバーのアイコンの側から開く (T20b の「閉じているとウィンドウが開かない」を直した)。
> - テスト: `MenuBarSummaryTests` 4 件 (MailStore)、`MenuBarModelTests` 3 件・`LoginItemSettingsTests` 2 件・`OpenRequestTests` 2 件 (アプリ)。
> - □ のまま: メニューから選んでそのメールが開くこと、ウィンドウを閉じても通知が出ること、実際のログイン項目の登録は、画面で Claude が確かめていない。
> - 決めたこと (あとから変えられる): メニューバーのアイコンはいつも出す (消す設定はまだない)。Dock のアイコンも残す。

**依存:** T20b
**触るファイル:** `App/CozyMailApp.swift`、`App/Features/MenuBar/` (新規)、`App/Features/Settings/`、テスト
**大きさ:** M

### T25: アカウントごとの署名

**説明:** 設定のアカウントの欄で、アカウントごとに署名を書ける。新規作成・返信・転送のとき、差出人のアカウントの署名を本文に入れる。差出人を変えたら署名も入れ替える。
署名は、アカウント一覧の保存 (`accounts.v1`) の形を変えずに、別の保存 (UserDefaults の別の場所) に置く (保存データの形を変えないため)。

**受け入れ条件:**
- [ ] アカウントごとに署名を書いて残せる (US-16)
- [x] 新規作成では本文の最後、返信・転送では引用の上に「-- 」と署名が入る
- [x] 差出人を変えると、署名が入れ替わる (自分で書いた本文は消えない)
- [x] 署名が空なら何も入らない

**確認:**
- [x] 🐧 署名の入れ方・入れ替え方のテスト (`Composer`)
- [ ] 🍎 署名を設定して、新規作成・返信で入る

> 状態 (2026-11-14): 🐧 済み。`Composer.draft(..., signature:)` が署名を入れ、`Composer.replacingSignature` が差出人を変えたときに入れ替える (手で消した署名は戻さない)。`SignatureStore` (MailStore) が UserDefaults の `signatures.v1` に保存する (アカウント一覧の保存の形は変えていない)。設定の「アカウント」に署名の欄。アカウントを消すと署名も消える。
> - テスト: `SignatureTests` 9 件・`SignatureStoreTests` 3 件 (MailStore)、`ComposeModelSignatureTests` 4 件・`MailServiceSignatureTests` 1 件 (アプリ)。
> - □ のまま: 「アカウントごとに書いて残せる」は保存の部分をテストしたが、設定画面での入力は Claude が画面で確かめていない。
> - 決めたこと (あとから変えられる): 区切りは「-- 」(メールの決まりごと)。返信・転送では引用の上 (Gmail と同じ)。署名の欄は、欄から離れたときに保存する。

**依存:** T18
**触るファイル:** `Packages/MailStore/Sources/MailStore/Composer.swift`、`SignatureStore.swift` (新規)、`App/Features/Accounts/AccountsSettings.swift`、`App/Features/Compose/ComposeModel.swift`、テスト
**大きさ:** M

### T24: 送信の取り消し

**説明:** 送信を押してから設定した秒数 (5〜30 秒、初めは 10 秒) は送らずに待ち、「取り消す」を押せば作成ウィンドウに戻る。待っている間にアプリを終えようとしたら、先に送る。

**受け入れ条件:**
- [ ] 送信後、設定した秒数のあいだ「送信を取り消す」が出て、押すと送られずに作成ウィンドウが元の中身で開く (US-15)
- [ ] 秒数は設定で 5〜30 秒 (0 = すぐ送る も選べる)
- [ ] 待っている間にアプリを終えると、先に送ってから終わる

**確認:**
- [ ] 🐧 送信の待ち行列 (待つ・取り消す・時間が来たら送る・終了時に送る) のテスト (時計は偽物で)
- [ ] 🍎 自分宛てに送って取り消す / 取り消さずに届く

**依存:** T18
**触るファイル:** `Packages/MailStore/Sources/MailStore/SendQueue.swift` (新規)、`App/Features/Compose/`、`App/Services/MailService.swift`、テスト
**大きさ:** M

### T26: 複数のメールを選んでまとめて操作

**説明:** 一覧で ⌘ + クリック・⇧ + クリック・⌘A で複数選び、まとめて既読/未読・スター・アーカイブ・削除・迷惑メールにする。サーバーへはアカウントとフォルダごとにまとめて 1 回で送る。

**受け入れ条件:**
- [ ] ⌘ / ⇧ + クリック、⌘A で複数選べる (US-17)
- [ ] ツールバー・右クリック・キーボードの操作が、選んだすべてに効く
- [ ] 複数を選んでいるときは、本文の列に「n 通を選択中」と出る
- [ ] 違うアカウントのメールが混ざっていても、それぞれのサーバーに送られる

**確認:**
- [ ] 🐧 まとめての操作のテスト (`InboxModel`、`LiveMailRepository`: アカウント・フォルダごとに 1 回)
- [ ] 🍎 複数選んでアーカイブし、Gmail の Web 版にも出る

**依存:** T15
**触るファイル:** `App/Features/Inbox/InboxModel.swift`、`MessageListView.swift`、`ReaderView.swift`、`Packages/MailStore/Sources/MailStore/LiveMailRepository.swift`、テスト
**大きさ:** M

### T23a: 下書きを Mac に自動保存

**説明:** 作成ウィンドウの中身を、打つのをやめて 2 秒たったら Mac に保存する。ウィンドウを閉じるときに中身があれば「下書きに保存 / 捨てる / やめる」を聞く。アプリを開き直すと、下書きフォルダから続きが書ける。
保存先は、SwiftData のモデルを変えずに、アプリの保存フォルダの JSON ファイルにする (保存データの形を変えないため)。

**受け入れ条件:**
- [ ] 打つのをやめて 2 秒で保存され、アプリが落ちても残る (US-14)
- [ ] 閉じるときに聞かれ、「下書きに保存」で残り、「捨てる」で消える
- [ ] 下書きフォルダに出て、開くと作成ウィンドウで続きが書ける。送ったら消える

**確認:**
- [ ] 🐧 下書きの保存・読み込み・削除のテスト (一時フォルダで)
- [ ] 🍎 書きかけで閉じて、下書きから続きを書いて送る

**依存:** T18
**触るファイル:** `Packages/MailStore/Sources/MailStore/DraftStore.swift` (新規)、`App/Features/Compose/`、テスト
**大きさ:** M

### T23b: 下書きをサーバーの下書きフォルダにも保存

**説明:** Mac に保存した下書きを、サーバーの下書きフォルダにも `APPEND` する (Gmail の Web 画面から続きが書けるように)。書き直したら古いものを消して入れ直す。送ったらサーバーの下書きも消す。

**受け入れ条件:**
- [ ] 下書きがサーバーの下書きフォルダに 1 通だけある (US-14)
- [ ] 送ったら、サーバーの下書きも消える

**確認:**
- [ ] 🐧 偽のサーバーで、入れ直し・削除の順番のテスト
- [ ] 🍎 Gmail の Web 版の下書きに出る

**依存:** T23a
**大きさ:** M

### T27: サーバー側の検索

**説明:** Mac 内の検索 (T19) の結果の下に「サーバーで探す」を出し、押すとサーバーで探す (Gmail は `X-GM-RAW`、ほかは `UID SEARCH TEXT`)。保存していない古いメールや、本文の中の言葉でも見つかる。見つかったメールは見出しを取って一覧に足す。

**受け入れ条件:**
- [ ] 30 日より前のメールや、本文の言葉でも見つかる (US-10)
- [ ] 結果は Mac 内の結果と重ならない

**確認:**
- [ ] 🐧 検索の命令の組み立て (日本語・Gmail) と、結果をまとめるテスト
- [ ] 🍎 古いメールを、サーバーで探して開ける

**依存:** T19
**大きさ:** M

### T28: IMAP / SMTP のサーバー設定を手で入れる

**説明:** アカウントの追加で「その他」を選ぶと、IMAP と SMTP のサーバー名とポートを入れられる (独自ドメイン用)。保存の形 (`ServerSettings`) はもうあるので変えない。暗号化なしの接続は選べない (993 / 465 / 587 の STARTTLS だけ)。

**受け入れ条件:**
- [ ] 「その他」でサーバー名・ポートを入れて追加でき、受信と送信ができる (US-2)
- [ ] 暗号化しないポート (143、25 など) は選べない

**確認:**
- [ ] 🐧 入力の確かめ (サーバー名・ポート) のテスト
- [ ] 🍎 (独自ドメインのアカウントがあれば) 追加して受信・送信

**依存:** T11
**大きさ:** S

### T22: オフラインの待ち行列 (作る前に相談)

**説明:** オフライン中の整理の操作 (既読・アーカイブなど) をためておき、つながったらサーバーに送る。アプリを終えても残すには、操作を保存する場所が要る。SwiftData のモデルに足すなら第 3 版になるので、**作る前にオーナーに相談する** (SPEC「先に相談する」)。

**依存:** T15
**大きさ:** M

| ID | タスク | US | 依存 |
|---|---|---|---|
| T29 (P2) | Gmail の「Google でログイン」。ホームページとプライバシーポリシーの URL を用意して (例: GitHub Pages)、Google Cloud を「本番環境」にする。⏸ 保留 (Google Cloud の設定が要る) | US-1 | T9, T12 |

### ✅ チェックポイント v1.0
- [ ] 🍎 SPEC の成功の条件 (10 章) をすべて満たす
- [ ] 🍎 オーナーが 2 週間、ほかのメールアプリやブラウザの Gmail を使わずに過ごせる
