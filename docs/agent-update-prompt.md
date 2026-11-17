# Update Koedex with an AI agent

This guide lets people who already have Koedex installed ask Codex or Claude Code to update it
to a new release in one guided task. Copy and paste the prompt below.

If you are installing Koedex for the first time, use
[docs/agent-install-prompt.md](agent-install-prompt.md) instead.

## Before you start

Start the agent in a mode that can run commands and edit files, not plan mode or read-only mode.
If it starts in one of those modes, the prompt asks it to tell you so and show how to switch.
The normal mode that asks before running commands is enough; you do not need a full-access or
skip-permissions mode.

- **Requirement:** A working copy of Koedex must already be installed at
  `/Applications/Koedex.app`. If it is not, use
  [docs/agent-install-prompt.md](agent-install-prompt.md) instead.
- The default destination for the new clone is `~/Developer/Koedex-v0.2.1`. Use
  `~/Downloads/Koedex-v0.2.1` only when `~/Developer/Koedex-v0.2.1` cannot be created.
- **Do not delete, overwrite, or reuse the clone folder from the original installation** (for
  example, `~/Developer/Koedex`). The new clone must be a separately named, new folder.
- If the folder exists, automatically add -2, -3, and so on; never reuse or delete it.
- Avoid Desktop, Documents, iCloud Drive, and other File Provider locations.
- In a desktop AI-agent client, select `~/Developer` as the working folder first. In a
  Terminal client, the prompt chooses an appropriate location regardless of the folder from
  which the client was started.

A public repository can be impersonated under the same name, so a URL alone is not enough.
This procedure checks the official HTTPS URL, release tag, remote, local HEAD, tag on GitHub,
and immutable release before it runs any script in the repository. This is the same
verification used for a new installation.

## Pinned source

This version pins the official URL `https://github.com/GrShin5/Koedex.git`, release tag
`v0.2.1`, and GitHub immutable-release verification.

## Recommended models (as of 2026-11-17)

- Codex: `GPT-6.1-Sol` / `medium`
- Claude Code: `Sonnet 5.5` / `medium` when available; otherwise `default` / `medium`

You do not need to force a model or effort level that is unavailable. These settings select the
AI agent that performs the update; they are separate from Koedex's in-app AI-model setting.

## Why the agent may pause for your decision

The agent reports all read-only preflight results together. It must, however, explain the
following actions and ask for approval immediately before carrying them out:

- if a new certificate is required, importing it into the login Keychain and setting it to
  Always Trust (normally unnecessary because the original installation created it);
- switching to the new app after the build succeeds: quitting Koedex, moving the old app to
  `~/Developer/Koedex-backups/` (not deleting it), and installing the new app into
  `/Applications`. This is **one approval**, and any build warnings are explained with it;
- running **`tccutil reset`**, limited to the three commands below and only when the documented
  broken-permission symptom is actually present.

Your agent app may also show its own "Allow this command?" dialogs for these same steps; allow
them if the command matches what the agent just explained. The agent also stops if a check
fails or it needs you to do something. Every stop includes a reply you can send as-is.

The number of confirmations cannot be promised in advance. If a network or sandbox approval
blocks the process, the agent may retry the **same URL, same ref, and same command** after
approval. It must not independently switch to another source or installation method.

## Copy-and-paste prompt

