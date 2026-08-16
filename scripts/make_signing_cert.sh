#!/bin/bash
# ローカル自己署名コード署名証明書 "Koedex Dev" をログインkeychainに作成するスクリプト。
#
# 目的: ad-hoc署名（codesign -s -）はビルドごとにアイデンティティが変わり、TCC権限
# （マイク・音声認識・アクセシビリティ）が再ビルドのたびに無効化されてしまう。
# 安定した自己署名証明書を使うことで、再ビルド後もTCC権限を再登録せずに済む。
#
# 既に "Koedex Dev" 証明書が存在すればスキップし、証明書のSHA-1ハッシュを出力する。
# CIなど非対話環境では --non-interactive を渡すと、作成不可の場合でも失敗させず
# メッセージを出してスキップする。
set -euo pipefail

CERT_NAME="Koedex Dev"
NON_INTERACTIVE=0
INTERACTIVE_HELP=0

for arg in "$@"; do
  case "$arg" in
    --non-interactive) NON_INTERACTIVE=1 ;;
    --interactive-help) INTERACTIVE_HELP=1 ;;
    *) ;;
  esac
done

existing_hash() {
  security find-identity -v -p codesigning | grep "\"$CERT_NAME\"" | head -1 | awk '{print $2}'
}

# codesigning用アイデンティティ（信頼済み）として既に使える場合。
HASH="$(existing_hash || true)"
if [[ -n "$HASH" ]]; then
  echo "=== 証明書 \"$CERT_NAME\" は既に存在し、信頼設定済みです ==="
  echo "SHA-1: $HASH"
  exit 0
fi

# keychainに証明書自体は存在するが信頼設定が未完了の場合（再実行での重複作成を防ぐ）。
# 冪等性のため、この時点で既に証明書がkeychainにあれば新規作成せず案内のみ再表示する。
EXISTING_CERT_IN_KEYCHAIN="$(security find-certificate -c "$CERT_NAME" "$HOME/Library/Keychains/login.keychain-db" 2>/dev/null | grep -c "labl" || true)"
if [[ "${EXISTING_CERT_IN_KEYCHAIN:-0}" -gt 0 ]]; then
  echo "=== 証明書 \"$CERT_NAME\" はkeychainに既に存在しますが、信頼設定（Trust）が未完了です ==="
  PERSISTENT_CERT_DIR="$HOME/Library/Application Support/Koedex"
  PERSISTENT_CERT_PATH="$PERSISTENT_CERT_DIR/koedex_dev_cert.crt"
  if [[ -f "$PERSISTENT_CERT_PATH" ]]; then
    echo "信頼設定を完了するには以下を実行し、認証ダイアログで承認してください:" >&2
    echo "  security add-trusted-cert -k \"\$HOME/Library/Keychains/login.keychain-db\" \"$PERSISTENT_CERT_PATH\"" >&2
  else
    echo "手動作成手順: bash $0 --interactive-help" >&2
  fi
  exit 0
fi

echo "=== 証明書 \"$CERT_NAME\" が見つかりません ==="

if [[ "$INTERACTIVE_HELP" -eq 1 ]]; then
  cat << 'EOF'
=== 手動作成手順（インタラクティブモード） ===
1. 「キーチェーンアクセス.app」を開く
2. メニューバー: キーチェーンアクセス → 証明書アシスタント → 証明書を作成...
3. 名前: "Koedex Dev"
4. identity種類: 自己署名ルート
5. 証明書の種類: コード署名
6. 「デフォルトを上書き」にチェックし、鍵ペア用途を「このアイテムのデフォルトを常に使用」から
   コード署名を確実に含める設定にして作成
7. 作成後、「ログイン」キーチェーンに保存されていることを確認
8. ターミナルで `security find-identity -v -p codesigning` を実行し、
   "Koedex Dev" が一覧に出ることを確認する

作成後、このスクリプトを再実行すればハッシュが表示されます。
EOF
  exit 0
fi

if [[ "$NON_INTERACTIVE" -eq 1 ]]; then
  echo "非対話モードのため証明書作成をスキップします。"
  echo "手動作成手順が必要な場合は: bash $0 --interactive-help"
  exit 0
fi

# 自己署名コード署名証明書を自動生成する。
# security create-keychainは使わず、既定のログインkeychainへ証明書を追加する形を取る。
# opensslで自己署名証明書＋秘密鍵を生成し、PKCS#12として一時的にエクスポートしてから
# securityコマンドでログインkeychainへインポートする（ユーザーのkeychainパスワード入力を
# 極力避けるため、既にアンロック状態のログインkeychainへの追加を試みる）。
WORKDIR="$(mktemp -d)"
trap 'rm -rf "$WORKDIR"' EXIT

KEY_PATH="$WORKDIR/koedex_dev.key"
CERT_PATH="$WORKDIR/koedex_dev.crt"
P12_PATH="$WORKDIR/koedex_dev.p12"
# This passphrase protects only the short-lived PKCS#12 file in WORKDIR.  It is
# generated per run, never printed, and becomes unusable when the trap removes
# that directory.
P12_PASSWORD="$(openssl rand -hex 32)"

echo "=== 自己署名証明書を生成しています ==="
openssl req -x509 -newkey rsa:2048 -keyout "$KEY_PATH" -out "$CERT_PATH" \
  -days 3650 -nodes -subj "/CN=$CERT_NAME" \
  -addext "keyUsage=critical,digitalSignature" \
  -addext "extendedKeyUsage=critical,codeSigning" >/dev/null 2>&1

