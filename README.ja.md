# Koedex

Koedexは、Mac全体で使える音声入力アプリです。ホットキー（既定はfnキー）を押して録音を開始し、
もう一度押して停止すると、あなたの発話が端末内で文字起こしされ、AIによって整形（フィラー除去・
言い直しの反映・句読点整形）された後、最前面アプリのカーソル位置に貼り付けられます。

English version: [README.md](README.md)

> **はじめて使う方へ** — 導入から設定までを噛み砕いて説明した
> [取扱説明書](docs/manual/ja.md)を用意しています。
> このREADMEは開発者向けの要約です。

## OpenAIとは無関係です

Koedexは独立したコミュニティプロジェクトです。**OpenAIと提携・後援・公認された関係にはありません。**
「OpenAI」「ChatGPT」「Codex」はOpenAIの商標です。Koedexは、OpenAIのロゴやブランドカラーを一切
使用していません。本プロジェクトのいかなる部分も、OpenAIの公式な製品やコミュニケーション窓口として
読み取られるべきではありません。詳細は[NOTICE](NOTICE)を参照してください。

## 動作要件

- macOS 26 (Tahoe) 以降 — KoedexはApple SpeechAnalyzer APIに依存しており、それより前のバージョンでは
  動作しません。
- ソースからビルドする場合はSwift 6.2以降。Command Line Tools SDKで十分で、Xcode.appのフルインストール
  は不要です。
