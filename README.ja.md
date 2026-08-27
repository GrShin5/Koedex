# Koedex

<p align="center">
  <img src="Assets/Branding/KoedexIcon-1024.png" width="128" alt="Koedex アイコン">
</p>

[English](README.md) | [日本語](README.ja.md) | [User guide](docs/manual/en.md) | [日本語ガイド](docs/manual/ja.md)

Koedexは、Mac全体で使える音声入力アプリです。ホットキー（既定はfnキー）を押して録音を開始し、
もう一度押して停止すると、あなたの発話が端末内で文字起こしされ、AIによって整形（フィラー除去・
言い直しの反映・句読点整形）された後、最前面アプリのカーソル位置に貼り付けられます。

> **はじめて使う方へ** — 上の日本語ガイドでは、導入から設定までを噛み砕いて説明しています。
> このREADMEは開発者向けの要約です。

## アーリーアクセスについて

これは未完成のアーリーアクセス版です。実際に使ったユーザーから問題点や改善案の
フィードバックを受け取り、それを今後の開発に反映していくために公開しています。

- 不具合報告・機能要望 → [GitHub Issues](../../issues)
- セキュリティ脆弱性 → **公開のIssueは立てず**、[SECURITY.md](SECURITY.md)の
  手順に従ってください。

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
- **このフォルダは、本人のアクセスだけを許す権限で作られます。** ディレクトリは`0700`、
  Koedex自身が書くファイルは`0600`です。1台のMacを複数のアカウントで共有していても、
  他のアカウントから文字起こしの内容を読むことはできません。実際に他アカウントを遮っているのは
  `0700`のディレクトリです。`codex` CLIが`AICommandRuntime/`配下へ書く一時ファイルは、
  CLI自身のumaskで作られます。以前のバージョンが残したファイルは、起動のたびに背後で
  引き締めます。この処理はベストエフォートで、フォルダ外へ影響が及ばないよう
  シンボリックリンクとハードリンクは意図的に対象外にしています。
- **履歴の保持期間は、新規インストールでは既定180日です。** 経過した履歴は、アプリの起動時、
  新しい履歴の追加時、設定変更時に削除されます。すでに保存済みの保持期間の設定はそのまま
  読み戻されます。新しい既定値が効くのは、設定が保存されていない場合だけです。
  保持期間は設定画面でモードごとに変更でき、「無期限」も選べます。

### 既知の制限

- **macOSが「セキュア入力」が有効だと報告している間、Koedexは選択範囲を読み取りません。**
  これは、ネイティブアプリやSafari/Chromeの通常のパスワード入力欄をカバーします。
- **見た目は秘密情報のようでも、技術的には通常のテキスト欄でしかないフィールドは検知
  できません。** ワンタイムパスコード（2FA）の入力欄が代表例です。このような欄で
  文章を選択した状態のまま「AIに指示」を開始しないでください。
- **選択した文章やWeb検索結果はAIへ送られ、AIがどこに回答を置くかにも影響し得ます。**
  結果を鵜呑みにせず、必ず内容を確認してから利用してください。
- **読み取りのために選択範囲をコピーしたあと、取り込みが中止された場合、コピーされた文章が
  クリップボードに残ります。** 「セキュア入力」が有効になった場合、フォーカスが別の場所へ
  移った場合、処理が取り消された場合のいずれでも起こります。Koedexはその文章を使いませんが、
  元のクリップボードの内容を戻すことはできません。
- **クリップボードを経由する挿入経路では、それまでの内容が失われることがあります。**
  クリップボードモードと、サポート専用のMail・Chrome版Googleドキュメント向け代替手段は、
  貼り付けのためにクリップボードを差し替えます。その途中で失敗した場合、以前の内容は
  復元されない可能性があります。どちらも、ご自身で有効にしない限りOFFです。

## インストール

所要時間: 15〜40分（大半はダウンロードとビルドの待ち時間）
あなたの操作が必要な場面は3回だけです。

1. 開発ツールの更新時にMacのパスワードを入力（すでに最新なら不要）
2. 証明書を信頼する認証ダイアログの承認（Touch IDまたはパスワード、1回）
3. アプリ起動後の権限許可3つ（マイク・音声認識・アクセシビリティ）

### A. エージェントに任せる（ターミナル操作がほぼ不要）

