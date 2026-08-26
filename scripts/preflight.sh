#!/bin/bash
# Koedexのビルド前提条件を読み取り専用で一括検査する。
set -euo pipefail
QUIET=0 INSTALL=0
for arg in "$@"; do case "$arg" in --quiet) QUIET=1;; --install) INSTALL=1;; *) echo "Usage: $0 [--quiet] [--install]" >&2; exit 2;; esac; done
UI_LANG="ja"
request="$(printf '%s' "${KOEDEX_LANG:-}" | tr '[:upper:]' '[:lower:]')"
case "$request" in
  en|en[-_.]*) UI_LANG="en" ;;
  ja|ja[-_.]*) UI_LANG="ja" ;;
  "")
    locale_request="$(printf '%s' "${LC_ALL:-${LC_MESSAGES:-${LANG:-}}}" | tr '[:upper:]' '[:lower:]')"
    case "$locale_request" in ""|ja*|c|c.*|posix) UI_LANG="ja" ;; *) UI_LANG="en" ;; esac ;;
esac
t() { [[ "$UI_LANG" == en ]] && printf '%s' "$2" || printf '%s' "$1"; }
cd "$(dirname "$0")/.."; ROOT_DIR="$(pwd)"; source "$ROOT_DIR/scripts/lib/install_checks.sh"
RESULT_LINES=(); ACTION_ITEMS=(); OVERALL_STATUS=0; WARN_COUNT=0
record() { case "$1" in ok) RESULT_LINES+=("✅ $2");; warn) RESULT_LINES+=("⚠️ $2"); WARN_COUNT=$((WARN_COUNT + 1));; fail) RESULT_LINES+=("❌ $2"); OVERALL_STATUS=2;; esac; }

# macOS / CLT / Swift / Codex CLI
macos_version="$(sw_vers -productVersion 2>/dev/null || true)"
macos_major="${macos_version%%.*}"
if [[ "$(uname -s 2>/dev/null || true)" == Darwin && "$macos_major" =~ ^[0-9]+$ && "$macos_major" -ge 26 ]]; then
  record ok "$(t "macOS ${macos_version}です（26以降）" "macOS ${macos_version} (26 or later) was detected")"
else
  record fail "$(t "macOS 26以降が必要です（検出値: ${macos_version:-不明}）" "macOS 26 or later is required (detected: ${macos_version:-unknown})")"
  ACTION_ITEMS+=("$(t "システム設定の「一般」→「ソフトウェアアップデート」でmacOSを更新してください。" "Update macOS in System Settings → General → Software Update.")")
