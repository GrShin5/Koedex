# Koedexの更新をAIエージェントに任せる

この文書は、すでに Koedex を導入していて、新しいリリースへ更新したい方が、CodexまたはClaude
Codeへ更新作業をまとめて依頼するためのものです。下のプロンプトをそのまま貼り付けてください。

初めて Koedex を導入する場合は、この文書ではなく
[docs/agent-install-prompt.md](agent-install-prompt.md)を使ってください。

## 始める前に

- **前提**：`/Applications/Koedex.app` に、現在動いている Koedex が既に入っていること。
  入っていない場合は、この文書ではなく
  [docs/agent-install-prompt.md](agent-install-prompt.md)を使ってください。
- 新しいバージョンのclone先は、既定で `~/Developer/Koedex-update` です。
  `~/Developer/Koedex-update`を作れない場合だけ、`~/Downloads/Koedex-update`を使います。
- **以前に導入したときのcloneフォルダ（例：`~/Developer/Koedex`）は、削除も上書きも再利用も
  しません。** 新しいclone先は、それとは別の名前の新規フォルダにしてください。
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
| リリースタグ | `v0.1.7` |
| 検証方式 | `GitHub immutable release` |

## 推奨モデル（2026-08-24時点）

| エージェント | 推奨 |
| --- | --- |
| Codex | `GPT-5.6-Terra` / `medium` |
| Claude Code | 利用できる場合は `Sonnet 5` / `medium`。なければ `default` / `medium` |

選択肢にないモデルやeffortを無理に指定する必要はありません。ここで選ぶモデルは
**更新作業を担当するAIエージェントのモデル**であり、Koedexアプリ内のAIモデル設定とは
別です。

## 途中で確認が必要になる理由

エージェントは事前チェックの結果を一括で説明します。ただし、次の操作は安全上、
実行直前に説明して承認を求めます。

- `/Applications/Koedex.app` を移動すること（削除ではありません）
- 証明書の作成が必要になった場合の、ログインキーチェーンへのimportと「常に信頼」の設定
  （通常は、以前の導入で作成済みのため不要です）
- `/Applications`への新しいアプリの書込み
- **`tccutil reset` の実行**（後述の「壊れた権限の直し方」に該当する症状が実際に
  見られた場合だけ、対象の3コマンドに限定して実行します）

確認回数を固定して約束することはできません。ネットワークやsandboxの承認で止まった場合、
承認後に**同じURL・同じref・同じコマンド**を再実行することは許可していますが、別の取得元や
別方式へ独断で切り替えることは禁止しています。

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
- リリースタグ: v0.1.7
- 検証方式: GitHub immutable release

【作業場所】
1. 新しいclone先は ~/Developer/Koedex-update としてください。
2. ~/Developerを作成・使用できない場合だけ、~/Downloads/Koedex-updateを候補にしてください。
3. 以前の導入で使ったcloneフォルダ（例：~/Developer/Koedex）は、削除・上書き・再利用せず、
   そのまま残してください。新しいcloneは必ず別名の新規フォルダに作ってください。
4. Desktop、Documents、iCloud Drive、File Provider配下、symlink先では作業しないでください。
5. 新しいclone先がすでに存在する場合は、削除・上書き・再利用せず、状態を平易に報告して
   止まってください。

【進め方】
- 小さな確認を1件ずつ出さず、最初に読み取り専用の事前チェックを最後まで行い、結果と私に
  必要な作業を一括で報告してください。
- ただし、/Applicationsにあるアプリの移動、Keychainの変更、/Applicationsへの新規書込み、
  tccutil resetの実行など、安全上必要な承認は実行直前に、何が変わるかを説明して私の承認を
  待ってください。確認回数を固定しないでください。
- sandboxまたはnetworkの承認が原因で失敗した場合、承認後に同じURL・同じref・同じコマンドを
  1回再実行して構いません。別URL、別ref、ミラー、ダウンロードZIP、別のインストール方式へ
  独断で切り替えないでください。

【手順1：現在のインストールを退避する】
1. /Applications/Koedex.app が実際に存在することを確認してください。存在しない場合は
   ここで止まり、docs/agent-install-prompt.md を使うよう案内してください。
