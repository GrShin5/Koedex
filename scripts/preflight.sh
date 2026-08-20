#!/bin/bash
# Koedexのビルド前提条件を検査する読み取り専用スクリプト。
#
# 目的: make_app.sh やmake_signing_cert.shが根本原因の分からないまま途中で
# 止まることを防ぐ。1件見つけて即失敗させるのではなく、全項目を検査してから
# 不合格をまとめて報告する。
#
# 何も変更しない。sudoもbrew installも実行しない。
set -euo pipefail

QUIET=0
for arg in "$@"; do
  case "$arg" in
    --quiet) QUIET=1 ;;
    *) ;;
  esac
done

cd "$(dirname "$0")/.."
ROOT_DIR="$(pwd)"

RESULT_LINES=()
ACTION_ITEMS=()
OVERALL_STATUS=0
WARN_COUNT=0

record() {
  local status="$1" line="$2"
  case "$status" in
    ok)   RESULT_LINES+=("✅ $line") ;;
    warn) RESULT_LINES+=("⚠️ $line"); WARN_COUNT=$((WARN_COUNT + 1)) ;;
    fail) RESULT_LINES+=("❌ $line"); OVERALL_STATUS=2 ;;
  esac
}

# 1. Xcode Command Line Tools
if xcode-select -p >/dev/null 2>&1; then
  record ok "Xcode Command Line Toolsが導入されています"
else
  record fail "Xcode Command Line Toolsが見つかりません"
  ACTION_ITEMS+=("ターミナルで \`xcode-select --install\` を実行し、案内に沿ってインストールしてください。")
fi

# 2. Swiftのバージョンが6.2以上か
SWIFT_VERSION=""
if command -v swift >/dev/null 2>&1; then
  SWIFT_VERSION_OUTPUT="$(swift --version 2>/dev/null || true)"
  # "swift-driver version: 1.148.6 Apple Swift version 6.3.3" のように別の版番号が
  # 先に出ることがあるため、"Apple Swift version" の直後を優先して読む。
  SWIFT_VERSION="$(printf '%s' "$SWIFT_VERSION_OUTPUT" \
    | sed -n 's/.*Apple Swift version \([0-9][0-9]*\.[0-9][0-9]*\).*/\1/p' | head -1 || true)"
  if [[ -z "$SWIFT_VERSION" ]]; then
    SWIFT_VERSION="$(printf '%s' "$SWIFT_VERSION_OUTPUT" | head -1 \
      | grep -oE '[0-9]+\.[0-9]+' | head -1 || true)"
  fi
fi
SWIFT_OK=0
if [[ -n "$SWIFT_VERSION" ]]; then
  SWIFT_MAJOR="${SWIFT_VERSION%%.*}"
  SWIFT_MINOR="${SWIFT_VERSION#*.}"
  if [[ "$SWIFT_MAJOR" -gt 6 || ( "$SWIFT_MAJOR" -eq 6 && "$SWIFT_MINOR" -ge 2 ) ]]; then
    SWIFT_OK=1
  fi
fi
if [[ "$SWIFT_OK" -eq 1 ]]; then
  record ok "Swiftのバージョンは${SWIFT_VERSION}です（6.2以上）"
else
  record fail "Swiftのバージョンが6.2未満、または確認できません（検出値: ${SWIFT_VERSION:-不明}）"
  ACTION_ITEMS+=("\`softwareupdate --list\` の出力を確認し、Swift 6.2以降を含むmacOSアップデートのラベルを出力からコピーして \`sudo softwareupdate --install \"<ラベル>\"\` を実行してください（ラベルは版ごとに変わるため固定文字列ではなく必ず出力からコピーしてください）。約900MBのダウンロードで10〜30分かかり、管理者パスワードの入力が1回必要です。")
fi

# 証明書がすでにあるかどうかを先に確定させる。opensslは証明書の「作成」にだけ必要なので、
# 作成済みの環境ではopensslが古くてもビルドを止める理由にならない。
SIGNING_CERT_EXISTS=0
# pipefail下で grep -q が先に終わると security 側がSIGPIPEで落ち、証明書があるのに
# 「無い」と判定されうる。出力を変数へ取ってから調べる。
CODESIGNING_IDENTITIES="$(security find-identity -v -p codesigning 2>/dev/null || true)"
case "$CODESIGNING_IDENTITIES" in
  *'"Koedex Dev"'*) SIGNING_CERT_EXISTS=1 ;;
esac