[docs/agent-install-prompt.md](docs/agent-install-prompt.md) のプロンプトをコピーして、
Claude CodeまたはCodex CLIに貼り付けるだけで導入できます。

### B. 自分でコマンドを実行する

#### 作業フォルダを選ぶ

デスクトップと書類フォルダは、iCloud Driveの「デスクトップと書類フォルダ」同期の対象になっている
ことが多く、同期が付ける拡張属性があるとmacOSがコード署名を拒否します。`scripts/make_app.sh`は
署名の直前に、自身が作った組み立て用の複製から拡張属性を取り除くため、多くの場合はそのまま
ビルドできます。確実を期すなら`~/Downloads`や`~/Developer`など、同期対象外の場所を使ってください。

署名の段階で`resource fork, Finder information, or similar detritus not allowed`が出た場合は、
同期対象外の場所へcloneし直してください。**移動（`mv`）では拡張属性がそのまま残るため解決しません。**

#### ソースを取得する

<!-- BEGIN KOEDEX_SOURCE_PIN_JA -->
公式リポジトリから、リリース `v0.1.8` の一点だけを clone します。最新の状態（`main`）ではなく、
この版だけを取得してください。`Koedex` という名前のフォルダが既にある場所では実行しないでください。

```bash
git clone --branch v0.1.8 --single-branch https://github.com/GrShin5/Koedex.git Koedex \
  && cd Koedex
```

**次の照合がすべて ✅ になるまで、リポジトリ内のスクリプトを1つも実行しないでください。**
clone してできたフォルダの中で、以下をそのまま貼り付けて実行します。

```bash
export GIT_TERMINAL_PROMPT=0
OFFICIAL_URL="https://github.com/GrShin5/Koedex.git"
EXPECTED_TAG="v0.1.8"
ok=1
fail() { echo "❌ $1"; ok=0; }
git rev-parse --is-inside-work-tree >/dev/null 2>&1 \
  && echo "✅ clone したフォルダの中にいる" || fail "clone したフォルダの中にいない"
origin_url="$(git remote get-url origin 2>/dev/null)"
[ -n "$origin_url" ] && [ "${origin_url%.git}" = "${OFFICIAL_URL%.git}" ] \
  && echo "✅ 取得元URLが公式と一致" || fail "取得元URLが公式と不一致"
head_sha="$(git rev-parse HEAD 2>/dev/null)"
tag_sha="$(git rev-parse "${EXPECTED_TAG}^{commit}" 2>/dev/null)"
[ -n "$head_sha" ] && [ "$tag_sha" = "$head_sha" ] \
  && echo "✅ ローカルの ${EXPECTED_TAG} と HEAD が一致" || fail "ローカルの ${EXPECTED_TAG} と HEAD が不一致"
remote_sha="$(git ls-remote "$OFFICIAL_URL" "refs/tags/${EXPECTED_TAG}^{}" 2>/dev/null | cut -f1)"
[ -n "$remote_sha" ] || remote_sha="$(git ls-remote "$OFFICIAL_URL" "refs/tags/${EXPECTED_TAG}" 2>/dev/null | cut -f1)"
[ -n "$remote_sha" ] && [ -n "$head_sha" ] && [ "$remote_sha" = "$head_sha" ] \
  && echo "✅ GitHub上の ${EXPECTED_TAG} と HEAD が一致" || fail "GitHub上の ${EXPECTED_TAG} を確認できないか HEAD と不一致"
status_out="$(git status --porcelain 2>/dev/null)"; status_rc=$?
[ "$status_rc" = 0 ] && [ -z "$status_out" ] \
  && echo "✅ 作業ツリーに変更も未追跡ファイルも無い" || fail "作業ツリーが clean でないか確認できない"
[ "$ok" = 1 ] && echo "→ すべて一致しました。次へ進めます。" \
              || echo "→ 一致しない項目があります。ここで中止してください。"
```

❌ が1つでも出たら、そこで中止してください。別のURL、別のタグ、ZIPダウンロード、ミラーなど、
別の取得方法へ切り替えないでください。

タグはあとから移動されうるため、GitHub の Releases 画面で `v0.1.8` が immutable release として
公開されていることも確認してください。GitHub CLI を使える場合は、次のコマンドでも確認できます。

```bash
gh release verify v0.1.8 --repo GrShin5/Koedex
```
<!-- END KOEDEX_SOURCE_PIN_JA -->

