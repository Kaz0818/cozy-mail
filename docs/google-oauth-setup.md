# Google ログインの準備 (Google Cloud の設定)

> **⏸ 2026-11-13 から保留中 (P2)。** いまの Cozy Mail は、Gmail も **アプリパスワード** でつなぎます (`docs/app-passwords.md`)。
> この手順は、将来「Google でログイン」を足すときのために残しています。「本番環境」にするには、アプリのホームページとプライバシーポリシーの URL が必要です (例: GitHub Pages で用意する)。

Cozy Mail で Gmail を「Google でログイン」で使うための、1 回だけの準備です。所要時間は 10 分ほどです。

> Google Cloud の画面は、名前や場所がよく変わります。下の手順と画面の表記が違うときは、似た名前の項目を探してください。

## 1. プロジェクトを作る

1. <https://console.cloud.google.com/> を開き、Gmail のどれか 1 つのアカウントでログインする。
2. 上のプロジェクト選択から「新しいプロジェクト」を選び、名前を `Cozy Mail` にして作る。

## 2. Gmail API を有効にする

1. 「API とサービス」→「ライブラリ」で `Gmail API` を検索する。
2. 「有効にする」を押す。

## 3. 同意画面 (Google Auth Platform) を設定する

1. 「Google Auth Platform」(または「OAuth 同意画面」) を開く。
2. **ブランディング**: アプリ名 `Cozy Mail`、サポートのメールアドレス (自分のアドレス) を入れて保存する。
3. **対象 (Audience)**: ユーザーの種類は「外部」。
4. **データアクセス**: 「スコープを追加」から `https://mail.google.com/` を追加して保存する (「制限付きのスコープ」と表示されますが、そのままで大丈夫です)。
5. **対象 (Audience)** に戻り、公開ステータスを **「アプリを公開」→「本番環境」** にする。

> ⚠️ **「テスト」のままにしないでください。** テスト状態では、7 日ごとにログインし直しになります。
> 本番状態でも Google の審査は不要です (自分用・100 人までなら)。代わりに、ログイン時に「Google はこのアプリを確認していません」という警告が出ます。

## 4. OAuth クライアントを作る

1. 「Google Auth Platform」→「クライアント」→「クライアントを作成」。
2. アプリケーションの種類は **「デスクトップ アプリ」**、名前は `Cozy Mail (Mac)`。
3. 作成すると **クライアント ID** と **クライアント シークレット** が表示されるので、控えておく。

> クライアント ID とシークレットは、**リポジトリにコミットしないでください**。下の `Local.xcconfig` (Git に入らない) か、環境変数にだけ書きます。

## 5. Cozy Mail に設定する

### アプリ

リポジトリの一番上で `Local.xcconfig.sample` を `Local.xcconfig` にコピーし、次の 2 行を自分の値にする。

```
COZYMAIL_GOOGLE_CLIENT_ID = 1234567890-xxxx.apps.googleusercontent.com
COZYMAIL_GOOGLE_CLIENT_SECRET = GOCSPX-xxxxxxxx
```

### 確認用ツール (`cozymail-probe`)

```bash
export COZYMAIL_GOOGLE_CLIENT_ID="1234567890-xxxx.apps.googleusercontent.com"
```

```bash
export COZYMAIL_GOOGLE_CLIENT_SECRET="GOCSPX-xxxxxxxx"
```

```bash
swift run --package-path Packages/MailCore cozymail-probe --gmail
```

ブラウザが開くので、ログインする Gmail アカウントを選びます。

## 6. 最初のログインで出る警告

「Google はこのアプリを確認していません」と出たら、

1. 「詳細」を押す。
2. 「Cozy Mail (安全ではないページ) に移動」を押す。
3. 「Gmail のすべてのメールの閲覧、作成、送信、削除」にチェックを入れて「続行」。

自分で作ったアプリなので問題ありません。3 つの Gmail アカウントそれぞれで 1 回ずつ行います。

## うまくいかないとき

| 表示 | 原因と対処 |
|---|---|
| `invalid_client` | クライアント ID かシークレットが違う。コピーし直す |
| `access_denied` / 「アクセスをブロック」 | 同意画面が「テスト」状態で、そのアカウントがテストユーザーに入っていない。手順 3-5 で「本番環境」にする |
| 7 日後にログインし直しを求められる | 同意画面が「テスト」状態のまま。手順 3-5 |
| IMAP で `Invalid credentials` | 手順 3-4 で `https://mail.google.com/` を追加していない、またはログイン時にチェックを入れていない |