# 3. opensslがOpenSSL 3系か（LibreSSLなら-legacy等のオプションを解さない）
OPENSSL_VERSION_OUTPUT="$(openssl version 2>/dev/null || true)"
if [[ "$OPENSSL_VERSION_OUTPUT" == *LibreSSL* ]]; then
  OPENSSL3_PATH=""
  BREW_OPENSSL3_PREFIX="$(brew --prefix openssl@3 2>/dev/null || true)"
  OPENSSL3_CANDIDATES=()
  [[ -n "$BREW_OPENSSL3_PREFIX" ]] && OPENSSL3_CANDIDATES+=("$BREW_OPENSSL3_PREFIX/bin/openssl")
  OPENSSL3_CANDIDATES+=("/opt/homebrew/opt/openssl@3/bin/openssl" "/usr/local/opt/openssl@3/bin/openssl")
  for candidate in "${OPENSSL3_CANDIDATES[@]}"; do
    if [[ -x "$candidate" ]]; then
      OPENSSL3_PATH="$candidate"
      break
    fi
  done
  if [[ -n "$OPENSSL3_PATH" ]]; then
    record ok "システムのopensslはLibreSSLですが、OpenSSL 3が見つかりました: $OPENSSL3_PATH"
  elif [[ "$SIGNING_CERT_EXISTS" -eq 1 ]]; then
    record warn "システムのopensslがLibreSSLでOpenSSL 3も見つかりませんが、証明書は作成済みのためビルドは進められます"
  else
    record fail "システムのopensslがLibreSSLで、OpenSSL 3が見つかりません（証明書作成に必要です）"
    ACTION_ITEMS+=("\`brew install openssl@3\` を実行してOpenSSL 3を導入してください。")
  fi
else
  record ok "opensslはOpenSSL 3系です"
fi

# 4. リポジトリのパスがiCloud同期下にないか
ICLOUD_DETECTED=0
CHECK_DIR="$ROOT_DIR"
while [[ "$CHECK_DIR" != "/" ]]; do
  DIR_XATTRS="$(xattr "$CHECK_DIR" 2>/dev/null || true)"
  if [[ "$DIR_XATTRS" == *"com.apple.file-provider-domain-id"* || "$DIR_XATTRS" == *"com.apple.fileprovider"* ]]; then
    ICLOUD_DETECTED=1
    break
  fi
  CHECK_DIR="$(dirname "$CHECK_DIR")"
done
if [[ "$ICLOUD_DETECTED" -eq 1 ]]; then
  # make_app.sh は署名の直前に、自分で作ったステージング複製へ xattr -cr をかけるため、
  # 多くの場合はこの場所のままでも署名できる。ただしiCloudが同期中に属性を付け直すことが
  # あるので、失敗した時の対処だけは先に伝えておく。
  record warn "リポジトリのパスがiCloud同期対象のディレクトリ配下にあります（署名の直前に拡張属性を除去するため、多くの場合はこのまま進められます）"
  record warn "もし署名で \"resource fork, Finder information, or similar detritus not allowed\" が出たら、\`~/Downloads\` など同期対象外の場所へ clone し直してください（\`mv\` での移動では拡張属性が残るため解決しません）"
else
  record ok "リポジトリのパスはiCloud同期対象ではありません"
fi

# 5. /Applications/Koedex.app が既に存在するか（警告のみ、不合格にはしない）
if [[ -e "/Applications/Koedex.app" ]]; then
  record warn "/Applications/Koedex.app が既に存在します。上書きする前に内容を確認してください"
else
  record ok "/Applications/Koedex.app はまだ存在しません"
fi

# 6. 空きディスク容量が2GB以上あるか
AVAILABLE_KB="$(df -k "$ROOT_DIR" 2>/dev/null | awk 'NR==2 {print $4}' || true)"
AVAILABLE_KB="${AVAILABLE_KB:-0}"
if [[ "$AVAILABLE_KB" =~ ^[0-9]+$ ]]; then
  AVAILABLE_GB=$(( AVAILABLE_KB / 1024 / 1024 ))
else
  AVAILABLE_KB=0
  AVAILABLE_GB=0
fi
if [[ "$AVAILABLE_KB" -ge $((2 * 1024 * 1024)) ]]; then
  record ok "空きディスク容量は約${AVAILABLE_GB}GB以上あります"
else
  record fail "空きディスク容量が不足しています（空き約${AVAILABLE_GB}GB、必要2GB以上）"
  ACTION_ITEMS+=("空き容量を2GB以上確保してください。")
fi

# 7. コード署名用証明書 "Koedex Dev" が信頼済みアイデンティティとして存在するか
if [[ "$SIGNING_CERT_EXISTS" -eq 1 ]]; then
  record ok "コード署名用証明書 \"Koedex Dev\" が見つかりました"
else
  record warn "コード署名用証明書 \"Koedex Dev\" はまだ作成されていません（初回は次の手順で作成します）"
  ACTION_ITEMS+=("\`bash scripts/make_signing_cert.sh\` を実行して証明書を作成してください（初回のみ。macOSの認証ダイアログの承認が1回必要です）。")
fi

print_report() {
  echo "=== Koedexビルド前提条件チェック ==="
  for line in "${RESULT_LINES[@]}"; do
    echo "$line"
  done
  if [[ "${#ACTION_ITEMS[@]}" -gt 0 ]]; then
    echo ""
    echo "=== あなたがやること ==="
    local i=1
    for action in "${ACTION_ITEMS[@]}"; do
      echo "$i. $action"
      i=$((i + 1))
    done
  fi
}

# --quiet は「全部問題なければ黙る」であって「警告を握りつぶす」ではない。
# make_app.sh からはこのモードで呼ばれるため、ここで隠すと利用者に警告が一切届かない。
if [[ "$QUIET" -eq 1 ]]; then
  if [[ "$OVERALL_STATUS" -ne 0 || "${#ACTION_ITEMS[@]}" -gt 0 || "$WARN_COUNT" -gt 0 ]]; then
    print_report
  fi
else
  print_report
fi

exit "$OVERALL_STATUS"