#### 事前チェック

ビルド前に以下を実行すると、必要な条件をまとめて確認できます。不足があれば、やるべきことが
一覧で表示されます。

```bash
bash scripts/preflight.sh
```

```bash
# 照合済みのクローンの中で実行します

# 実行ファイルだけをビルド
swift build

# .appバンドルの組み立て（dist/Koedex.appを生成）
./scripts/make_app.sh debug
```

#### Swiftのバージョンが足りない場合

Command Line Toolsが入っていても、バージョンが古い場合があります。以下で更新してください。

```bash
softwareupdate --list
sudo softwareupdate --install "<--list の出力からコピーしたラベル>"
```

ラベル名は版ごとに変わるため、固定の文字列ではなく`--list`の出力からコピーしてください。
ダウンロードサイズは約900MB、所要時間は10〜30分で、**管理者パスワードが必要です**。

#### 今後の配布について

現在、ビルド済みの配布物は提供していません。配布物を準備する場合は、この公式リポジトリの対応する
release tagから作ったcleanなcloneを使います。別の作業用コピーから作った`.app`は配布しません。

#### コード署名証明書（初回のみ）

`scripts/make_app.sh` は ad-hoc署名の`.app`を作成しません。ad-hoc署名はビルドごとにアイデンティティが
変わり、署名が変わるたびにmacOSがアクセシビリティ／マイク／音声認識の権限を無効化してしまうためです。
代わりに、安定したローカル自己署名証明書「Koedex Dev」が必要です。

証明書の作成にはOpenSSL 3が必要です。macOS標準の`openssl`はLibreSSLであり、そのままでは動作しません。
スクリプトは自動でOpenSSL 3を探しますが、見つからない場合は次でインストールしてください。

```bash
brew install openssl@3
```

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

#### 証明書の削除

「Koedex Dev」証明書が不要になった場合（例: このMacでのKoedexビルドを終える場合）は、
以下の手順で削除します。

1. 実際に入っているか確認します。

   ```bash
   security find-identity -v -p codesigning
   ```

2. ログインキーチェーンから証明書と秘密鍵を削除します。

   ```bash
   security delete-identity -c "Koedex Dev" "$HOME/Library/Keychains/login.keychain-db"
   ```

3. 信頼設定の残骸を削除します。証明書自体を削除した後も、macOSが孤立した信頼設定を
   残すことがあります。この手順には確実なコマンドライン手段がないため、
   「キーチェーンアクセス.app」を開き、**証明書**カテゴリで「Koedex Dev」を検索し、
   まだ残っていれば削除してください。

#### ビルド成功の判定基準

エージェントに委任した場合の誤判定を防ぐため、ビルドが成功したかどうかは以下すべてで判定してください。

1. スクリプトの終了コードが0
2. `dist/Koedex.app`が存在する
3. `codesign --verify --deep --strict dist/Koedex.app`が成功する

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

## 既存インストールの更新

`scripts/install_app.sh`は、`/Applications/Koedex.app`が既に存在する場合、上書きせずエラーで
停止します。そのため更新は「まず旧アプリを退避し、空いた場所へ新しいアプリを入れる」という
手順になります。

AIエージェントに更新を任せる場合は、
[docs/agent-update-prompt.md](docs/agent-update-prompt.md)のプロンプトをコピーして貼り付けてください。

1. 現在インストールされているアプリを削除せず、退避します。
   `mv /Applications/Koedex.app ~/Desktop/Koedex-old.app`
   （`/Applications`の外であれば、退避先はどこでも構いません）