2. 実行前に、/Applications/Koedex.app を ~/Desktop/Koedex-old.app へ移動する（削除では
   ありません）ことを説明し、承認を待ってください。
3. 承認後、mv /Applications/Koedex.app ~/Desktop/Koedex-old.app を実行してください。
   手作業のGUI操作で同じ結果になる場合はそれでも構いませんが、削除・ゴミ箱送りは
   しないでください。

【手順2：新しいバージョンの取得と照合】
1. 選んだ新規clone先へ、次の内容と等価な方法でv0.1.7をcloneしてください。
   git clone --branch v0.1.7 --single-branch https://github.com/GrShin5/Koedex.git <新規clone先>
2. clone直後、スクリプトを1つも実行する前に、次をすべて確認してください。
   - originのfetch URLが https://github.com/GrShin5/Koedex.git と一致する
     （比較時だけ末尾の.gitの有無を同一視して構いません）
   - ローカルのv0.1.7 tagが指すcommitとHEADが完全一致する
   - 公式URLへのgit ls-remoteで得たrefs/tags/v0.1.7もHEADと完全一致する
   - GitHub公式APIのreleases/tags/v0.1.7が、tag_name=v0.1.7かつimmutable=trueを返す
   - GitHub CLIをすでに利用できる場合は、gh release verify v0.1.7 --repo GrShin5/Koedexも成功する
   - checkoutがcleanで、未追跡ファイルもない
3. 1つでも一致しない、releaseが存在しない・immutableでない、取得結果を確認できない、
   別refへ誘導された場合は、リポジトリ内のスクリプトを実行せず、確認できた値を表で
   報告して止まってください。

【手順3：事前チェック】
取得元の照合がすべて通った後だけ、新しいclone内で次を実行してください。
  bash scripts/preflight.sh --install
macOS、Swift、Command Line Tools、Codex CLI、OpenSSL 3、Keychain、空き容量、作業場所を
含む全結果を確認し、PASS/WARN/FAILを省略せず一括報告してください。署名用の証明書は
以前の導入で作成済みのはずです。証明書が見つからない場合だけ、
bash scripts/make_signing_cert.sh の実行前にその内容（自己署名証明書の作成、ログイン
キーチェーンへのimport、「常に信頼」の設定）を説明し、承認を待ってください。

【手順4：ビルド】
1. 次を実行してください。
   ./scripts/make_app.sh release --previous-app ~/Desktop/Koedex-old.app
2. 終了コードが0、dist/Koedex.appが存在、bundle IDがcom.koedex.app、deep strict署名が
   有効であることを確認してください。
3. 出力に「更新互換性OK: bundle ID、Designated Requirement、署名者証明書は連続しています。」
   という行が含まれることを確認してください。含まれない場合、または警告や失敗が出た場合は、
   インストールに進まず、出力をそのまま報告して止まってください。

【手順5：インストール】
1. bash scripts/install_app.sh の実行前に、dist/Koedex.appを/Applicationsへ新規配置する
   ことを説明して、承認を待ってください（手順1で/Applications/Koedex.appは空いています）。
2. 承認後に bash scripts/install_app.sh を引数なしで実行してください。手作業のcopyや
   別名配置へ切り替えないでください。
3. 配置後のbundle ID、deep strict署名、退避した旧appとのsigner fingerprintおよびidentity
   continuityを検証し、結果を報告してください。

【手順6：権限の確認】
1. Koedexを起動し、マイク・音声認識・アクセシビリティが引き続き有効になっているか、
   セットアップ画面またはシステム設定で確認してください。**通常は何もしなくても
   引き継がれます。**
2. もし、いずれかの権限が画面で「許可済み」と表示されているのに実際には録音や貼り付けが
   動かず、かつシステム設定 →「プライバシーとセキュリティ」→ マイク／音声認識／
   アクセシビリティのいずれの一覧にもKoedexが表示されない場合は、以前の導入が残した
   古いmacOS権限（TCC）の記録が原因の可能性があります。この症状を実際に確認できた
   場合だけ、次の3コマンドを実行することを説明し、承認を待ってください。
   - tccutil reset Microphone com.koedex.app
   - tccutil reset SpeechRecognition com.koedex.app
   - tccutil reset Accessibility com.koedex.app