fi
if xcode-select -p >/dev/null 2>&1; then record ok "$(t "Xcode Command Line Toolsが導入されています" "Xcode Command Line Tools are installed")"; else record fail "$(t "Xcode Command Line Toolsが見つかりません" "Xcode Command Line Tools were not found")"; ACTION_ITEMS+=("$(t "ターミナルで \`xcode-select --install\` を実行してください。" "Run \`xcode-select --install\` in Terminal.")"); fi
swift_version="$(swift --version 2>/dev/null | sed -n 's/.*Apple Swift version \([0-9][0-9]*\.[0-9][0-9]*\).*/\1/p' | head -1 || true)"; swift_ok=0
if [[ "$swift_version" =~ ^([0-9]+)\.([0-9]+)$ ]] && { [[ ${BASH_REMATCH[1]} -gt 6 ]] || { [[ ${BASH_REMATCH[1]} -eq 6 && ${BASH_REMATCH[2]} -ge 2 ]]; }; }; then swift_ok=1; fi
if [[ $swift_ok -eq 1 ]]; then record ok "$(t "Swiftのバージョンは${swift_version}です（6.2以上）" "Swift version is ${swift_version} (6.2 or later)")"; else record fail "$(t "Swift 6.2以上が必要です（検出値: ${swift_version:-不明}）" "Swift 6.2 or later is required (detected: ${swift_version:-unknown})")"; ACTION_ITEMS+=("$(t "\`softwareupdate --list\` を確認し、Swift 6.2以降を含む更新を導入してください。" "Check \`softwareupdate --list\` and install an update that includes Swift 6.2 or later.")"); fi
if command -v codex >/dev/null 2>&1; then
  codex_version_output="$(codex --version 2>&1 || true)"
  codex_version="$(printf '%s\n' "$codex_version_output" | sed -n '/^codex-cli /{p;q;}' || true)"
  [[ -n "$codex_version" ]] || codex_version="$(printf '%s\n' "$codex_version_output" | head -n 1)"
  codex_detail_ja=""; codex_detail_en=""
  if [[ -n "$codex_version" ]]; then
    codex_detail_ja="（${codex_version}）"
    codex_detail_en=" (${codex_version})"
  fi
  record ok "$(t "Codex CLIが見つかりました${codex_detail_ja}" "Codex CLI was found${codex_detail_en}")"
else
  record fail "$(t "Codex CLIが見つかりません" "Codex CLI was not found")"
  ACTION_ITEMS+=("$(t "取扱説明書のCodex CLI導入手順を完了し、ChatGPTへログインしてください。" "Complete the manual's Codex CLI setup and sign in with ChatGPT.")")
fi

# Keychain is three-valued; inaccessible is never treated as absent.
keychain_state="$(koedex_keychain_state)"; signing_exists=0
case "$keychain_state" in found) signing_exists=1; record ok "$(t "コード署名用証明書 \"Koedex Dev\" が見つかりました" "The code-signing certificate \"Koedex Dev\" was found")";; absent) record warn "$(t "コード署名用証明書 \"Koedex Dev\" はまだ作成されていません" "The code-signing certificate \"Koedex Dev\" has not been created yet")"; ACTION_ITEMS+=("$(t "\`bash scripts/make_signing_cert.sh\` を実行して証明書を作成してください。" "Run \`bash scripts/make_signing_cert.sh\` to create the certificate.")");; inaccessible) record fail "$(t "Keychainにアクセスできません（証明書なしとは判定しません）" "The Keychain is inaccessible (not treated as a missing certificate)")"; ACTION_ITEMS+=("$(t "ログインキーチェーンを解除して再実行してください。証明書の削除や作り直しは不要です。" "Unlock the login Keychain and retry. Do not delete or recreate the certificate.")");; esac
openssl3="$(koedex_find_openssl3 || true)"
if [[ -n "$openssl3" ]]; then record ok "$(t "OpenSSL 3を実体検証しました: $openssl3" "OpenSSL 3 was verified: $openssl3")"; elif [[ $signing_exists -eq 1 ]]; then record warn "$(t "OpenSSL 3は見つかりませんが、証明書は作成済みです" "OpenSSL 3 was not found, but the certificate already exists")"; else record fail "$(t "OpenSSL 3が見つかりません（PATHと既知場所を検証しました）" "OpenSSL 3 was not found (PATH and known locations were checked)")"; ACTION_ITEMS+=("$(t "\`brew install openssl@3\` を実行してください。" "Run \`brew install openssl@3\`.")"); fi

# Work location: symlink, File Provider/iCloud, and dirty clone.
if [[ -L "$ROOT_DIR" || -L "$0" ]]; then
  record fail "$(t "シンボリックリンク経由の作業場所は使えません" "A symlinked work location cannot be used")"
  ACTION_ITEMS+=("$(t "~/Developer/Koedexへ新しくcloneし、symlinkを使わずに作業してください。" "Make a new clone at ~/Developer/Koedex and do not use a symlink.")")
else
  record ok "$(t "作業場所はシンボリックリンクではありません" "The work location is not a symlink")"
fi
if [[ -w "$ROOT_DIR" ]]; then
  record ok "$(t "作業場所へ書き込めます" "The working location is writable")"
else
  record fail "$(t "作業場所へ書き込めません" "The working location is not writable")"
  ACTION_ITEMS+=("$(t "書込み可能な~/Developerへ新しくcloneしてください。" "Make a new clone inside the writable ~/Developer folder.")")
fi
case "$ROOT_DIR/" in
  "$HOME/Desktop/"*|"$HOME/Documents/"*|"$HOME/Library/Mobile Documents/"*|*"/Library/CloudStorage/"*)
    record fail "$(t "Desktop/Documents/iCloud/File Provider配下では作業できません" "Do not work inside Desktop, Documents, iCloud, or File Provider storage")"
    ACTION_ITEMS+=("$(t "~/Developer/Koedexへ新しくcloneしてください。既存フォルダは移動・再利用しないでください。" "Make a new clone at ~/Developer/Koedex. Do not move or reuse the existing folder.")")
    ;;
esac
provider=0; check="$ROOT_DIR"; while [[ "$check" != / ]]; do attrs="$(xattr "$check" 2>/dev/null || true)"; [[ "$attrs" == *com.apple.file-provider-domain-id* || "$attrs" == *com.apple.fileprovider* ]] && { provider=1; break; }; check="$(dirname "$check")"; done
if [[ $provider -eq 0 ]]; then record ok "$(t "リポジトリのパスはiCloud/File Provider配下ではありません" "The repository is outside iCloud/File Provider storage")"; else record fail "$(t "リポジトリのパスがiCloud/File Provider配下です" "The repository is inside iCloud/File Provider storage")"; ACTION_ITEMS+=("$(t "~/Developer/Koedexへ新しくcloneしてください。既存フォルダは移動・再利用しないでください。" "Make a new clone at ~/Developer/Koedex. Do not move or reuse the existing folder.")"); fi
if git -C "$ROOT_DIR" rev-parse --is-inside-work-tree >/dev/null 2>&1; then [[ -z "$(git -C "$ROOT_DIR" status --porcelain 2>/dev/null)" ]] && record ok "$(t "Git cloneはcleanです" "The Git clone is clean")" || record warn "$(t "Git cloneに未コミット変更があります" "The Git clone has uncommitted changes")"; else record fail "$(t "Git cloneとして確認できません" "This location is not a Git clone")"; fi

# Existing install is non-destructive normally and a hard failure for --install.
if koedex_install_target_exists /Applications/Koedex.app; then if [[ $INSTALL -eq 1 ]]; then record fail "$(t "/Applications/Koedex.app が既に存在します（app・通常file・symlinkを上書きしません）" "/Applications/Koedex.app already exists (app, regular file, and symlink are never overwritten)")"; ACTION_ITEMS+=("$(t "既存のKoedex.appを残すか手動で削除するかを判断してください。このスクリプトは変更しません。" "Decide whether to keep or manually remove the existing Koedex.app. This script will not change it.")"); else record warn "$(t "/Applications/Koedex.app が既に存在します。上書きする前に内容を確認してください" "/Applications/Koedex.app already exists. Check it before overwriting.")"; fi; else record ok "$(t "/Applications/Koedex.app はまだ存在しません" "/Applications/Koedex.app does not exist yet")"; fi
available_kb="$(df -k "$ROOT_DIR" 2>/dev/null | awk 'NR==2 {print $4}' || true)"; [[ "$available_kb" =~ ^[0-9]+$ && "$available_kb" -ge 2097152 ]] && record ok "$(t "空きディスク容量は2GB以上あります" "At least 2GB of disk space is available")" || { record fail "$(t "空きディスク容量が不足しています（必要2GB以上）" "Not enough free disk space (2GB or more is required)")"; ACTION_ITEMS+=("$(t "空き容量を2GB以上確保してください。" "Free up at least 2GB of disk space.")"); }

print_report() { echo "$(t "=== Koedexビルド前提条件チェック ===" "=== Koedex build prerequisite check ===")"; printf '%s\n' "${RESULT_LINES[@]}"; if [[ ${#ACTION_ITEMS[@]} -gt 0 ]]; then echo ""; echo "$(t "=== あなたがやること ===" "=== What you need to do ===")"; local i=1; for action in "${ACTION_ITEMS[@]}"; do echo "$i. $action"; i=$((i + 1)); done; fi; }
if [[ $QUIET -eq 0 || $OVERALL_STATUS -ne 0 || ${#ACTION_ITEMS[@]} -gt 0 || $WARN_COUNT -gt 0 ]]; then print_report; fi
exit "$OVERALL_STATUS"
