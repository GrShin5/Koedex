#!/bin/bash
# Install only a verified, signed dist/Koedex.app.  No arguments are accepted.
set -euo pipefail

[[ $# -eq 0 ]] || { echo "Usage: $0" >&2; exit 2; }
ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd -P)"
SOURCE_APP="$ROOT_DIR/dist/Koedex.app"
TARGET_APP="/Applications/Koedex.app"
[[ -d "$SOURCE_APP" && ! -L "$SOURCE_APP" ]] || { echo "エラー: 入力appがありません: $SOURCE_APP" >&2; exit 2; }
if [[ -e "$TARGET_APP" || -L "$TARGET_APP" ]]; then
  echo "エラー: インストール先は既に存在するため上書きしません: $TARGET_APP" >&2; exit 2
fi
TARGET_PARENT="$(dirname "$TARGET_APP")"
[[ -d "$TARGET_PARENT" && ! -L "$TARGET_PARENT" ]] || { echo "エラー: インストール先の親ディレクトリが安全ではありません" >&2; exit 2; }
TEMP_ROOT="$(mktemp -d "$TARGET_PARENT/.koedex-install.XXXXXX")"
TEMP_APP="$TEMP_ROOT/Koedex.app"
CLAIMED_TARGET=0
CLAIMED_TARGET_ID=""
# TEMP_ROOT was created by mktemp directly below the fixed target parent.  Never
# remove a caller-provided path or an existing installation target.
owns_claimed_target() {
  [[ "$CLAIMED_TARGET" -eq 1 && -d "$TARGET_APP" && ! -L "$TARGET_APP" ]] || return 1
  [[ "$(stat -f '%d:%i' "$TARGET_APP" 2>/dev/null || true)" == "$CLAIMED_TARGET_ID" ]]
}
cleanup() {
  [[ -n "${TEMP_ROOT:-}" && -d "$TEMP_ROOT" ]] && rm -rf "$TEMP_ROOT"
  if owns_claimed_target; then
    rm -rf "$TARGET_APP"
  fi
  return 0
}
trap cleanup EXIT

ditto "$SOURCE_APP" "$TEMP_APP"
bash "$ROOT_DIR/scripts/verify_app_identity.sh" "$SOURCE_APP"
bash "$ROOT_DIR/scripts/verify_app_identity.sh" "$TEMP_APP"
bash "$ROOT_DIR/scripts/verify_app_identity.sh" "$SOURCE_APP" "$TEMP_APP"
# mkdir is the no-clobber claim: a competing app/file/symlink makes it fail,
# and we never pass an existing directory to mv (which could nest the bundle).
if ! mkdir "$TARGET_APP"; then
  echo "エラー: インストール先が競合したため上書きせず停止しました" >&2; exit 2
fi
CLAIMED_TARGET=1
CLAIMED_TARGET_ID="$(stat -f '%d:%i' "$TARGET_APP" 2>/dev/null || true)"
[[ -n "$CLAIMED_TARGET_ID" ]] || { echo "エラー: インストール先の所有確認に失敗しました" >&2; exit 2; }
owns_claimed_target || { echo "エラー: インストール先が検証中に置き換えられました" >&2; exit 2; }
mv "$TEMP_APP/Contents" "$TARGET_APP/Contents"
[[ ! -e "$TEMP_APP/Contents" && -d "$TARGET_APP/Contents" ]] || { echo "エラー: 一時appを確定できませんでした" >&2; exit 2; }
bash "$ROOT_DIR/scripts/verify_app_identity.sh" "$SOURCE_APP" "$TARGET_APP"
CLAIMED_TARGET=0
rm -rf "$TEMP_ROOT"; TEMP_ROOT=""
echo "インストールOK: $TARGET_APP"