<!-- BEGIN KOEDEX_AGENT_UPDATE_PROMPT_EN -->
```text
Update the Koedex macOS app already installed on this Mac to a newer release from its
official GitHub repository. I am not comfortable with Terminal. Explain each action in
plain English, including exactly what I need to look for or click, instead of asking me
questions that only use engineering terms.

ASSUMPTION
Koedex is already installed at /Applications/Koedex.app on this Mac. If it is not, stop and
use docs/agent-install-prompt.md instead.

PINNED SOURCE
- Official URL: https://github.com/GrShin5/Koedex.git
- Release tag: v0.2.1
- Verification method: GitHub immutable release

WORKING LOCATION
1. Use ~/Developer/Koedex-v0.2.1 as the new clone destination.
2. Only if ~/Developer cannot be created or used, offer ~/Downloads/Koedex-v0.2.1 instead.
3. Do not delete, overwrite, or reuse the clone folder from the original install (for
   example ~/Developer/Koedex). The new clone must be a separate, new folder.
4. Do not work in Desktop, Documents, iCloud Drive, another File Provider location, or
   through a symlink.
5. If the destination exists (including a symlink), automatically try -2, -3, and so on.
   Use a new folder; never delete, overwrite, or reuse an existing folder.

HOW TO PROCEED
- If you are in plan mode or read-only mode, say so in one sentence and show how to switch to a mode that can run commands and edit files. The normal mode that asks before running commands is enough; do not ask me for a full-access or skip-permissions mode. Do not silently return only a plan.
- Complete all read-only preflight checks first, then report every finding and all action I
  need to take in one batch. Do not interrupt me once per finding.
- A report alone is not a reason to wait. Stop only for the approvals below, a failed
  required check, or something only I can do; otherwise continue to the next step.
- Still ask before changing Keychain, before the switch-over in STEP 5 (one approval that
  covers quitting Koedex, moving the old app aside, and installing the new app), and before
  running tccutil reset. Explain what will change and wait for my approval. Do not promise
  a fixed number of pauses.
- If sandbox or network approval caused a command to fail, after approval you may retry the
  same URL, ref, and command once. Do not independently switch to another URL, ref, mirror,
  ZIP download, or installation method.

- A failed check in a sandbox or restricted environment is unconfirmed, not absent. For
  example, "cannot reach GitHub" or "0 certificates found" does not prove absence. Ask for
  approval to rerun the same read-only command with the needed access before concluding.
- Report compiler warnings, but they alone do not require a pause. For the build, stop on
  a non-zero exit code, error:, signing failure, or a ⚠️ line printed by the scripts, except
  the expected line saying /Applications/Koedex.app already exists (preflight prints it and
  the build repeats it). Also stop if the compatibility-OK line is missing. Keep all other safety checks.

WHENEVER YOU STOP
Show all six items: ① what is done; ② why you stopped; ③ whether the current app still
works (or is unconfirmed); ④ the recommended choice and an exact reply I can send, such as
"Proceed with this"; ⑤ what will run automatically after approval; ⑥ how to undo.
If a required check failed, recommend fixing it and rerunning that check, not bypassing it.
Never end with only "waiting for instructions".

STEP 1: CHECK THE CURRENT INSTALL
Read-only: confirm /Applications/Koedex.app exists and read its version. If absent, stop
and direct me to docs/agent-install-prompt.md. Leave the app in /Applications, and do not move or quit it, until the build succeeds.

STEP 2: FETCH AND VERIFY THE NEW VERSION
1. Clone v0.2.1 into the new destination using a command equivalent to:
   git clone --branch v0.2.1 --single-branch https://github.com/GrShin5/Koedex.git <new-destination>
2. Before running any repository script, verify all of the following:
   - origin's fetch URL matches https://github.com/GrShin5/Koedex.git
     (you may treat only a trailing .git as equivalent during comparison)
   - the local v0.2.1 tag's commit exactly equals HEAD
   - refs/tags/v0.2.1 returned by git ls-remote against the official URL exactly equals HEAD
   - GitHub's official releases/tags/v0.2.1 API reports tag_name=v0.2.1 and immutable=true
   - if GitHub CLI is already available, gh release verify v0.2.1 --repo GrShin5/Koedex also succeeds
   - the checkout is clean and has no untracked files
3. If any value differs, the release is missing or not immutable, or a value cannot be
   verified, do not run a repository script. Report the values you could verify in a table
   and stop.

STEP 3: PREFLIGHT
Only after every source check passes, run this inside the new clone:
  KOEDEX_LANG=en bash scripts/preflight.sh
Review the complete output for macOS, Swift, Command Line Tools, Codex CLI, OpenSSL 3,
Keychain, free disk space, and working location. Report every PASS/WARN/FAIL in one batch. A
signing certificate should already exist from the original install. Only if none is found,
explain before running bash scripts/make_signing_cert.sh that it creates a self-signed
code-signing certificate, imports it into the login Keychain, and marks it Always Trust, and
wait for my approval.

Exactly one WARN about the existing app is expected. A WARN that OpenSSL 3 was not found but the
certificate already exists is also harmless for updates. If the SwiftUI component check FAILs,
stop before building and follow its guidance. Only if Xcode is already installed, you may
retry just the failing build/check command with DEVELOPER_DIR=<existing /Applications/Xcode*.app>/Contents/Developer.
Do not change system settings or run xcode-select -s.

STEP 4: BUILD
1. Run: ./scripts/make_app.sh release --previous-app /Applications/Koedex.app
2. Verify exit status zero, dist/Koedex.app exists, bundle ID is com.koedex.app, and its
   deep strict signature is valid.
3. Verify the output includes a line reading (in Japanese)
   "更新互換性OK: bundle ID、Designated Requirement、署名者証明書は連続しています。" — this
   confirms signing continuity with the app still in /Applications. The ⚠️ line saying
   /Applications/Koedex.app already exists is expected here. If the OK line is missing, the
   output says the app cannot be verified as a stable signature (安定署名として検証できません),
   or any error:, non-zero exit code, signing failure, or other script-printed ⚠️ line
   appears, do not proceed to install; report the output as-is and stop.
4. Then run: bash scripts/verify_app_identity.sh /Applications/Koedex.app dist/Koedex.app
   Require exit status zero and the same 更新互換性OK line. Only this direct comparison with
   the installed app counts as proof of continuity.

STEP 5: SWITCH OVER (ONE APPROVAL)
1. After the build succeeds, explain all warnings and the following actions together; ask
   once for approval: quit Koedex, move the old app to ~/Developer/Koedex-backups/Koedex-<old version>.app
   (automatically add -2, -3 before .app if occupied), install, and verify. Never use Desktop.
2. After approval, perform those actions, running bash scripts/install_app.sh with no arguments.
   Never overwrite a backup or switch to a manual copy or alternate install destination.
   If install_app.sh exits non-zero, confirm /Applications/Koedex.app does not exist, move
   the set-aside app back to /Applications/Koedex.app (covered by this same approval),
   confirm it opens, then stop and report.
3. Run bash scripts/verify_app_identity.sh <set-aside app path> /Applications/Koedex.app and
   require exit status zero and the 更新互換性OK line, then report the results.

STEP 6: CHECK PERMISSIONS
1. Launch Koedex with open /Applications/Koedex.app (explicit path; never open -a or -b) and confirm マイク / Microphone, 音声認識 / Speech Recognition, and アクセシビリティ / Accessibility are still
   granted, either in the setup screen or in System Settings. **Normally this carries over
   with no action needed.**
2. If any permission shows as already granted on screen yet recording or pasting still does
   not work, and Koedex does not appear at all in System Settings → Privacy & Security →
   マイク / Microphone・音声認識 / Speech Recognition・アクセシビリティ / Accessibility, this may be a leftover macOS permission
   (TCC) record from the earlier install. Only if you actually observe this symptom, explain
   that you will run these three commands, and wait for my approval:
   - tccutil reset Microphone com.koedex.app
   - tccutil reset SpeechRecognition com.koedex.app
   - tccutil reset Accessibility com.koedex.app
3. After approval, quit Koedex, run the three commands above without sudo, then reopen
   Koedex and walk me through granting the three permissions normally. If you do not observe
   this symptom, do not run tccutil reset.

DO NOT CHANGE
- Do not hand-edit Codex settings or credentials under ~/.codex/. Codex CLI saving its own
  state during normal operation is fine.
- Do not reset TCC permissions unless you actually observed the symptom above, and even then
  only for Koedex's own three permissions (Microphone / SpeechRecognition / Accessibility,
  com.koedex.app) — never for any other app or permission.
- Do not automatically delete an existing app, old certificate, Keychain
  item, Koedex settings, or history.
- Do not delete or overwrite the clone folder from the original install.
- Do not fetch or run scripts from outside the repository or install new software on your
  own.
- Do not independently use sudo, delete or overwrite files, disable Gatekeeper, or broadly
  remove quarantine attributes.

MANUAL FINAL CHECK
Ask me to open TextEdit, press fn, say a short sentence, press fn again, and check that
text appears. This check is manual only. If any other UI automation takes more than
1–2 minutes, switch to manual instructions. Permission names are マイク / Microphone,
音声認識 / Speech Recognition, and アクセシビリティ / Accessibility; names may vary slightly
by macOS version.

Restore: before switch-over the old app is still in /Applications. After switch-over, quit
Koedex and, with approval, move the new app to a fresh folder without overwriting anything,
then return the backup to /Applications/Koedex.app. Never delete either app automatically.

FINAL REPORT
1. Working location and the verified origin, tag, and HEAD
2. Every preflight, build (including the --previous-app continuity result), install, and
   signature PASS/WARN/FAIL
3. Where the set-aside old app is (~/Developer/Koedex-backups/Koedex-<old version>.app), that it's safe to delete once
   I'm satisfied, and that deleting it is my decision, not yours
4. Whether permissions carried over automatically, or whether an old TCC record was found
   and reset
5. How to verify the Codex CLI connection and what to do if it is unavailable
```
<!-- END KOEDEX_AGENT_UPDATE_PROMPT_EN -->

