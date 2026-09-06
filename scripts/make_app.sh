#!/bin/bash
# swift build成果物を Koedex.app バンドルに組み立てるスクリプト。
set -euo pipefail

cd "$(dirname "$0")/.."
ROOT_DIR="$(pwd)"

CONFIGURATION="debug"
PREVIOUS_APP_PATH=""
if [[ "$#" -gt 0 && "$1" != "--previous-app" ]]; then
  CONFIGURATION="$1"
  shift
fi

while [[ "$#" -gt 0 ]]; do
  case "$1" in
    --previous-app)
      [[ "$#" -ge 2 ]] || {
        echo "エラー: --previous-app には更新前の.appへのパスが必要です。" >&2
        exit 1
      }
      [[ -z "$PREVIOUS_APP_PATH" ]] || {
        echo "エラー: --previous-app は1回だけ指定できます。" >&2
        exit 1
      }
      PREVIOUS_APP_PATH="$2"
      shift 2
      ;;
    *)
      echo "Usage: $0 [debug|release|onboarding-debug] [--previous-app /path/to/Koedex.app]" >&2
      exit 1
      ;;
  esac
done

if [[ "$CONFIGURATION" != "debug" && "$CONFIGURATION" != "release" && "$CONFIGURATION" != "onboarding-debug" ]]; then
  echo "Usage: $0 [debug|release|onboarding-debug] [--previous-app /path/to/Koedex.app]" >&2
  exit 1
fi

# 前提条件をまとめて検査してから始める。90秒のコンパイルを終えた後に、
# 事前に分かる理由で失敗させないための入口。
if [[ -f "$ROOT_DIR/scripts/preflight.sh" ]]; then
  if ! PREFLIGHT_OUTPUT="$(bash "$ROOT_DIR/scripts/preflight.sh" --quiet 2>&1)"; then
    echo "$PREFLIGHT_OUTPUT" >&2
    echo "=== 失敗: 前提条件が満たされていません ===" >&2
    exit 2
  fi
  [[ -n "$PREFLIGHT_OUTPUT" ]] && echo "$PREFLIGHT_OUTPUT"
fi

CERT_NAME="Koedex Dev"
IDENTITY_LIST="$(security find-identity -v -p codesigning 2>/dev/null || true)"
MATCHING_IDENTITIES=()
while IFS= read -r identity; do
  [[ -n "$identity" ]] && MATCHING_IDENTITIES+=("$identity")
