# Koedexの導入をエージェントに任せるためのプロンプト

*This file contains ready-to-paste prompts for delegating the Koedex build-and-install
process to an AI coding agent (Claude Code or Codex CLI). Everything below this line is in
Japanese; jump to [English versions](#english-versions-concise) at the bottom for a shorter
English-language equivalent of each prompt.*

ターミナル操作に不慣れな人が、Claude CodeやCodex CLIにKoedexの導入を丸ごと任せるための
プロンプト集です。プロンプトをコピーして、エージェントのチャットにそのまま貼り付けてください。

Koedex の公式リポジトリは <https://github.com/GrShin5/Koedex> です。GitHubには誰でも同名の
リポジトリを作れるため、以下のプロンプトはエージェントに対し、clone直後にこのURLとの一致を
確認させ、一致しなければそこで作業を止めさせるよう指示しています。

この確認は、**エージェントが独自に別の取得元を選んだ場合**と、**すでに手元にある別のcloneで
作業を始めようとした場合**に効きます。プロンプトどおりに進めば一致するのが当たり前なので、
URLそのものの正しさを保証するものではありません。**上のURLがKoedexの公式であることは、
この文書を配布した経路（このリポジトリ自身）を信頼して確かめてください。**

公式リポジトリにはリリースタグが付いています（`v0.1.0` 以降）。**下のプロンプトは既定で
リリースタグ `v0.1.4` を取得します。** 固定すると取得のたびに同じ中身になりますが、
その後の修正は入りません。

開発中の最新版（`main` ブランチ）を試したい場合は、プロンプトの clone 行を
`git clone https://github.com/GrShin5/Koedex.git` に書き換えてください。**ただし
`main` は常に変化するため、あなたが読んでいるこの説明書の内容と食い違うことがあります。**

## 設計方針: 「人間のゲートを最初にまとめる」

途中で何度も作業が止まり、そのたびに判断とターミナル操作を求められる、という進め方は
体験を大きく損ないます。目指すのは次の流れです。

```
開始 → 前提を一括チェック → 「あなたがやることはこの3つです」とまとめて提示 →
ユーザーが実施 → エージェントが最後まで自動実行 → 完了
```

ポイントは「1件見つけるたびに止まらない」ことです。前提チェックを全項目走らせてから、
不足を**まとめて**報告するよう、プロンプト側で明示的に指示しています。

## あなたが事前に知っておくこと: あなたがやること3つ

macOSの仕様上、エージェントがどうしても代行できない操作は3種類だけです。

| # | やること | 所要 | なぜ必要か |
| --- | --- | --- | --- |
| 1 | ターミナルで1行を実行し、Macのパスワードを入力 | 10〜30分（ダウンロード待ち。すでに開発ツールが最新なら不要） | 開発ツールの更新に管理者権限が要るため |
| 2 | 認証ダイアログでTouch ID／パスワードを1回承認 | 5秒 | 自己署名証明書をログインキーチェーンへ取り込み、macOSに信頼させるため |
| 3 | アプリ起動後、権限ダイアログを3つ許可（マイク／音声認識／アクセシビリティ） | 1分 | 音声入力と貼り付けに必要なため |

## プロンプトA: Claude Code用（そのままコピーして貼り付け）

````
KoedexというmacOSアプリを、GitHubからソースを取得してビルドし、インストールしてください。
私はターミナルの操作に不慣れです。以下の方針を必ず守ってください。

# 最重要の方針
作業を細かく中断しないでください。まず「事前チェック」を全項目まとめて実行し、
私がやるべきことが何件あるのかを一度に提示してください。
1件見つけるたびに止まって私に聞く、という進め方はしないでください。

# ステップ1: 取得と事前チェック
Koedexの公式リポジトリは https://github.com/GrShin5/Koedex です。
iCloud同期の対象外の場所（例: ~/Downloads/Koedex）へ、以下のコマンドでcloneしてください。
デスクトップと書類フォルダは同期対象になっていることが多いので避けてください。

    git clone --branch v0.1.4 --depth 1 https://github.com/GrShin5/Koedex.git

（開発中の最新版が必要な場合のみ、`--branch v0.1.4 --depth 1` を外して `main` を
取得してください。ただし `main` は常に変化するため、この説明書の内容と食い違う
ことがあります。）

clone直後に、取得元が公式リポジトリと完全に一致するかを確認してください。

    git remote -v
    git describe --tags
    git status

出力されたURLが https://github.com/GrShin5/Koedex（末尾に.gitが付く場合を含む）と
完全に一致しない場合は、そこで作業を止め、一致しない旨を私に報告してください。
`git describe --tags` と `git status` の結果もあわせて報告してください。
事前チェックを含め、以降の手順には絶対に進まないでください。

一致を確認できたら、cloneしたディレクトリの中で、以下を実行してください。これは読み取り専用で、何も変更しません。

    bash scripts/preflight.sh

結果を日本語の表で報告してください。不足があっても途中で止まらず、
スクリプトの出力をすべて確認してから次に進んでください。

# ステップ2: 私がやることの一括提示
事前チェックの結果、私の操作が必要なもの（管理者パスワードが要るもの等）があれば、
それを「あなたがやること」として番号付きで一度にまとめて提示してください。
コマンドは1行ずつ、コピーしやすい形で示してください。
私が「終わりました」と言うまで待ってください。

# ステップ3: 自動実行
私の作業が終わったら、以下を最後まで自動で進めてください。

  1. ステップ1でcloneしたディレクトリで作業する（clone済みなので取得は不要です）
  2. bash scripts/make_signing_cert.sh を実行する「前」に、このスクリプトが何をするかを
     日本語で説明してください。説明には次の3点を含めてください。
       - 自己署名のコード署名証明書を新しく作ること
       - それをログインキーチェーンへ取り込むこと
       - コード署名に使えるよう「常に信頼」を設定すること（この設定でmacOSの認証ダイアログが出ます）
     説明したうえで、実行してよいか私に尋ね、承認を待ってください
  3. 承認が得られたら bash scripts/make_signing_cert.sh を実行してください。
     途中でmacOSの認証ダイアログが出るので、私がTouch IDかパスワードで承認します
     （この承認自体はあなたには代行できません）
  4. ./scripts/make_app.sh release でビルドする（数分かかります）
  5. できあがった dist/Koedex.app を /Applications へコピーする
  6. codesign --verify --deep --strict で署名を検証し、結果を報告する

# 守ってほしい制約
- 実行してよいのはこのリポジトリに含まれるスクリプトだけです。
  リポジトリ外から取得したスクリプトを実行しないでください。
  取得元が公式リポジトリ（https://github.com/GrShin5/Koedex）と一致しない場合は、
  スクリプトを1つも実行しないでください。
- 新しいソフトウェアを勝手にインストールしないでください。
  必要なものがあれば、何が必要かを私に伝えて止まってください。
- /Applications に既にKoedex.appがある場合、上書き・削除せず報告して止まってください。
- 私が依頼していないファイルの削除や設定変更をしないでください。
- 失敗したら別の方法を勝手に試さず、止まって日本語で状況を報告してください。
  make_app.sh は成功時に「=== 完了: ... ===」、失敗時に「=== 失敗: ... ===」を出力します。
  この表示と終了コード（0=成功 / 1=引数の指定ミス / 2=前提不足 / 3=ビルド失敗 / 4=署名失敗）で判定してください。
  出力の末尾だけを見て成功と判断しないでください。
- 各ステップの前に、これから何をするのかを日本語で説明してください。
- 管理者パスワードの入力、キーチェーンでの承認、権限ダイアログの許可は
  あなたには代行できません。必要になったら私が何をすればよいか説明して待ってください。

# 完了後に説明してほしいこと
1. 初回起動の方法（Gatekeeperに止められた場合の解除手順を含む）
2. 必要な権限（マイク・音声認識・アクセシビリティ）の許可手順
3. Codex CLIとの接続確認の方法と、接続できていない場合の対処
````

## プロンプトB: Codex CLI用

内容はプロンプトAとほぼ同じですが、Codex CLIはサンドボックスと承認モードの設定を持つため、
**書き込みが必要な作業（clone、ビルド、/Applicationsへの移動）を行えるモードで起動する
必要があります。** 既定の読み取り専用モードのままだと、途中で必ず詰まります。

プロンプトAの本文をコピーし、先頭に以下を追加して貼り付けてください。

````
あなたはmacOSのターミナルで作業します。破壊的な操作（削除・上書き・sudo）を
実行する前には必ず私に確認してください。読み取り専用の調査は確認不要で進めてください。

（この下に、プロンプトAの本文をそのまま続けて貼り付けてください）
````

## エージェントが誤判定しないための注意

`scripts/make_app.sh` は、成功時に `=== 完了: <パス> ===`、失敗時に
`=== 失敗: <理由> ===` を出力し、終了コードを用途別に分けています
（0=成功 / 1=引数の指定ミス / 2=前提不足 / 3=ビルド失敗 / 4=署名失敗）。エージェントに委任する場合、
出力の解析だけに頼らず、次のすべてで成功を判定してください。

1. スクリプトの終了コードが0
2. `dist/Koedex.app`が存在する
3. `codesign --verify --deep --strict dist/Koedex.app`が成功する

---

## English versions (concise)

Koedex's official repository is <https://github.com/GrShin5/Koedex>. Anyone can create a
repository with the same name on GitHub, so the prompts below tell the agent to check the
remote URL against that one immediately after cloning and to stop if it does not match.
That check catches the agent picking a different source on its own, and it catches starting
work in some other clone you already had. It does not vouch for the URL itself: **trust that
this URL is Koedex's official one only as far as you trust the channel that gave you this
document — this repository itself.**

The official repository carries release tags (`v0.1.0` onward). **The prompt below clones
the release tag `v0.1.4` by default**, so you get the same contents every time, without any
later fixes. If you want the latest in-development version instead, tell the agent to clone
`main` — but note that **`main` changes constantly, so it may differ from the manual you're
reading.**

### Prompt A (Claude Code)

````
Build and install a macOS app called Koedex from source on GitHub. I'm not comfortable with
the terminal, so please follow these rules:

- Don't stop repeatedly for small issues. Koedex's official repository is
  `https://github.com/GrShin5/Koedex`. Clone it with
  `git clone --branch v0.1.4 --depth 1 https://github.com/GrShin5/Koedex.git` into a location
  outside iCloud sync (Desktop and Documents usually are synced; `~/Downloads/Koedex` is
  fine). (Only if the latest in-development version is specifically needed, drop
  `--branch v0.1.4 --depth 1` and clone `main` instead — but `main` changes constantly, so it
  may differ from this manual.) Immediately after cloning, run `git remote -v`,
  `git describe --tags`, and `git status`, and confirm the remote URL matches
  `https://github.com/GrShin5/Koedex` exactly (with or without a trailing `.git`). If it
  doesn't match, stop right there, report it along with the `git describe --tags` and
  `git status` output, and do not proceed to any later step, including preflight — don't run
  any script. Once confirmed, run `KOEDEX_LANG=en bash scripts/preflight.sh` inside it — it
  is read-only — and report every finding at once as a table, not one at a time.
- After that, list everything that needs MY action (e.g. anything requiring an admin
  password) in one batch, with copy-pasteable one-line commands, and wait until I say I'm
  done.
- Then, in the clone you already made: before running `bash scripts/make_signing_cert.sh`,
  explain in plain language what it does — it creates a new self-signed code-signing
  certificate, imports it into my login keychain, and marks it "Always Trust" for code signing
  (which triggers a macOS authentication dialog) — then ask whether you may run it, and wait
  for my approval. Once approved, run `bash scripts/make_signing_cert.sh`; I'll approve the
  macOS authentication dialog with Touch ID or my password (only I can do that part). Then run
  `./scripts/make_app.sh release`, copy the resulting `dist/Koedex.app` to `/Applications`,
  and verify it with `codesign --verify --deep --strict`.
- Only run scripts that are part of this repository. If the clone's origin doesn't match the
  official repository above, don't run a single script. Don't install new software on your
  own — tell me what's missing and stop. Don't overwrite an existing
  `/Applications/Koedex.app`. Don't delete or change files I didn't ask about.
- `make_app.sh` prints `=== 完了: ... ===` on success and `=== 失敗: ... ===` on failure,
  with exit codes 0=success / 1=bad arguments / 2=missing prerequisite / 3=build failed /
  4=signing failed.
  Judge success by these, not by skimming the tail of the output. If anything fails, stop
  and report instead of trying something else on your own.
- Explain what you're about to do before each step. Password entry, keychain approval, and
  permission dialogs are things only I can do — tell me what to do and wait.

When done, explain: (1) how to open the app the first time, including how to get past
Gatekeeper if macOS blocks it, (2) how to grant
the three permissions (Microphone, Speech Recognition, Accessibility), (3) how to verify the
Codex CLI connection and what to do if it isn't connected.
````

### Prompt B (Codex CLI)

Same as Prompt A, but Codex CLI needs a sandbox/approval mode that allows writes (clone,
build, moving into `/Applications`) — the default read-only mode will get stuck partway
through. Prepend:

````
You're working in a macOS terminal. Always confirm with me before destructive actions
(delete, overwrite, sudo). Read-only investigation can proceed without asking.
````
