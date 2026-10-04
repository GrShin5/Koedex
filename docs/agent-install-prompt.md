# Install Koedex with an AI agent

This guide lets people who are not comfortable with Terminal ask Codex or Claude Code to
download, build, and install Koedex in one guided task. Copy and paste the prompt below.

## Before you start

- The default working folder is `~/Developer`, and the clone destination is
  `~/Developer/Koedex`.
- Use `~/Downloads/Koedex` only when `~/Developer` cannot be created or used.
- Avoid Desktop, Documents, iCloud Drive, and other File Provider locations.
- Do not reuse an earlier clone or a non-empty folder. If the destination already exists,
  have the agent stop instead of deleting it.
- In a desktop AI-agent client, select `~/Developer` as the working folder first. In a
  Terminal client, the prompt chooses an appropriate location regardless of the folder from
  which the client was started.

A public repository can be impersonated under the same name, so a URL alone is not enough.
This procedure checks the official HTTPS URL, release tag, remote, local HEAD, tag on GitHub,
and immutable release before it runs any script in the repository.

## Pinned source

This version pins the official URL `https://github.com/GrShin5/Koedex.git`, release tag
`v0.1.10`, and GitHub immutable-release verification.

> **For people updating the public release:** A Git commit SHA is calculated from, among other
> things, the commit's own contents, so it cannot be written into that same commit in advance.
> For a new release, update the tag in this prompt and in both manuals together, enable release
> immutability on GitHub, and only then publish the release. Never use `main` or a mutable tag
> as an installation reference.

## Recommended models (as of 2026-08-24)

- Codex: `GPT-5.6-Terra` / `medium`
- Claude Code: `Sonnet 5` / `medium` when available; otherwise `default` / `medium`