2. **新しく作ったフォルダへ**、上の[ソースを取得する](#ソースを取得する)と同じ手順で新しいリリース
   タグをcloneします。既存のcloneをそのまま更新して使い回さないでください。
3. ビルドします。`./scripts/make_app.sh release`
   退避したアプリを残してある場合は、`--previous-app ~/Desktop/Koedex-old.app`を付けると、
   ビルドが退避アプリとの署名の連続性を検証し、
   `更新互換性OK: bundle ID、Designated Requirement、署名者証明書は連続しています。`と表示します。
4. インストールします。`bash scripts/install_app.sh`
   手順1で`/Applications/Koedex.app`を空にしてあるため、ここで初めて成功します。

**権限は引き継がれるため、あらためて許可し直す必要はありません。** このリポジトリからビルドする限り、
bundle IDと署名identityは変わらず、`scripts/make_app.sh`自身がその連続性を検証します（手順3参照）。
macOSはマイク・音声認識・アクセシビリティの許可を、個々の`.app`ファイルではなくこのidentityに
紐付けているため、新しいビルドは古いアプリへ許可した内容をそのまま引き継ぎます。

**ただし、すでに壊れている権限は更新しても直りません。** Koedexの画面では権限が「許可済み」に
なっているのに録音や貼り付けが動かず、しかもシステム設定 →「プライバシーとセキュリティ」→
マイク／音声認識／アクセシビリティのどの一覧にもKoedexが表示されない場合、それはこのMacに
以前あったインストールが残した古いmacOS権限（TCC）の記録です。アプリを更新しても、この記録は
変わりません。実際に不具合のあったMacで、この対処により解消することを確認しています。
対処するには、Koedexを終了してから、次の3つを**`sudo`を付けずに**実行してください。

```bash
tccutil reset Microphone com.koedex.app
tccutil reset SpeechRecognition com.koedex.app
tccutil reset Accessibility com.koedex.app
```

そのあとKoedexを開き直し、[3つの権限付与手順](#3つの権限付与手順)のとおり、通常どおり許可し
直してください。

## 使い方

- 任意のアプリでカーソルをテキスト入力欄に置いた状態で、**fnキー**を押すと録音が始まります。
  もう一度**fnキー**を押すと停止し、文字起こし→AI整形→カーソル位置への貼り付け、が自動で行われます。
- 処理中は、画面下部の小さなフローティングHUDに「録音中」「整形中」などの状態が表示されます。
- メニューバーアイコンから「設定…」を開くと、AI整形のオン/オフ、カスタムインストラクション、履歴、
  ユーザー辞書を管理できます。
- ホットキーは設定画面で変更できます。既定はfnキー（`0x3F`）です。
- **挿入時に、あらかじめ決めた「画面に現れない文字」だけを取り除きます。** 対象は、ゼロ幅
  スペース、ワードジョイナー、制御文字、双方向の上書き・分離文字、タグ文字です。これは
  除去対象を列挙した一覧であって、あらゆる不可視文字を捕捉する保証ではありません。改行、
  タブ、箇条書きの記号や番号を含む可視文字は一切変更しないため、AI整形が作るリストや段落の
  形はそのまま保たれます。絵文字を連結する文字や漢字の異体字を指定する文字も、表示に影響
  するため除去しません。なお、これが効くのは挿入の瞬間です。結果ウィンドウや履歴一覧から
  コピーした文字列は、そのまま渡されます。

### AIに指示

「AIに指示」は、単なる文字起こしではなくAIに何かをしてもらうための、別系統のワンタップ操作です。

- 既定のバインドは、開始が**fn + Space**、停止が**fn**です（いずれも変更可能）。
- **録音開始時に文章を選択している場合**：話した指示が、選択した文章に対して適用されます
  （要約・翻訳・書き換えなど）。結果は、停止時点で元のキャレット位置が安全だと確認できた場合に
  貼り付けられます。この厳格な確認に失敗した場合は、盲目的に挿入せず、コピー可能な別ウィンドウに
  表示されます。ただし互換入力モードが有効な場合は、キー送出による代替経路で入力されます。
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

## 開発

```bash
# ビルド
swift build

# .appバンドルの組み立て — 3つのターゲットに対応しています
./scripts/make_app.sh debug                  # dist/Koedex.app、debugビルド
./scripts/make_app.sh release                # dist/Koedex.app、releaseビルド
./scripts/make_app.sh onboarding-debug        # dist/Koedex Debug.app、初回セットアップ確認用の隔離環境

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

`onboarding-debug`は独自の
`~/Library/Application Support/Koedex Debug/`データ領域を使うため、普段使いのKoedexの設定・
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
`enable`を実行してください。`onboarding-debug`のビルドでも拒否されます。

実行前にKoedexを終了してください。起動中はコマンド側が拒否します（アプリとコマンドが同時に
設定ファイルを持たないようにするためです）。

## ライセンス

Koedexは[Apache License 2.0](LICENSE)の下で公開されています。帰属表示とOpenAIとの非提携についての
注記は[NOTICE](NOTICE)も参照してください。
