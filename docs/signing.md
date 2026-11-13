# 無料の Apple ID で署名する (キーチェーンの確認を減らす)

## なぜ必要か

何も設定しないと、アプリは「Sign to Run Locally」(自分の Mac だけで動く署名) で作られます。
この署名は **ビルドするたびに変わる** ので、macOS は毎回「知らないアプリがキーチェーンを使おうとしている」と判断し、
ログインのパスワードを聞いてきます。

無料の Apple ID (Personal Team) で署名すると、署名がビルドのたびに変わらなくなります。
一度「常に許可」を押せば、そのあとは基本的に聞かれません。

- 料金はかかりません (年 $99 の Apple Developer Program には入りません)。
- ふだん使っている Apple ID でかまいません。アプリが公開されたり、Apple ID の情報がリポジトリに入ったりすることはありません。
- 設定は `Local.xcconfig` (Git に入らないファイル) に書きます。

## 手順

### 1. Xcode に Apple ID を追加する

1. Xcode を開き、メニューの「Xcode > Settings…」(⌘,) を開く。
2. 「Accounts」のタブで、左下の「＋」→「Apple ID」を選び、ふだんの Apple ID でサインインする。
3. 追加した Apple ID を選ぶと、右に「(あなたの名前) (Personal Team)」が出る。
4. 「Manage Certificates…」を押し、左下の「＋」→「Apple Development」を選ぶ (署名用の証明書ができる)。

### 2. チーム ID を調べる

ターミナルで次を実行します。

```bash
security find-certificate -c "Apple Development" -p | openssl x509 -noout -subject
```

出てきた文の中の `OU=` のあとの 10 文字 (英大文字と数字) がチーム ID です。
(`CN=Apple Development: 名前 (XXXXXXXXXX)` のかっこの中は、チーム ID ではないので注意)

### 3. `Local.xcconfig` に 2 行書く

リポジトリの一番上 (`project.yml` と同じ場所) にある `Local.xcconfig` に、次の 2 行を足します (ファイルがなければ作ります)。

```
DEVELOPMENT_TEAM = チームID
CODE_SIGN_IDENTITY = Apple Development
```

### 4. 作り直す

```bash
xcodegen
```

Xcode で開き直してビルドします。最初の 1 回だけキーチェーンの確認が出るので、**「常に許可」** を押します。

## うまくいかないとき

- **「Failed to register bundle identifier」と出る**: バンドル ID がほかの人と重なっています。
  `Local.xcconfig` の `COZYMAIL_BUNDLE_ID` を、自分だけのもの (例: `com.あなたの名前.cozymail`、英数字と `.` だけ) にします。
  バンドル ID を変えると、アプリの保存場所が変わるので、**アカウントを追加し直す** 必要があります (一度だけ)。
- **元に戻したい**: `Local.xcconfig` の 2 行を消して `xcodegen` し直せば、元の「Sign to Run Locally」に戻ります。