# Koedexの更新をAIエージェントに任せる

この文書は、すでに Koedex を導入していて、新しいリリースへ更新したい方が、CodexまたはClaude
Codeへ更新作業をまとめて依頼するためのものです。下のプロンプトをそのまま貼り付けてください。

初めて Koedex を導入する場合は、この文書ではなく
[docs/agent-install-prompt.md](agent-install-prompt.md)を使ってください。

## 始める前に

エージェントは、計画モードや読み取り専用モードではなく、コマンド実行とファイル変更ができるモードで
始めてください。それらのモードで始めた場合は、そのことと切替方法をエージェントが伝えます。
コマンド実行前に確認が出る通常モードで十分です。全権限モードや確認を省略するモードは不要です。

- **前提**：`/Applications/Koedex.app` に、現在動いている Koedex が既に入っていること。
  入っていない場合は、この文書ではなく
  [docs/agent-install-prompt.md](agent-install-prompt.md)を使ってください。
- 新しいバージョンのclone先は、既定で `~/Developer/Koedex-v0.2.1` です。
  `~/Developer/Koedex-v0.2.1`を作れない場合だけ、`~/Downloads/Koedex-v0.2.1`を使います。
- **以前に導入したときのcloneフォルダ（例：`~/Developer/Koedex`）は、削除も上書きも再利用も
  しません。** 新しいclone先は、それとは別の名前の新規フォルダにしてください。