# -legacy: OpenSSL 3.x はデフォルトでAES暗号化のPKCS#12を生成するが、macOSの
# securityコマンド（SecKeychainItemImport）はこれを正しく復号できずMAC検証エラーになる
# 場合がある。-legacyでRC2/3DES系の従来形式にすることでmacOS側と互換性を持たせる。
P12_PASSWORD="$P12_PASSWORD" openssl pkcs12 -export -out "$P12_PATH" -inkey "$KEY_PATH" -in "$CERT_PATH" \
  -name "$CERT_NAME" -passout env:P12_PASSWORD -legacy

echo "=== ログインkeychainへインポートしています ==="
if security import "$P12_PATH" -k "$HOME/Library/Keychains/login.keychain-db" \
  -P "$P12_PASSWORD" -T /usr/bin/codesign -T /usr/bin/security; then
  echo "インポートに成功しました。"
else
  echo "インポートに失敗しました。keychainがロックされている可能性があります。" >&2
  echo "手動作成手順: bash $0 --interactive-help" >&2
  exit 1
fi

# コード署名で使えるように、信頼設定に「常に信頼」を付与する（自己署名のため必要）。
# 重要: `add-trusted-cert` はGUIの認証ダイアログ（Touch ID/パスワード入力）を要求する。
# これは意図的なOSのセキュリティゲートであり、非対話シェルからは絶対に自動承認できない
# （承認するまでプロセスは無期限にブロックする）。そのためtimeoutで打ち切り、
# 承認されなかった場合は明確にその旨を案内する。
TRUST_TIMEOUT_SECONDS=5
if command -v timeout >/dev/null 2>&1; then
  TIMEOUT_CMD="timeout"
else
  # BSD/macOS標準にはtimeoutが無いことがあるため簡易フォールバック。
  TIMEOUT_CMD=""
fi

TRUST_ADDED=0
if [[ -n "$TIMEOUT_CMD" ]]; then
  # `-r trustAsRoot` は自己署名ルート証明書向けの厳格な設定だが、macOSによっては
  # `SecTrustSettingsSetTrustSettings: parameters were not valid` エラーで拒否されることがある。
  # `-r trustAsRoot` を省略した通常のadd-trusted-certでも codeSigning EKU を持つ自己署名証明書は
  # `find-identity -p codesigning` に登録されるため、まずこちらを試す。
  if $TIMEOUT_CMD "$TRUST_TIMEOUT_SECONDS" security add-trusted-cert -k "$HOME/Library/Keychains/login.keychain-db" "$CERT_PATH" 2>/dev/null; then
    TRUST_ADDED=1
  fi
else
  echo "注意: 'timeout'コマンドが無いため信頼設定の自動付与はスキップします（GUI承認ダイアログが必要なため）。" >&2
fi

NEW_HASH="$(existing_hash || true)"

if [[ "$TRUST_ADDED" -eq 1 && -n "$NEW_HASH" ]]; then
  echo "=== 証明書 \"$CERT_NAME\" を作成し、信頼設定も完了しました ==="
  echo "SHA-1: $NEW_HASH"
  exit 0
fi

# 証明書自体はkeychainに存在するがcodesigning用アイデンティティとしては未認識
# （信頼設定が付与されていない）。keychainから証明書を永続パスへ再エクスポートし、
# WORKDIR削除後も手動コマンドが使えるようにしておく。
PERSISTENT_CERT_DIR="$HOME/Library/Application Support/Koedex"
mkdir -p "$PERSISTENT_CERT_DIR"
PERSISTENT_CERT_PATH="$PERSISTENT_CERT_DIR/koedex_dev_cert.crt"
security find-certificate -c "$CERT_NAME" -p "$HOME/Library/Keychains/login.keychain-db" > "$PERSISTENT_CERT_PATH" 2>/dev/null || \
  cp "$CERT_PATH" "$PERSISTENT_CERT_PATH"

CERT_HASH="$(openssl x509 -in "$PERSISTENT_CERT_PATH" -noout -fingerprint -sha1 2>/dev/null | sed 's/^.*=//')"
echo "=== 証明書 \"$CERT_NAME\" はkeychainに作成されましたが、信頼設定（Trust）が未完了です ===" >&2
echo "SHA-1 (証明書): ${CERT_HASH:-不明}" >&2
echo "" >&2
echo "macOSの仕様上、自己署名証明書を codesign で使えるようにする「常に信頼」設定は" >&2
echo "GUIの認証ダイアログでの明示的な承認が必須で、スクリプトから自動化できません。" >&2
echo "以下のいずれかの方法で信頼設定を完了してください:" >&2
echo "  1. 「キーチェーンアクセス.app」を開き、\"$CERT_NAME\" を検索 → ダブルクリック →" >&2
echo "     「信頼」セクションを展開 → 「コード署名」を「常に信頼」に変更" >&2
echo "  2. またはターミナルで以下を実行し、表示される認証ダイアログで承認する:" >&2
echo "     security add-trusted-cert -k \"\$HOME/Library/Keychains/login.keychain-db\" \"$PERSISTENT_CERT_PATH\"" >&2
echo "" >&2
echo "信頼設定完了後、'security find-identity -v -p codesigning' に \"$CERT_NAME\" が表示されます。" >&2
echo "信頼設定が完了するまで、scripts/make_app.sh は安全のため.appの作成を停止します。" >&2
# 証明書自体の作成（keychainへの追加）は成功しているため、スクリプトとしては成功終了とする。
# 「codesign実行可能な状態への到達」は信頼設定の手動承認という別ステップであり、
# それが未完了であること自体はこのスクリプトの失敗ではない。
exit 0