- PATH上に[Codex CLI](https://www.npmjs.com/package/@openai/codex)（`codex`コマンド）があり、
  ChatGPTサブスクリプションで認証済みであること（つまり `~/.codex/auth.json` が存在し有効であること）。
  Koedexは `codex app-server` を子プロセスとして起動するだけで、どのAPIとも直接通信しません。

## 端末外へ出るもの・出ないもの

- **文字起こしは完全に端末内で行われます。** KoedexはApple SpeechAnalyzer/SpeechTranscriberを使って
  音声をローカルでテキスト化します。文字起こしのために音声が端末の外へ送られることはありません。
  ここで発生する唯一のネットワーク通信は、macOSがある言語を初めて使う際に、Appleから音声認識モデルの
  アセットをダウンロードする処理です。
- **AI整形と「AIに指示」は、ローカルの`codex` CLI経由で処理されます。** 文字起こしされたテキスト
  （音声そのものではありません）が `codex app-server` へ送られ、あなた自身が認証済みのChatGPT
  サブスクリプションを使ってOpenAIと通信します。Koedexは `mcp_servers={}` `plugins={}` を指定して
  `codex app-server` を起動し、`~/.codex/config.toml` は変更しません。
- それ以外――設定、履歴、ユーザー辞書、カスタムインストラクション――はすべて
  `~/Library/Application Support/Koedex/` 以下にローカル保存され、Koedex自身がどこかへ送信することは
  ありません。

## インストール／ソースからのビルド

```bash
# このリポジトリのクローンから実行します

# 実行ファイルだけをビルド
swift build

# .appバンドルの組み立て（dist/Koedex.appを生成）
./scripts/make_app.sh debug
```

### コード署名証明書（初回のみ）

`scripts/make_app.sh` は ad-hoc署名の`.app`を作成しません。ad-hoc署名はビルドごとにアイデンティティが
変わり、署名が変わるたびにmacOSがアクセシビリティ／マイク／音声認識の権限を無効化してしまうためです。
代わりに、安定したローカル自己署名証明書「Koedex Dev」が必要です。

初回ビルド前に、以下で作成します。

```bash
bash scripts/make_signing_cert.sh
```

これによって自己署名のコード署名証明書が生成され、ログインキーチェーンへインポートされます。続いて
macOSが、この証明書をコード署名用として信頼するかどうかの承認を求めてきます。**この承認はキーチェーン
アクセスのGUIダイアログで行われるものであり、スクリプトから自動化することはできません。** これは
意図的なmacOSのセキュリティゲートです。この承認が完了していなくても、スクリプト自体は成功終了し、
未完了の場合は次の手順を案内します。

```bash
security add-trusted-cert -k "$HOME/Library/Keychains/login.keychain-db" \
  "$HOME/Library/Application Support/Koedex/koedex_dev_cert.crt"
```

`scripts/make_app.sh` は、この証明書が信頼済みのコード署名アイデンティティとして認識される
（`security find-identity -v -p codesigning` に表示される）まで、`.app`の組み立てを行いません。
表示されるようになったら、`./scripts/make_app.sh debug`（または`release`）を再実行してください。

## 3つの権限付与手順

Koedexは、macOSの3つのプライバシー権限を必要とします。`dist/Koedex.app`を`/Applications`などへ
コピーし、初めて起動した際にダイアログが出たら順に許可してください（ダイアログが出ない場合は手動で
追加します）。

1. **アクセシビリティ（Accessibility）** — グローバルホットキー検知（`CGEventTap`）と、カーソル位置
   への⌘V送出に必要です。システム設定 > プライバシーとセキュリティ > アクセシビリティ から
   Koedexを追加してONにします。
2. **マイク（Microphone）** — 音声録音に必要です。システム設定 > プライバシーとセキュリティ >
   マイク からKoedexをONにします。
3. **音声認識（Speech Recognition）** — オンデバイス文字起こしに必要です。通常は初回起動時に
   ダイアログが自動で出ます。出ない場合はシステム設定 > プライバシーとセキュリティ > 音声認識 を
   確認してください。

アクセシビリティ権限はプロセス起動時に一度だけチェックされます。権限を許可した後は、同じセッションを
続けるのではなく、**Koedexを完全に終了してから再起動してください**。再起動するまで、新しく許可した
アクセシビリティ権限は反映されません。

## 使い方

- 任意のアプリでカーソルをテキスト入力欄に置いた状態で、**fnキー**を押し続けると録音が始まります。
  もう一度**fnキー**を押すと停止し、文字起こし→AI整形→カーソル位置への貼り付け、が自動で行われます。
- 処理中は、画面下部の小さなフローティングHUDに「録音中」「整形中」などの状態が表示されます。
- メニューバーアイコンから「設定…」を開くと、AI整形のオン/オフ、カスタムインストラクション、履歴、
  ユーザー辞書を管理できます。
- ホットキーは設定画面で変更できます。既定はfnキー（`0x3F`）です。

### AIに指示

「AIに指示」は、単なる文字起こしではなくAIに何かをしてもらうための、別系統のワンタップ操作です。

- 既定のバインドは、開始が**fn + Space**、停止が**fn**です（いずれも変更可能）。
- **録音開始時に文章を選択している場合**：話した指示が、選択した文章に対して適用されます
  （要約・翻訳・書き換えなど）。結果は、停止時点で元のキャレット位置が安全だと確認できた場合のみ
  貼り付けられます。それ以外の場合は、盲目的に挿入せず、コピー可能な別ウィンドウに表示されます。
  この経路ではWeb検索は無効です。選択した文章にプロンプトインジェクション（AIへの意図しない指示）が
  含まれている可能性があるためです。
- **選択がない場合**：話した指示はAIへの質問として扱われ、回答は別ウィンドウに表示されます。
  Web検索はこの経路でのみ利用でき、回答には実際に参照した具体的なリンクが表示されます。
- 「AIに指示」の履歴には、確定した音声指示の文字起こしだけが保存されます。選択した文章、回答、
  音声、参照リンクは保存されません。

### ハンズフリー送信

ハンズフリー送信は、特定のトリガーフレーズを話すことで、貼り付けて止めるのではなく、自動で送信
（Return、⌘Return、⌃Returnのいずれかを擬似的に送出）できる機能です。既定ではオフになっており、
設定画面で個別に有効化します。外部アプリでの自動送信には、専用の明示的な同意設定があります。

## 初回起動時の注意（Gatekeeper）

現在、Koedexの配布物（Releases）は**notarize（公証）されていません**。ダウンロードした`Koedex.app`を
初めて開くとき、macOSのGatekeeperが通常のダブルクリックでは起動をブロックします。

開き方:

1. `Koedex.app`を右クリック（またはControlクリック）し、**「開く」**を選び、表示される確認ダイアログで
   承認する。**または**
2. 一度通常どおり開こうとして（ブロックされます）、**システム設定 > プライバシーとセキュリティ**を開き、
   Koedexの項目の横にある**「このまま開く」**をクリックする。

この操作は、ビルドごとに一度だけ必要です。転送方法などの事情で上記のいずれもうまくいかず、かつ
入手元を確認済みの場合に限り、最後の手段としてquarantine属性を直接解除できます。

```bash
xattr -dr com.apple.quarantine /Applications/Koedex.app
```

## 開発

```bash
# ビルド
swift build

# .appバンドルの組み立て — 4つのターゲットに対応しています
./scripts/make_app.sh debug                  # dist/Koedex.app、debugビルド
./scripts/make_app.sh release                # dist/Koedex.app、releaseビルド
./scripts/make_app.sh onboarding-debug        # dist/Koedex Debug.app、初回セットアップ確認用の隔離環境
./scripts/make_app.sh language-setup-debug    # dist/Koedex Language Setup Debug.app、言語セットアップ確認用の隔離環境

# 回帰テストスイート — ネットワーク通信もcodex app-server呼び出しも行いません
.build/debug/Koedex --test-regressions

# 想定より多くスキップされたら失敗させる（CIは13を渡しています）
.build/debug/Koedex --test-regressions --max-skips 13
```

特定の部分を調べるための診断コマンドです。回帰テストスイートには含まれず、CIでも実行されません。

```bash
# 音声ファイルを文字起こしする（1回／繰り返し）
# 録音時と同じく、マイク権限と音声認識権限の両方が必要です
.build/debug/Koedex --test-stt path/to/audio.wav
.build/debug/Koedex --test-stt-repeat 5 path/to/audio.wav

# 部分結果がいつ届くかを、録音せずに計測します
.build/debug/Koedex --test-stt-partials path/to/audio.wav \
  --probe-locale ja-JP --probe-reporting volatile,fast --probe-trailing-silence-ms 12000
# 他に --probe-chunk-ms, --probe-feed, --probe-format, --probe-transcription,
# --probe-attributes, --probe-preset, --probe-label, --probe-reserve, --probe-prepare,
# --probe-start-time, --probe-detector

# AI整形を実行します — こちらはcodex app-serverを実際に起動します
.build/debug/Koedex --test-cleanup "整形したい文章" --test-model <slug> --test-effort <effort>

# 同一プロセス内でN回整形し、thread使い回しの効果を見ます。
# **回数だけ**を取ります。入力は組み込みの固定文字列で、渡した文字列は使われません。
.build/debug/Koedex --test-cleanup-repeat 3 --test-model <slug> --test-effort <effort>
```

`onboarding-debug`と`language-setup-debug`は、それぞれ独自の
`~/Library/Application Support/Koedex Debug/`相当のデータ領域を使うため、普段使いのKoedexの設定・
履歴・辞書・Codex接続に触れずに初回フローを試せます。

一部のクリップボード（pasteboard）関連の回帰テストは、実際のpasteboardサーバーへの接続を必要とします。
ヘッドレス環境やCIなど、それが使えない環境では、メッセージを表示して自動的にスキップされます。
これは想定内の挙動であり、失敗ではありません。CIでの実行例は`.github/workflows/build.yml`を参照して
ください。

## サポート専用フラグ

Koedexは`--support-scoped-clipboard-fallback enable|disable|status`も受け付けます。これは特定の
外部アプリとの貼り付け互換性の問題に対処するための、サポート／診断用ツールです。通常のユーザーには
不要で、ソースから見つけられるものなので、ここに正直に記載しています。

このフラグは設定の互換入力モードに従属します。互換入力がOFFの間は`enable`できず、互換入力をOFFに
するとこのフラグも解除されます。**互換入力をONに戻してもこのフラグは復活しません**。もう一度
`enable`を実行してください。`onboarding-debug`と`language-setup-debug`のビルドでも拒否されます。

実行前にKoedexを終了してください。起動中はコマンド側が拒否します（アプリとコマンドが同時に
設定ファイルを持たないようにするためです）。

## ライセンス

Koedexは[Apache License 2.0](LICENSE)の下で公開されています。帰属表示とOpenAIとの非提携についての
注記は[NOTICE](NOTICE)も参照してください。