- フォルダが存在したら自動で-2、-3と付け、削除・再利用しません。
- Desktop、Documents、iCloud Drive、その他のFile Provider配下は避けます。
- デスクトップ版のAIエージェントでは、まず `~/Developer` を作業フォルダとして選びます。
  ターミナル版では、どのフォルダから起動しても、プロンプトが適切な場所を選びます。

公開リポジトリは同名の偽物を作れるため、URLだけでは十分ではありません。この手順では、
公式HTTPS URL、リリースタグ、remote、ローカルHEAD、GitHub上のtag、変更不能なreleaseを
すべて照合し、一致するまでリポジトリ内のスクリプトを実行しません。これは新規導入と
同じ検証です。

この版で固定している取得元は次のとおりです。

| 項目 | 固定値 |
| --- | --- |
| 公式URL | `https://github.com/GrShin5/Koedex.git` |
| リリースタグ | `v0.2.1` |
| 検証方式 | `GitHub immutable release` |

## 推奨モデル（2026-11-17時点）

| エージェント | 推奨 |
| --- | --- |
| Codex | `GPT-6.1-Sol` / `medium` |
| Claude Code | 利用できる場合は `Sonnet 5.5` / `medium`。なければ `default` / `medium` |

選択肢にないモデルやeffortを無理に指定する必要はありません。ここで選ぶモデルは
**更新作業を担当するAIエージェントのモデル**であり、Koedexアプリ内のAIモデル設定とは
別です。

## 途中で確認が必要になる理由

エージェントは事前チェックの結果を一括で説明します。ただし、次の操作は安全上、
実行直前に説明して承認を求めます。

- 証明書の作成が必要になった場合の、ログインキーチェーンへのimportと「常に信頼」の設定
  （通常は、以前の導入で作成済みのため不要です）
- ビルド成功後の切り替え：Koedexの終了、旧アプリの `~/Developer/Koedex-backups/` への移動
  （削除ではありません）、新しいアプリの `/Applications` への導入。これは**1回の承認**にまとめ、
  ビルド時の警告もこのときに一緒に説明します