3. 承認後、Koedexを終了してから上記3コマンドをsudoを付けずに実行し、Koedexを開き直して
   3つの権限を通常どおり許可し直すよう案内してください。この症状が見られない場合は、
   tccutil resetを実行しないでください。

【変更してはいけないもの】
- ~/.codex/配下を変更しないでください。
- 上記の症状が実際に確認できた場合を除き、TCC権限をresetしないでください。resetする
  場合も、Koedexの3権限（Microphone / SpeechRecognition / Accessibility、
  com.koedex.app）以外には絶対に使わないでください。
- 手順1以外で、既存app、古い証明書、Keychain項目、Koedexの設定や履歴を自動削除しないで
  ください。
- 以前の導入で使ったcloneフォルダを削除・上書きしないでください。
- リポジトリ外のスクリプトを取得・実行せず、新しいソフトウェアを勝手にインストールしないで
  ください。
- sudo、削除、上書き、Gatekeeper無効化、quarantine属性の一括削除を独断で行わないでください。

【完了報告】
1. 実際に使った作業場所、origin、tag、HEADの照合結果
2. preflight、build（--previous-appの検証結果を含む）、install、署名検証のPASS/WARN/FAIL
3. 退避した旧アプリ（~/Desktop/Koedex-old.app）の場所。満足したら削除してよいことと、
   削除は私自身が判断して行うこと