You do not need to force a model or effort level that is unavailable. Use the client's default
effort when it offers no effort control. Check Claude Code's current options and configuration
at its [official model-configuration guide](https://code.claude.com/docs/en/model-config) when
you run the task. These settings select the AI agent that performs the installation; they are
separate from Koedex's in-app AI-model setting.

## Why the agent may pause for your decision

The agent reports all read-only preflight results together. It must, however, explain the
following actions and ask for approval immediately before carrying them out:

- creating a certificate, importing it into the login Keychain, or setting it to Always Trust;
- writing to `/Applications`;
- handling Gatekeeper checks or granting Microphone, Speech Recognition, or Accessibility
  permissions.

The number of confirmations cannot be promised in advance. If a network or sandbox approval
blocks the process, the agent may retry the **same URL, same ref, and same command** after
approval. It must not independently switch to another source or installation method.

Removing an earlier Koedex.app can leave macOS permissions (TCC) or an earlier signing
certificate behind. That is not automatically a problem. The agent does not reset TCC or
automatically delete old certificates or app data; follow macOS's on-screen instructions only
when it asks for permission again, such as after a signing change.

## Copy-and-paste prompt

<!-- BEGIN KOEDEX_AGENT_INSTALL_PROMPT_EN -->
```text
Build and install the Koedex macOS app from its official GitHub repository. I am not
comfortable with Terminal. Explain each action in plain English, including exactly what I
need to look for or click, instead of asking me questions that only use engineering terms.

PINNED SOURCE
- Official URL: https://github.com/GrShin5/Koedex.git
- Release tag: v0.1.10
- Verification method: GitHub immutable release

WORKING LOCATION
1. Use ~/Developer as the default parent and ~/Developer/Koedex as the clone destination.
2. Only if ~/Developer cannot be created or used, offer ~/Downloads/Koedex instead.
3. Do not work in Desktop, Documents, iCloud Drive, another File Provider location, or
   through a symlink.
4. If the destination already exists, contains anything, is a symlink, or is an existing
   clone with uncommitted changes, do not delete, overwrite, or reuse it. Report its location
   and state in plain language, then stop.

HOW TO PROCEED
- Complete all read-only preflight checks first, then report every finding and all action I
  need to take in one batch. Do not interrupt me once per finding.
- Still ask immediately before a safety-sensitive action such as changing Keychain,
  writing to /Applications, handling Gatekeeper, or granting macOS permissions. Explain
  what will change and wait for my approval. Do not promise a fixed number of pauses.
- If sandbox or network approval caused a command to fail, after approval you may retry the
  same URL, ref, and command once. Do not independently switch to another URL, ref, mirror,
  ZIP download, or installation method.

FETCH AND VERIFY
1. Clone v0.1.10 into the new destination using a command equivalent to:
   git clone --branch v0.1.10 --single-branch https://github.com/GrShin5/Koedex.git <new-destination>
2. Before running any repository script, verify all of the following:
   - origin's fetch URL matches https://github.com/GrShin5/Koedex.git
     (you may treat only a trailing .git as equivalent during comparison)
   - the local v0.1.10 tag's commit exactly equals HEAD
   - refs/tags/v0.1.10 returned by git ls-remote against the official URL exactly equals HEAD
   - GitHub's official releases/tags/v0.1.10 API reports tag_name=v0.1.10 and immutable=true
   - if GitHub CLI is already available, gh release verify v0.1.10 --repo GrShin5/Koedex also succeeds
   - the checkout is clean and has no untracked files
3. If any value differs, the release is missing or not immutable, or a value cannot be
   verified, do not run a repository script. Report the values you could verify in a table
   and stop.

PREFLIGHT
Only after every source check passes, run this inside the clone:
  KOEDEX_LANG=en bash scripts/preflight.sh --install
Review the complete output for macOS, Swift, Command Line Tools, Codex CLI, OpenSSL 3,
Keychain, free disk space, working location, and /Applications/Koedex.app. Report every
PASS/WARN/FAIL in one batch. Do not treat an inaccessible Keychain as an absent certificate
or a broken signature. If /Applications/Koedex.app exists as an app, regular file, or
symlink, do not overwrite or delete it; stop.

BUILD AND INSTALL
1. Only if a signing identity is absent, explain before running
   bash scripts/make_signing_cert.sh that it creates a self-signed code-signing certificate,
   imports it into the login Keychain, and marks it Always Trust for code signing, which
   triggers a macOS authentication dialog. Wait for my approval.
2. After approval, run that script and verify success. If Keychain is inaccessible, do not
   recreate or delete anything; stop.
3. Run ./scripts/make_app.sh release.
4. Verify exit status zero, dist/Koedex.app exists, bundle ID is com.koedex.app, its deep
   strict signature is valid, and its signer fingerprint can be read.
5. Before running bash scripts/install_app.sh, explain that it makes a new installation from
   dist/Koedex.app to /Applications and never overwrites an existing Koedex.app. Wait for my
   approval.
6. After approval, run bash scripts/install_app.sh with no arguments. Do not switch to a
   manual copy or alternate destination.
7. Verify the installed bundle ID, deep strict signature, signer fingerprint, and identity
   continuity with the source app, then report the results.

DO NOT CHANGE
- Do not modify anything under ~/.codex/ and do not reset TCC permissions.
- Do not automatically delete an existing app, old certificate, Keychain item, Koedex
  settings, or history.
- Do not fetch or run scripts from outside the repository or install new software on your
  own.
- Do not independently use sudo, delete or overwrite files, disable Gatekeeper, or broadly
  remove quarantine attributes.

FINAL REPORT
1. Working location and the verified origin, tag, and HEAD
2. Every preflight, build, install, and signature PASS/WARN/FAIL
3. Safe first launch in Finder and what to do if Gatekeeper blocks it
4. How to grant Microphone, Speech Recognition, and Accessibility permissions
5. How to verify the Codex CLI connection and what to do if it is unavailable
6. State that old macOS permissions or signing records can remain after deleting an older
   app, and that you did not automatically reset or delete them
```
<!-- END KOEDEX_AGENT_INSTALL_PROMPT_EN -->

# Koedexの導入をAIエージェントに任せる

この文書は、ターミナル操作に不慣れな方が、CodexまたはClaude CodeへKoedexの取得・
ビルド・インストールをまとめて依頼するためのものです。下のプロンプトをそのまま
貼り付けてください。

## 始める前に

- 既定の作業場所は `~/Developer`、clone先は `~/Developer/Koedex` です。
- `~/Developer`を作れない場合だけ、`~/Downloads/Koedex`を使います。
- Desktop、Documents、iCloud Drive、その他のFile Provider配下は避けます。
- 以前のcloneや中身のあるフォルダは再利用しません。clone先が存在する場合は、
  エージェントに削除させず、作業を止めてください。
- デスクトップ版のAIエージェントでは、まず `~/Developer` を作業フォルダとして選びます。
  ターミナル版では、どのフォルダから起動しても、プロンプトが適切な場所を選びます。

公開リポジトリは同名の偽物を作れるため、URLだけでは十分ではありません。この手順では、
公式HTTPS URL、リリースタグ、remote、ローカルHEAD、GitHub上のtag、変更不能なreleaseを
すべて照合し、一致するまでリポジトリ内のスクリプトを実行しません。

この版で固定している取得元は次のとおりです。

| 項目 | 固定値 |
| --- | --- |
| 公式URL | `https://github.com/GrShin5/Koedex.git` |
| リリースタグ | `v0.1.10` |
| 検証方式 | `GitHub immutable release` |

> **公開版を更新する方へ**：Gitのcommit SHAは、そのcommit自身の本文を含めて計算されるため、
> 同じcommit内へ自分自身のSHAを事前記載することはできません。新しいリリースではプロンプトと
> 日英マニュアルのタグを同時に更新し、GitHub側でrelease immutabilityを有効にしてからreleaseを
> 公開してください。`main`や変更可能なtagだけをインストール手順に使わないでください。

## 推奨モデル（2026-08-24時点）

| エージェント | 推奨 |
| --- | --- |
| Codex | `GPT-5.6-Terra` / `medium` |
| Claude Code | 利用できる場合は `Sonnet 5` / `medium`。なければ `default` / `medium` |

選択肢にないモデルやeffortを無理に指定する必要はありません。effortを選べない環境では
既定値を使ってください。Claude Codeの現在の選択肢と設定方法は、実行時に
[公式のモデル設定資料](https://code.claude.com/docs/en/model-config)で確認してください。
ここで選ぶモデルは**導入を担当するAIエージェントのモデル**であり、Koedexアプリ内の
AIモデル設定とは別です。

## 途中で確認が必要になる理由

エージェントは事前チェックの結果を一括で説明します。ただし、次の操作は安全上、
実行直前に説明して承認を求めます。

- 証明書の作成、ログインキーチェーンへのimport、「常に信頼」の設定
- `/Applications`への書込み
- Gatekeeperの確認、マイク・音声認識・アクセシビリティ権限

確認回数を固定して約束することはできません。ネットワークやsandboxの承認で止まった場合、
承認後に**同じURL・同じref・同じコマンド**を再実行することは許可していますが、別の取得元や
別方式へ独断で切り替えることは禁止しています。

以前のKoedex.appを削除しても、macOSの権限（TCC）や以前の署名証明書が残ることがあります。
これは直ちに異常を意味しません。エージェントはTCCをresetせず、古い証明書やアプリデータも
自動削除しません。署名が変わった場合など、macOSが再許可を求めたときだけ画面の案内に従って
ください。

## 日本語のコピペ用プロンプト

<!-- BEGIN KOEDEX_AGENT_INSTALL_PROMPT_JA -->
```text
KoedexというmacOSアプリを、公式GitHubリポジトリから取得してビルドし、インストールしてください。
私はターミナル操作に不慣れです。技術用語だけで質問せず、私が画面上で何を確認・操作すれば
よいかを平易な日本語で説明してください。

【固定する取得元】
- 公式URL: https://github.com/GrShin5/Koedex.git
- リリースタグ: v0.1.10
- 検証方式: GitHub immutable release

【作業場所】
1. 既定の親フォルダは ~/Developer、clone先は ~/Developer/Koedex としてください。
2. ~/Developerを作成・使用できない場合だけ、~/Downloads/Koedexを候補にしてください。
3. Desktop、Documents、iCloud Drive、File Provider配下、symlink先では作業しないでください。
4. clone先がすでに存在する、中身がある、symlinkである、または既存cloneに未commit変更がある
   場合は、削除・上書き・再利用せず、場所と状態を平易に報告して止まってください。

【進め方】
- 小さな確認を1件ずつ出さず、最初に読み取り専用の事前チェックを最後まで行い、結果と私に
  必要な作業を一括で報告してください。
- ただし、Keychainの変更、/Applicationsへの書込み、Gatekeeper、macOS権限など、安全上必要な
  承認は実行直前に、何が変わるかを説明して私の承認を待ってください。確認回数を固定しないで
  ください。
- sandboxまたはnetworkの承認が原因で失敗した場合、承認後に同じURL・同じref・同じコマンドを
  1回再実行して構いません。別URL、別ref、ミラー、ダウンロードZIP、別のインストール方式へ
  独断で切り替えないでください。

【取得と照合】
1. 選んだ新規clone先へ、次の内容と等価な方法でv0.1.10をcloneしてください。
   git clone --branch v0.1.10 --single-branch https://github.com/GrShin5/Koedex.git <新規clone先>
2. clone直後、スクリプトを1つも実行する前に、次をすべて確認してください。
   - originのfetch URLが https://github.com/GrShin5/Koedex.git と一致する
     （比較時だけ末尾の.gitの有無を同一視して構いません）
   - ローカルのv0.1.10 tagが指すcommitとHEADが完全一致する
   - 公式URLへのgit ls-remoteで得たrefs/tags/v0.1.10もHEADと完全一致する
   - GitHub公式APIのreleases/tags/v0.1.10が、tag_name=v0.1.10かつimmutable=trueを返す
   - GitHub CLIをすでに利用できる場合は、gh release verify v0.1.10 --repo GrShin5/Koedexも成功する
   - checkoutがcleanで、未追跡ファイルもない
3. 1つでも一致しない、releaseが存在しない・immutableでない、取得結果を確認できない、
   別refへ誘導された場合は、
   リポジトリ内のスクリプトを実行せず、確認できた値を表で報告して止まってください。

【事前チェック】
取得元の照合がすべて通った後だけ、clone内で次を実行してください。
  bash scripts/preflight.sh --install
macOS、Swift、Command Line Tools、Codex CLI、OpenSSL 3、Keychain、空き容量、作業場所、
/Applications/Koedex.appの有無を含む全結果を確認し、PASS/WARN/FAILを省略せず一括報告してください。
Keychainへアクセスできない状態を「証明書なし」や「署名破損」と決めつけないでください。
/Applications/Koedex.appがapp、通常ファイル、symlinkのいずれかで存在した場合は、上書き・削除
せず止まってください。

【ビルドとインストール】
1. 署名用identityがない場合だけ、bash scripts/make_signing_cert.sh の実行前に、次の3点を説明し、
   承認を待ってください。
   - 自己署名のコード署名証明書を作る
   - ログインキーチェーンへimportする
   - コード署名で使えるよう「常に信頼」を設定し、認証画面が出る
2. 承認後に同スクリプトを実行し、成功を確認してください。Keychainがinaccessibleなら、勝手な
   作り直しや削除をせず止まってください。
3. ./scripts/make_app.sh release を実行してください。
4. 終了コードが0、dist/Koedex.appが存在、bundle IDがcom.koedex.app、deep strict署名が有効、
   signer fingerprintが取得できることを確認してください。
5. bash scripts/install_app.sh の実行前に、dist/Koedex.appを/Applicationsへ新規配置し、既存の
   Koedex.appは上書きしないことを説明して、承認を待ってください。
6. 承認後に bash scripts/install_app.sh を引数なしで実行してください。手作業のcopyや別名配置へ
   切り替えないでください。
7. 配置後のbundle ID、deep strict署名、元appとのsigner fingerprintおよびidentity continuityを
   検証し、結果を報告してください。

【変更してはいけないもの】
- ~/.codex/配下を変更しないでください。
- TCC権限をresetしないでください。
- 既存app、古い証明書、Keychain項目、Koedexの設定や履歴を自動削除しないでください。
- リポジトリ外のスクリプトを取得・実行せず、新しいソフトウェアを勝手にインストールしないで
  ください。
- sudo、削除、上書き、Gatekeeper無効化、quarantine属性の一括削除を独断で行わないでください。

【完了報告】
1. 実際に使った作業場所、origin、tag、HEADの照合結果
2. preflight、build、install、署名検証のPASS/WARN/FAIL
3. 私がFinderで初回起動する手順と、Gatekeeperに止められた場合の安全な開き方
4. マイク・音声認識・アクセシビリティ権限の許可手順
5. Codex CLI接続確認と、接続できない場合の対処
6. 旧アプリを削除しても権限や以前の署名が残る場合があり、自動reset・自動削除はしていないこと
```
<!-- END KOEDEX_AGENT_INSTALL_PROMPT_JA -->