- **`tccutil reset` の実行**（後述の「壊れた権限の直し方」に該当する症状が実際に
  見られた場合だけ、対象の3コマンドに限定して実行します）

同じ操作について、エージェントのアプリ自身が「このコマンドを許可しますか」という確認を出すことも
あります。エージェントが直前に説明した内容と同じコマンドなら許可してください。確認に失敗した
場合や、あなたの操作が必要な場合もエージェントは止まります。止まるときは、そのまま送れる返信例を
必ず示します。

確認回数を固定して約束することはできません。ネットワークやエージェントアプリの実行制限で
止まった場合、承認後に**同じURL・同じバージョン指定・同じコマンド**を再実行することは
許可していますが、別の取得元や別方式へ独断で切り替えることは禁止しています。

## 日本語のコピペ用プロンプト

<!-- BEGIN KOEDEX_AGENT_UPDATE_PROMPT_JA -->
```text
KoedexというmacOSアプリを、公式GitHubリポジトリの新しいリリースへ更新してください。
私はターミナル操作に不慣れです。技術用語だけで質問せず、私が画面上で何を確認・操作すれば
よいかを平易な日本語で説明してください。

【前提】
このMacの /Applications/Koedex.app に、現在動いている Koedex が既に入っています。まだ
入っていない場合は、この手順ではなく docs/agent-install-prompt.md の手順を使ってください。

【固定する取得元】
- 公式URL: https://github.com/GrShin5/Koedex.git
- リリースタグ: v0.2.1
- 検証方式: GitHub immutable release

【作業場所】
1. 新しいclone先は ~/Developer/Koedex-v0.2.1 としてください。
2. ~/Developerを作成・使用できない場合だけ、~/Downloads/Koedex-v0.2.1を候補にしてください。
3. 以前の導入で使ったcloneフォルダ（例：~/Developer/Koedex）は、削除・上書き・再利用せず、
   そのまま残してください。新しいcloneは必ず別名の新規フォルダに作ってください。
4. Desktop、Documents、iCloud Drive、File Provider配下、symlink先では作業しないでください。
5. clone先が存在する場合（symlinkも含む）は、自動で末尾に-2、-3と付けて空いている名前を
   選んでください。既存フォルダは削除・上書き・再利用しないでください。

【進め方】
- 計画モードまたは読み取り専用モードなら、1文でその状態を伝え、コマンド実行とファイル変更ができるモードへの切替方法を示してください。コマンド実行前に確認が出る通常モードで十分で、全権限モードや確認省略モードを求めないでください。計画だけを黙って返さないでください。
- 小さな確認を1件ずつ出さず、最初に読み取り専用の事前チェックを最後まで行い、結果と私に
  必要な作業を一括で報告してください。
- 報告だけを理由に待たないでください。止まるのは、下の承認、必須チェックの失敗、私にしか
  できない操作のときだけです。それ以外は次の手順へ進んでください。
- ただし、Keychainの変更、手順5の切り替え（Koedexの終了・旧アプリの退避・新しいアプリの導入を
  まとめた1回の承認）、tccutil resetの実行の前には、何が変わるかを説明して私の承認を
  待ってください。確認回数を固定しないでください。
- sandboxまたはnetworkの承認が原因で失敗した場合、承認後に同じURL・同じref・同じコマンドを
  1回再実行して構いません。別URL、別ref、ミラー、ダウンロードZIP、別のインストール方式へ
  独断で切り替えないでください。

- sandboxや制限された環境での失敗は「なし」ではなく「未確認」です。たとえば
  "cannot reach GitHub"や"0 certificates found"だけでは不在と判断できません。
  結論を出す前に、必要なアクセスの承認を求め、同じ読み取り専用コマンドを再実行してください。
- コンパイラ警告は報告しますが、それだけで止めないでください。ビルドでは、終了コードが0以外、
  error:、署名失敗、スクリプト自身が出す⚠️行で停止してください。ただし、/Applications/Koedex.app
  が既に存在するという想定どおりの⚠️行（事前チェックが出し、ビルドでも再表示されます）は
  除きます。互換性OK行がない場合も停止してください。他の安全確認も維持してください。

【停止するたびに示すこと】
必ず6項目を示してください。①完了したこと ②停止理由 ③現在のアプリが動くか（未確認なら明記）
④推奨する選択と、そのまま送れる返信例「この内容で進めて」など ⑤承認後に自動で進む作業
⑥元に戻す方法。必須チェックに失敗した場合は、その修正と再確認を推奨し、省略を勧めないでください。
「指示待ち」だけで返信を終えないでください。

【手順1：現在のアプリを確認する】
読み取り専用で /Applications/Koedex.app の存在とバージョンを確認してください。存在しなければ
停止し、docs/agent-install-prompt.mdを案内してください。ビルド成功まで旧アプリは /Applications に置いたままにし、移動も終了もしないでください。

【手順2：新しいバージョンの取得と照合】
1. 選んだ新規clone先へ、次の内容と等価な方法でv0.2.1をcloneしてください。
   git clone --branch v0.2.1 --single-branch https://github.com/GrShin5/Koedex.git <新規clone先>
2. clone直後、スクリプトを1つも実行する前に、次をすべて確認してください。
   - originのfetch URLが https://github.com/GrShin5/Koedex.git と一致する
     （比較時だけ末尾の.gitの有無を同一視して構いません）
   - ローカルのv0.2.1 tagが指すcommitとHEADが完全一致する
   - 公式URLへのgit ls-remoteで得たrefs/tags/v0.2.1もHEADと完全一致する
   - GitHub公式APIのreleases/tags/v0.2.1が、tag_name=v0.2.1かつimmutable=trueを返す
   - GitHub CLIをすでに利用できる場合は、gh release verify v0.2.1 --repo GrShin5/Koedexも成功する
   - checkoutがcleanで、未追跡ファイルもない
3. 1つでも一致しない、releaseが存在しない・immutableでない、取得結果を確認できない、
   別refへ誘導された場合は、リポジトリ内のスクリプトを実行せず、確認できた値を表で
   報告して止まってください。

【手順3：事前チェック】
取得元の照合がすべて通った後だけ、新しいclone内で次を実行してください。
  bash scripts/preflight.sh
macOS、Swift、Command Line Tools、Codex CLI、OpenSSL 3、Keychain、空き容量、作業場所を
含む全結果を確認し、PASS/WARN/FAILを省略せず一括報告してください。署名用の証明書は
以前の導入で作成済みのはずです。証明書が見つからない場合だけ、
bash scripts/make_signing_cert.sh の実行前にその内容（自己署名証明書の作成、ログイン
キーチェーンへのimport、「常に信頼」の設定）を説明し、承認を待ってください。

既存アプリについてのWARNがちょうど1件出るのは想定どおりです。「OpenSSL 3は見つかりませんが、
証明書は作成済みです」というWARNも、更新では問題ありません。SwiftUIコンポーネントの確認が
FAILならビルド前に止め、その案内に従ってください。Xcodeが既にある場合だけ、失敗したビルド・確認
コマンドだけにDEVELOPER_DIR=<既存の /Applications/Xcode*.app>/Contents/Developerを指定して
再実行できます。システム設定の変更やxcode-select -sは行わないでください。

【手順4：ビルド】
1. 次を実行してください。
   ./scripts/make_app.sh release --previous-app /Applications/Koedex.app
2. 終了コードが0、dist/Koedex.appが存在、bundle IDがcom.koedex.app、deep strict署名が
   有効であることを確認してください。
3. 出力に「更新互換性OK: bundle ID、Designated Requirement、署名者証明書は連続しています。」
   という行が含まれることを確認してください。/Applications/Koedex.appが既に存在するという⚠️行は
   ここでは想定どおりです。OK行がない、「安定署名として検証できません」と表示された、または
   終了コードが0以外、error:、署名失敗、それ以外のスクリプト自身の⚠️行が出た場合は、
   インストールに進まず、出力をそのまま報告して止まってください。
4. 続けて bash scripts/verify_app_identity.sh /Applications/Koedex.app dist/Koedex.app を実行し、
   終了コード0と同じ更新互換性OK行を確認してください。導入済みアプリとのこの直接比較だけを、
   連続性の根拠にします。

【手順5：切替（承認は1回）】
1. ビルド成功後、警告と次の操作をまとめて説明し、一度だけ承認を求めてください。Koedexを終了し、
   旧appを ~/Developer/Koedex-backups/Koedex-<旧バージョン>.app へ移動します。名前が存在する
   場合は.appの前に自動で-2、-3を付けます。続いてインストールと検証を行います。Desktopへは移動しません。
2. 承認後、この一連の操作を行い、bash scripts/install_app.shを引数なしで実行してください。
   バックアップの上書き、手作業のcopyや別のインストール先への切替は禁止です。
   install_app.shが0以外で終了したら、/Applications/Koedex.appが存在しないことを確認して
   退避した旧appを/Applications/Koedex.appへ戻し（この承認に含みます）、起動を確認してから
   停止・報告してください。
3. bash scripts/verify_app_identity.sh <退避した旧appのパス> /Applications/Koedex.app を実行し、
   終了コード0と更新互換性OK行を確認して、結果を報告してください。

【手順6：権限の確認】
1. open /Applications/Koedex.app でKoedexを起動し（パスを明示し、open -aや-bは使いません）、マイク / Microphone・音声認識 / Speech Recognition・アクセシビリティ / Accessibilityが引き続き有効になっているか、
   セットアップ画面またはシステム設定で確認してください。**通常は何もしなくても
   引き継がれます。**
2. もし、いずれかの権限が画面で「許可済み」と表示されているのに実際には録音や貼り付けが
   動かず、かつシステム設定 →「プライバシーとセキュリティ」→ マイク / Microphone・音声認識 / Speech Recognition・
   アクセシビリティ / Accessibilityのいずれの一覧にもKoedexが表示されない場合は、以前の導入が残した
   古いmacOS権限（TCC）の記録が原因の可能性があります。この症状を実際に確認できた
   場合だけ、次の3コマンドを実行することを説明し、承認を待ってください。
   - tccutil reset Microphone com.koedex.app
   - tccutil reset SpeechRecognition com.koedex.app
   - tccutil reset Accessibility com.koedex.app
3. 承認後、Koedexを終了してから上記3コマンドをsudoを付けずに実行し、Koedexを開き直して
   3つの権限を通常どおり許可し直すよう案内してください。この症状が見られない場合は、
   tccutil resetを実行しないでください。

【変更してはいけないもの】
- ~/.codex/内のCodex設定や認証情報を手で編集しないでください。Codex CLIが通常動作で
  自身の状態を保存することは構いません。
- 上記の症状が実際に確認できた場合を除き、TCC権限をresetしないでください。resetする
  場合も、Koedexの3権限（Microphone / SpeechRecognition / Accessibility、
  com.koedex.app）以外には絶対に使わないでください。
- 既存app、古い証明書、Keychain項目、Koedexの設定や履歴を自動削除しないで
  ください。
- 以前の導入で使ったcloneフォルダを削除・上書きしないでください。
- リポジトリ外のスクリプトを取得・実行せず、新しいソフトウェアを勝手にインストールしないで
  ください。
- sudo、削除、上書き、Gatekeeper無効化、quarantine属性の一括削除を独断で行わないでください。

【最後の手動確認】
私にテキストエディットを開き、fnを押し、短い文を話し、もう一度fnを押して、文字が入るか
確認するよう案内してください。この確認は手動だけで行います。それ以外のUI自動操作が
1〜2分で終わらない場合も手動の案内に切り替えてください。権限名は、マイク / Microphone、
音声認識 / Speech Recognition、アクセシビリティ / Accessibilityです。macOSの版によって
表示名が少し異なる場合があります。

戻し方：切替前は旧appが/Applicationsにあります。切替後はKoedexを終了し、承認を得て新appを
上書きのない新規フォルダへ移し、バックアップを/Applications/Koedex.appへ戻します。
どちらのappも自動削除しないでください。

【完了報告】
1. 実際に使った作業場所、origin、tag、HEADの照合結果
2. preflight、build（--previous-appの検証結果を含む）、install、署名検証のPASS/WARN/FAIL
3. 退避した旧アプリ（~/Developer/Koedex-backups/Koedex-<旧バージョン>.app）の場所。満足したら削除してよいことと、
   削除は私自身が判断して行うこと
4. 権限が引き継がれたか、または古いTCC記録が見つかりtccutil resetを行ったかどうか
5. Codex CLI接続確認と、接続できない場合の対処
```
<!-- END KOEDEX_AGENT_UPDATE_PROMPT_JA -->