4. 権限が引き継がれたか、または古いTCC記録が見つかりtccutil resetを行ったかどうか
5. Codex CLI接続確認と、接続できない場合の対処
```
<!-- END KOEDEX_AGENT_UPDATE_PROMPT_JA -->

## English versions (concise)

Use `~/Developer/Koedex-update` as the new clone destination (fall back to
`~/Downloads/Koedex-update` only if `~/Developer` cannot be used). Never reuse, overwrite, or
delete the folder from your original install. This flow assumes Koedex is already installed
at `/Applications/Koedex.app` — if it isn't, use
[docs/agent-install-prompt.md](agent-install-prompt.md) instead.

Recommended agent as of 2026-08-24: Codex `GPT-5.6-Terra` / `medium`; Claude Code
`Sonnet 5` / `medium` when available, otherwise `default` / `medium`. This is separate from
Koedex's in-app AI model.

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
- Release tag: v0.1.7
- Verification method: GitHub immutable release

WORKING LOCATION
1. Use ~/Developer/Koedex-update as the new clone destination.
2. Only if ~/Developer cannot be created or used, offer ~/Downloads/Koedex-update instead.
3. Do not delete, overwrite, or reuse the clone folder from the original install (for
   example ~/Developer/Koedex). The new clone must be a separate, new folder.
4. Do not work in Desktop, Documents, iCloud Drive, another File Provider location, or
   through a symlink.
5. If the new destination already exists, do not delete, overwrite, or reuse it. Report its
   location and state in plain language, then stop.

HOW TO PROCEED
- Complete all read-only preflight checks first, then report every finding and all action I
  need to take in one batch. Do not interrupt me once per finding.
- Still ask immediately before moving the app in /Applications, changing Keychain, writing a
  new app into /Applications, or running tccutil reset. Explain what will change and wait
  for my approval. Do not promise a fixed number of pauses.
- If sandbox or network approval caused a command to fail, after approval you may retry the
  same URL, ref, and command once. Do not independently switch to another URL, ref, mirror,
  ZIP download, or installation method.

STEP 1: SET ASIDE THE CURRENT INSTALL
1. Confirm /Applications/Koedex.app actually exists. If it does not, stop and direct me to
   docs/agent-install-prompt.md instead.
2. Before doing anything, explain that you will move (not delete)
   /Applications/Koedex.app to ~/Desktop/Koedex-old.app, and wait for my approval.
3. After approval, run: mv /Applications/Koedex.app ~/Desktop/Koedex-old.app
   An equivalent Finder drag is fine too, but never delete or trash it.

STEP 2: FETCH AND VERIFY THE NEW VERSION
1. Clone v0.1.7 into the new destination using a command equivalent to:
   git clone --branch v0.1.7 --single-branch https://github.com/GrShin5/Koedex.git <new-destination>
2. Before running any repository script, verify all of the following:
   - origin's fetch URL matches https://github.com/GrShin5/Koedex.git
     (you may treat only a trailing .git as equivalent during comparison)
   - the local v0.1.7 tag's commit exactly equals HEAD
   - refs/tags/v0.1.7 returned by git ls-remote against the official URL exactly equals HEAD
   - GitHub's official releases/tags/v0.1.7 API reports tag_name=v0.1.7 and immutable=true
   - if GitHub CLI is already available, gh release verify v0.1.7 --repo GrShin5/Koedex also succeeds
   - the checkout is clean and has no untracked files
3. If any value differs, the release is missing or not immutable, or a value cannot be
   verified, do not run a repository script. Report the values you could verify in a table
   and stop.

STEP 3: PREFLIGHT
Only after every source check passes, run this inside the new clone:
  KOEDEX_LANG=en bash scripts/preflight.sh --install
Review the complete output for macOS, Swift, Command Line Tools, Codex CLI, OpenSSL 3,
Keychain, free disk space, and working location. Report every PASS/WARN/FAIL in one batch. A
signing certificate should already exist from the original install. Only if none is found,
explain before running bash scripts/make_signing_cert.sh that it creates a self-signed
code-signing certificate, imports it into the login Keychain, and marks it Always Trust, and
wait for my approval.

STEP 4: BUILD
1. Run: ./scripts/make_app.sh release --previous-app ~/Desktop/Koedex-old.app
2. Verify exit status zero, dist/Koedex.app exists, bundle ID is com.koedex.app, and its
   deep strict signature is valid.
3. Verify the output includes a line reading (in Japanese)
   "更新互換性OK: bundle ID、Designated Requirement、署名者証明書は連続しています。" — this
   confirms signing continuity with the app you set aside. If that line is missing, or any
   warning or failure appears, do not proceed to install; report the output as-is and stop.

STEP 5: INSTALL
1. Before running bash scripts/install_app.sh, explain that it installs dist/Koedex.app to
   /Applications, which is now clear because of step 1. Wait for my approval.
2. After approval, run bash scripts/install_app.sh with no arguments. Do not switch to a
   manual copy or alternate destination.
3. Verify the installed bundle ID, deep strict signature, and identity continuity (signer
   fingerprint) against the app you set aside, then report the results.

STEP 6: CHECK PERMISSIONS
1. Launch Koedex and confirm Microphone, Speech Recognition, and Accessibility are still
   granted, either in the setup screen or in System Settings. **Normally this carries over
   with no action needed.**
2. If any permission shows as already granted on screen yet recording or pasting still does
   not work, and Koedex does not appear at all in System Settings → Privacy & Security →
   Microphone/Speech Recognition/Accessibility, this may be a leftover macOS permission
   (TCC) record from the earlier install. Only if you actually observe this symptom, explain
   that you will run these three commands, and wait for my approval:
   - tccutil reset Microphone com.koedex.app
   - tccutil reset SpeechRecognition com.koedex.app
   - tccutil reset Accessibility com.koedex.app
3. After approval, quit Koedex, run the three commands above without sudo, then reopen
   Koedex and walk me through granting the three permissions normally. If you do not observe
   this symptom, do not run tccutil reset.

DO NOT CHANGE
- Do not modify anything under ~/.codex/.
- Do not reset TCC permissions unless you actually observed the symptom above, and even then
  only for Koedex's own three permissions (Microphone / SpeechRecognition / Accessibility,
  com.koedex.app) — never for any other app or permission.
- Outside step 1, do not automatically delete an existing app, old certificate, Keychain
  item, Koedex settings, or history.
- Do not delete or overwrite the clone folder from the original install.
- Do not fetch or run scripts from outside the repository or install new software on your
  own.
- Do not independently use sudo, delete or overwrite files, disable Gatekeeper, or broadly
  remove quarantine attributes.

FINAL REPORT
1. Working location and the verified origin, tag, and HEAD
2. Every preflight, build (including the --previous-app continuity result), install, and
   signature PASS/WARN/FAIL
3. Where the set-aside old app is (~/Desktop/Koedex-old.app), that it's safe to delete once
   I'm satisfied, and that deleting it is my decision, not yours
4. Whether permissions carried over automatically, or whether an old TCC record was found
   and reset
5. How to verify the Codex CLI connection and what to do if it is unavailable
```
<!-- END KOEDEX_AGENT_UPDATE_PROMPT_EN -->
