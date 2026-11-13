# アプリパスワードの準備

Cozy Mail は、どのアカウント (Gmail も Yahoo! も) も **アプリパスワード** でつなぎます。
アプリパスワードは、ふだんのログイン用パスワードとは別に、メールアプリ専用に発行するパスワードです。費用はかかりません。

- 1 つのアカウントにつき 1 回だけの準備です (Gmail 3 つなら 3 回)。
- アプリパスワードは Mac のキーチェーンにだけ保存します。リポジトリや記録には出しません。
- いらなくなったら、各社の設定画面からいつでも取り消せます。取り消すと Cozy Mail からはつながらなくなります。

> 各社の画面は、名前や場所がよく変わります。下の手順と表記が違うときは、似た名前の項目を探してください。

## Gmail

1. **2 段階認証を有効にする** (有効なら飛ばす)
   <https://myaccount.google.com/security> → 「2 段階認証プロセス」をオンにする。
2. **アプリパスワードを作る**
   <https://myaccount.google.com/apppasswords> を開き、アプリ名に `Cozy Mail` と入れて「作成」。
   表示された 16 文字 (`abcd efgh ijkl mnop` のような形) を控える。**この画面を閉じると二度と表示されません。**
3. **IMAP を確認する**
   Gmail を開き、右上の歯車 →「すべての設定を表示」→「メール転送と POP/IMAP」で、IMAP が無効なら有効にする。

| 項目 | 値 |
|---|---|
| 受信 (IMAP) | `imap.gmail.com`、ポート 993 |
| 送信 (SMTP) | `smtp.gmail.com`、ポート 465 |
| ユーザー名 | Gmail のアドレス |
| パスワード | 手順 2 のアプリパスワード (空白はあってもなくてもよい) |

**アプリパスワードの画面が出ないとき:** 2 段階認証がオフ、または会社の Google Workspace のアカウントで管理者が禁止している可能性があります。後者の場合は、そのアカウントだけ管理者に相談するか、P2 の「Google でログイン」(`docs/google-oauth-setup.md`) を待ってください。

## Yahoo!メール (Yahoo! JAPAN)

1. Yahoo!メールを開き、「設定・利用規約」→「メールの設定」→「IMAP/POP/SMTPアクセス」を開く。
2. IMAP と SMTP のアクセスを「有効にする」にして保存する。
3. 画面の案内に従ってパスワードを用意する。ログイン方法によっては、IMAP 用のパスワードの発行や設定を求められます。

| 項目 | 値 |
|---|---|
| 受信 (IMAP) | `imap.mail.yahoo.co.jp`、ポート 993 |
| 送信 (SMTP) | `smtp.mail.yahoo.co.jp`、ポート 465 |
| ユーザー名 | Yahoo! のメールアドレス |

## つながるか確かめる (確認用ツール)

アプリの画面 (T11 / T12) ができる前に、Mac のターミナルで確かめられます。リポジトリの一番上で次を実行し、パスワードを聞かれたらアプリパスワードを貼り付けます (画面には表示されません)。

```bash
swift run --package-path Packages/MailCore cozymail-probe imap.gmail.com あなたのアドレス@gmail.com
```

```bash
swift run --package-path Packages/MailCore cozymail-probe imap.mail.yahoo.co.jp あなたのアドレス@yahoo.co.jp
```

フォルダの一覧と、受信トレイの最新 20 通の件名が出れば成功です。

## うまくいかないとき

| 表示 | 原因と対処 |
|---|---|
| `ログインできませんでした: ... Invalid credentials` | パスワードが違う。ふだんのパスワードではなく、アプリパスワードを使っているか確認する |
| `ログインできませんでした: ... Application-specific password required` | Gmail で、ふだんのパスワードを入れている。手順 2 のアプリパスワードを使う |
| `サーバーに接続できませんでした` | サーバー名の打ち間違い、またはネットワークの問題 |
| Yahoo! で `Invalid credentials` | 「IMAP/POP/SMTPアクセス」が無効のまま。手順 1〜2 を確認する |