done < <(printf '%s\n' "$IDENTITY_LIST" | awk -v certificate_name="$CERT_NAME" '
  index($0, "\"" certificate_name "\"") && $2 ~ /^[[:xdigit:]]{40}$/ { print toupper($2) }
')

if [[ "${#MATCHING_IDENTITIES[@]}" -gt 1 ]]; then
  cat >&2 <<EOF
エラー: "$CERT_NAME" と同名の有効なコード署名アイデンティティが複数あります。

権限を維持するには、毎回同じ証明書を使う必要があります。不要な同名証明書を
キーチェーンから整理して1つにしてから、もう一度実行してください。
EOF
  echo "=== 失敗: 前提条件が満たされていません ===" >&2
  exit 2
fi

SIGN_IDENTITY="${MATCHING_IDENTITIES[0]:-}"

if [[ ! "$SIGN_IDENTITY" =~ ^[[:xdigit:]]{40}$ ]]; then
  cat >&2 <<EOF
エラー: 安定したコード署名アイデンティティ "$CERT_NAME" が見つかりません。

マイク、音声認識、アクセシビリティのmacOS権限を更新後も維持するため、
ad-hoc署名（codesign --sign -）ではKoedex.appを作成しません。

次の手順で準備してください:
  1. bash scripts/make_signing_cert.sh
  2. 表示されるmacOSの認証ダイアログで、コード署名の信頼設定を承認する
  3. security find-identity -v -p codesigning を実行し、"$CERT_NAME" を確認する

証明書がkeychainにあるのに使えない場合は、次も参照してください:
  bash scripts/make_signing_cert.sh --interactive-help
EOF
  echo "=== 失敗: 前提条件が満たされていません ===" >&2
  exit 2
fi

IDENTITY_STATE_FILE="$ROOT_DIR/dist/.koedex-signing-identity"
PINNED_SIGN_IDENTITY=""
if [[ -f "$IDENTITY_STATE_FILE" ]]; then
  PINNED_SIGN_IDENTITY="$(tr -d '[:space:]' < "$IDENTITY_STATE_FILE")"
  if [[ ! "$PINNED_SIGN_IDENTITY" =~ ^[[:xdigit:]]{40}$ ]]; then
    echo "エラー: 署名IDの固定情報が壊れています: $IDENTITY_STATE_FILE" >&2
    echo "=== 失敗: 前提条件が満たされていません ===" >&2
    exit 2
  fi
  PINNED_SIGN_IDENTITY="$(printf '%s' "$PINNED_SIGN_IDENTITY" | tr '[:lower:]' '[:upper:]')"
  if [[ "$SIGN_IDENTITY" != "$PINNED_SIGN_IDENTITY" ]]; then
    cat >&2 <<EOF
エラー: 今回選ばれた署名証明書が、Koedexで固定済みの証明書と一致しません。

固定済みの証明書を使用するか、署名を変更する理由と既存利用者への権限再許可の
影響を確認してから、明示的な署名移行手順を行ってください。
EOF
    echo "=== 失敗: 署名または配置に失敗しました ===" >&2
    exit 4
  fi
fi

echo "=== 署名: 安定した \"$CERT_NAME\" 証明書を使用 ==="

if [[ "$CONFIGURATION" == "release" ]]; then
  echo "=== swift build (-c release) ==="
  if ! swift build -c release; then
    echo "=== 失敗: swift buildに失敗しました ===" >&2
    echo "上記のビルドエラーを確認し、修正してから再実行してください。" >&2
    exit 3
  fi
  BIN_PATH=".build/release/Koedex"
else
  echo "=== swift build (debug) ==="
  if ! swift build; then
    echo "=== 失敗: swift buildに失敗しました ===" >&2
    echo "上記のビルドエラーを確認し、修正してから再実行してください。" >&2
    exit 3
  fi
  BIN_PATH=".build/debug/Koedex"
fi

if [[ "$CONFIGURATION" == "onboarding-debug" ]]; then
  APP_NAME="Koedex Debug.app"
  APP_DISPLAY_NAME="Koedex Debug"
  BUNDLE_IDENTIFIER="com.koedex.onboarding-debug"
  LS_UI_ELEMENT="<false/>"
  ICON_PLIST_ENTRY=""
else
  APP_NAME="Koedex.app"
  APP_DISPLAY_NAME="Koedex"
  BUNDLE_IDENTIFIER="com.koedex.app"
  # 通常版はDockと⌘Tabに表示する。
  LS_UI_ELEMENT="<false/>"
  ICON_PLIST_ENTRY=$'    <key>CFBundleIconFile</key>\n    <string>Koedex.icns</string>'
fi

BRANDING_DIR="$ROOT_DIR/Assets/Branding"
BRANDING_ICONSET_DIR="$BRANDING_DIR/Koedex.iconset"
BRANDING_MENU_TEMPLATE="$BRANDING_DIR/KoedexMenuBarTemplate.pdf"
if [[ "$CONFIGURATION" == "debug" || "$CONFIGURATION" == "release" ]]; then
  [[ -d "$BRANDING_ICONSET_DIR" ]] || {
    echo "エラー: Dockアイコンのiconsetが見つかりません: $BRANDING_ICONSET_DIR" >&2
    echo "=== 失敗: 前提条件が満たされていません ===" >&2
    exit 2
  }
  for icon_name in \
    icon_16x16.png \
    icon_16x16@2x.png \
    icon_32x32.png \
    icon_32x32@2x.png \
    icon_128x128.png \
    icon_128x128@2x.png \
    icon_256x256.png \
    icon_256x256@2x.png \
    icon_512x512.png \
    icon_512x512@2x.png; do
    [[ -f "$BRANDING_ICONSET_DIR/$icon_name" ]] || {
      echo "エラー: Dockアイコンの必須サイズが見つかりません: $BRANDING_ICONSET_DIR/$icon_name" >&2
      echo "=== 失敗: 前提条件が満たされていません ===" >&2
      exit 2
    }
  done
  [[ -f "$BRANDING_MENU_TEMPLATE" ]] || {
    echo "エラー: メニューバー用テンプレートPDFが見つかりません: $BRANDING_MENU_TEMPLATE" >&2
    echo "=== 失敗: 前提条件が満たされていません ===" >&2
    exit 2
  }
  command -v iconutil >/dev/null 2>&1 || {
    echo "エラー: macOSのiconutilが見つからないため、Dockアイコンを生成できません。" >&2
    echo "=== 失敗: 前提条件が満たされていません ===" >&2
    exit 2
  }
fi

TARGET_APP_DIR="$ROOT_DIR/dist/$APP_NAME"
if [[ -n "$PREVIOUS_APP_PATH" ]]; then
  [[ -d "$PREVIOUS_APP_PATH" ]] || {
    echo "エラー: 更新前のアプリが見つかりません: $PREVIOUS_APP_PATH" >&2
    echo "=== 失敗: 前提条件が満たされていません ===" >&2
    exit 2
  }
  PREVIOUS_APP_PATH="$(cd "$PREVIOUS_APP_PATH" && pwd -P)"
fi

TARGET_APP_IS_STABLE=false
EXTERNAL_REFERENCE_IS_STABLE=false
if [[ -d "$TARGET_APP_DIR" ]]; then
  target_signer="$(bash "$ROOT_DIR/scripts/verify_app_identity.sh" --signer-fingerprint "$TARGET_APP_DIR" 2>/dev/null || true)"
  if [[ -n "$target_signer" ]]; then
    target_signer="$(printf '%s' "$target_signer" | tr '[:lower:]' '[:upper:]')"
    if [[ "$target_signer" != "$SIGN_IDENTITY" ]]; then
      cat >&2 <<EOF
エラー: 既存の$(basename "$TARGET_APP_DIR")は別の安定署名で作成されています。

現在の.appを上書きするとmacOS権限が継続しない可能性があるため、ビルドを中止しました。
署名移行の影響を確認してから、明示的な移行手順で作業してください。
EOF
      echo "=== 失敗: 署名または配置に失敗しました ===" >&2
      exit 4
    fi
    TARGET_APP_IS_STABLE=true
  else
    echo "注意: 既存の$(basename "$TARGET_APP_DIR")は安定署名として検証できません。" >&2
    echo "      不安定署名版からの初回移行では、macOSで一度だけ権限の再許可が必要になる場合があります。" >&2
  fi
fi

if [[ -n "$PREVIOUS_APP_PATH" && "$PREVIOUS_APP_PATH" != "$TARGET_APP_DIR" ]]; then
  external_signer="$(bash "$ROOT_DIR/scripts/verify_app_identity.sh" --signer-fingerprint "$PREVIOUS_APP_PATH" 2>/dev/null || true)"
  if [[ -n "$external_signer" ]]; then
    external_signer="$(printf '%s' "$external_signer" | tr '[:lower:]' '[:upper:]')"
    if [[ "$external_signer" != "$SIGN_IDENTITY" ]]; then
      cat >&2 <<EOF
エラー: --previous-appで指定した更新前アプリは別の安定署名で作成されています。

macOS権限が継続しない可能性があるため、ビルドを中止しました。署名移行の影響を
確認してから、明示的な移行手順で作業してください。
EOF
      echo "=== 失敗: 署名または配置に失敗しました ===" >&2
      exit 4
    fi
    EXTERNAL_REFERENCE_IS_STABLE=true
  else
    echo "注意: --previous-appで指定したアプリは安定署名として検証できません。" >&2
    echo "      不安定署名版からの初回移行では、macOSで一度だけ権限の再許可が必要になる場合があります。" >&2
  fi
fi

mkdir -p "$ROOT_DIR/dist"
STAGING_DIRECTORY="$(mktemp -d "$ROOT_DIR/dist/.koedex-staging.XXXXXX")"
APP_DIR="$STAGING_DIRECTORY/$APP_NAME"
CONTENTS_DIR="$APP_DIR/Contents"
MACOS_DIR="$CONTENTS_DIR/MacOS"
RESOURCES_DIR="$CONTENTS_DIR/Resources"
PREVIOUS_TARGET_BACKUP=""
REPLACEMENT_COMMITTED=false
cleanup_staging() {
  if [[ "${REPLACEMENT_COMMITTED:-false}" != true &&
        -n "${PREVIOUS_TARGET_BACKUP:-}" &&
        -d "$PREVIOUS_TARGET_BACKUP" ]]; then
    echo "エラー: 既存アプリの退避コピーを保持しました: $PREVIOUS_TARGET_BACKUP" >&2
    return 0
  fi
  if [[ -n "${STAGING_DIRECTORY:-}" && -d "$STAGING_DIRECTORY" ]]; then
    rm -rf "$STAGING_DIRECTORY"
  fi
  return 0
}
trap cleanup_staging EXIT

echo "=== .appバンドルを検証用ステージングへ組み立て ==="
mkdir -p "$MACOS_DIR" "$RESOURCES_DIR"

# 起動時ログで、更新直後の挙動を実際に起動した成果物と対応付けられるようにする。
# 取得できない配布環境でもビルド自体は止めない。
BUILD_GIT_SHA="$(git -C "$ROOT_DIR" rev-parse --short=12 HEAD 2>/dev/null || printf 'unknown')"

cp "$BIN_PATH" "$MACOS_DIR/Koedex"

# swift buildが生成したリソースバンドル（Koedex_Koedex.bundle等）を同梱する。
BUILD_DIR="$(dirname "$BIN_PATH")"
for bundle in "$BUILD_DIR"/*.bundle; do
  [[ -e "$bundle" ]] || continue
  cp -R "$bundle" "$RESOURCES_DIR/"
done

# SwiftUIの静的文言は製品.appのmain bundleからローカライズされるため、
# SwiftPM resource bundleとは別に日英の文字列カタログを配置する。
for localization in "$ROOT_DIR"/Sources/Koedex/Resources/*.lproj; do
  [[ -d "$localization" ]] || continue
  cp -R "$localization" "$RESOURCES_DIR/"
done

if [[ "$CONFIGURATION" == "debug" || "$CONFIGURATION" == "release" ]]; then
  echo "=== Dock・メニューバー用アセットを同梱 ==="
  iconutil -c icns "$BRANDING_ICONSET_DIR" -o "$RESOURCES_DIR/Koedex.icns"
  cp "$BRANDING_MENU_TEMPLATE" "$RESOURCES_DIR/KoedexMenuBarTemplate.pdf"
fi

cat > "$CONTENTS_DIR/Info.plist" << PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key>
    <string>$APP_DISPLAY_NAME</string>
    <key>CFBundleDisplayName</key>
    <string>$APP_DISPLAY_NAME</string>
    <key>CFBundleIdentifier</key>
    <string>$BUNDLE_IDENTIFIER</string>
    <key>CFBundleVersion</key>
    <string>0.1.9</string>
    <key>CFBundleShortVersionString</key>
    <string>0.1.9</string>
    <key>KoedexBuildGitSHA</key>
    <string>$BUILD_GIT_SHA</string>
    <key>CFBundlePackageType</key>
    <string>APPL</string>
    <key>CFBundleExecutable</key>
    <string>Koedex</string>
${ICON_PLIST_ENTRY}
    <key>LSMinimumSystemVersion</key>
    <string>26.0</string>
    <key>LSUIElement</key>
    $LS_UI_ELEMENT
    <key>NSMicrophoneUsageDescription</key>
    <string>Koedexは音声入力の文字起こしのためにマイクを使用します。音声データは端末内で処理され、外部へ送信されることはありません。</string>
    <key>NSSpeechRecognitionUsageDescription</key>
    <string>Koedexは音声をテキストに変換するためにmacOSのオンデバイス音声認識を使用します。</string>
    <key>NSAppleEventsUsageDescription</key>
    <string>Koedexはカーソル位置へテキストを挿入するために他のアプリを操作します。</string>
</dict>
</plist>
PLIST

# ステージング領域（$STAGING_DIRECTORY配下、mktemp -dでスクリプト自身が複製した.app）の
# 拡張属性を除去する。ユーザーのソースツリーには一切触れない。
# iCloud同期下で拡張属性（com.apple.fileprovider.dir#N等）が付いたまま作業していると、
# codesignが "resource fork, Finder information, or similar detritus not allowed" で失敗するため。
xattr -cr "$APP_DIR"

if ! codesign --force --sign "$SIGN_IDENTITY" "$APP_DIR"; then
  echo "=== 失敗: コード署名に失敗しました ===" >&2
  echo "証明書やkeychainの状態を確認し、必要であれば bash scripts/make_signing_cert.sh を再実行してください。" >&2
  exit 4
fi

echo "=== 署名検証 ==="
verify_or_fail() {
  if ! bash "$ROOT_DIR/scripts/verify_app_identity.sh" "$@"; then
    echo "=== 失敗: 署名または配置に失敗しました ===" >&2
    echo "組み立てたアプリの署名を検証できませんでした。既存のアプリは置き換えていません。" >&2
    exit 4
  fi
}
verify_or_fail "$APP_DIR"
if [[ "$TARGET_APP_IS_STABLE" == true ]]; then
  verify_or_fail "$TARGET_APP_DIR" "$APP_DIR"
fi
if [[ "$EXTERNAL_REFERENCE_IS_STABLE" == true ]]; then
  verify_or_fail "$PREVIOUS_APP_PATH" "$APP_DIR"
fi

if [[ -d "$TARGET_APP_DIR" ]]; then
  PREVIOUS_TARGET_BACKUP="$STAGING_DIRECTORY/previous-$(basename "$TARGET_APP_DIR")"
  mv "$TARGET_APP_DIR" "$PREVIOUS_TARGET_BACKUP"
fi
if ! mv "$APP_DIR" "$TARGET_APP_DIR"; then
  if [[ -n "$PREVIOUS_TARGET_BACKUP" && -d "$PREVIOUS_TARGET_BACKUP" ]]; then
    if [[ -e "$TARGET_APP_DIR" || -L "$TARGET_APP_DIR" ]]; then
      echo "エラー: 配置失敗後に出力先が存在するため、安全に復元できません。退避コピーを保持しています: $PREVIOUS_TARGET_BACKUP" >&2
      echo "=== 失敗: 署名または配置に失敗しました ===" >&2
      exit 4
    fi
    if mv "$PREVIOUS_TARGET_BACKUP" "$TARGET_APP_DIR"; then
      PREVIOUS_TARGET_BACKUP=""
    else
      echo "エラー: 既存アプリの復元に失敗しました。退避コピーを保持しています: $PREVIOUS_TARGET_BACKUP" >&2
      echo "=== 失敗: 署名または配置に失敗しました ===" >&2
      exit 4
    fi
  fi
  echo "エラー: 検証済みアプリを配置できませんでした。既存アプリを復元しました。" >&2
  echo "=== 失敗: 署名または配置に失敗しました ===" >&2
  exit 4
fi
if [[ ! -d "$TARGET_APP_DIR" ]]; then
  echo "エラー: 検証済みアプリの配置を確認できませんでした。" >&2
  echo "=== 失敗: 署名または配置に失敗しました ===" >&2
  exit 4
fi
if [[ -n "$PREVIOUS_TARGET_BACKUP" ]]; then
  rm -rf "$PREVIOUS_TARGET_BACKUP"
  PREVIOUS_TARGET_BACKUP=""
fi
REPLACEMENT_COMMITTED=true

if [[ -z "$PINNED_SIGN_IDENTITY" ]]; then
  umask 077
  printf '%s\n' "$SIGN_IDENTITY" > "$IDENTITY_STATE_FILE"
  echo "=== 署名IDをこのMacのKoedexビルド用に固定しました ==="
fi

echo "=== 完了: $TARGET_APP_DIR ==="
