#!/bin/bash
# Koedex.app のbundle ID、コード署名、Designated Requirementを検証する。
#
# Usage:
#   bash scripts/verify_app_identity.sh <app>
#   bash scripts/verify_app_identity.sh <old-app> <new-app>
#   bash scripts/verify_app_identity.sh --signer-fingerprint <app>
#
# 2つの.appを渡した場合は、各.appの検証に加え、bundle IDとDesignated
# Requirementと署名者証明書が更新前後で連続していることを確認する。
# --signer-fingerprint はmake_app.sh内部でのみ使う機械可読な確認用。
set -euo pipefail

usage() {
  cat >&2 <<EOF
Usage:
  $0 <app>
  $0 <old-app> <new-app>
  $0 --signer-fingerprint <app>

  <app>                    1つのKoedex.appを検証する
  <old-app> <new-app>      更新前後の.appを検証し、識別と署名者の連続性を確認する
  --signer-fingerprint     署名者証明書のSHA-1を内部確認用に出力する
EOF
  exit 1
}

fail() {
  echo "エラー: $*" >&2
  exit 1
}

if [[ "$#" -eq 2 && "$1" == "--signer-fingerprint" ]]; then
  output_mode="signer-fingerprint"
elif [[ "$#" -eq 1 || "$#" -eq 2 ]]; then
  output_mode="standard"
else
  usage
fi

validated_bundle_id=""
validated_requirement=""
validated_signer_fingerprint=""

verify_app() {
  local requested_path="$1"
  local app_path info_plist bundle_id bundle_icon_file ls_ui_element signed_metadata signed_identifier requirement_metadata requirement
  local certificate_directory certificate_prefix leaf_certificate signer_fingerprint

  [[ -d "$requested_path" ]] || fail "アプリが見つかりません: $requested_path"
  app_path="$(cd "$requested_path" && pwd -P)"
  info_plist="$app_path/Contents/Info.plist"
  [[ -f "$info_plist" ]] || fail "Info.plistが見つかりません: $app_path"

  bundle_id="$(plutil -extract CFBundleIdentifier raw -o - "$info_plist" 2>/dev/null || true)"
  [[ -n "$bundle_id" ]] || fail "CFBundleIdentifierを読み取れません: $app_path"

  case "$bundle_id" in
    com.koedex.app|com.koedex.onboarding-debug) ;;
    *) fail "想定外のbundle IDです: $bundle_id" ;;
  esac

  if [[ "$bundle_id" == "com.koedex.app" ]]; then
    ls_ui_element="$(plutil -extract LSUIElement raw -o - "$info_plist" 2>/dev/null || true)"
    case "$ls_ui_element" in
      false|0) ;;
      *) fail "通常版はLSUIElement=falseでDock表示する必要があります: $app_path" ;;
    esac

    bundle_icon_file="$(plutil -extract CFBundleIconFile raw -o - "$info_plist" 2>/dev/null || true)"
    [[ "$bundle_icon_file" == "Koedex.icns" ]] || fail "通常版のCFBundleIconFileがKoedex.icnsではありません: $app_path"
    [[ -f "$app_path/Contents/Resources/$bundle_icon_file" ]] || fail "通常版のDockアイコンが見つかりません: $app_path"
    [[ -f "$app_path/Contents/Resources/KoedexMenuBarTemplate.pdf" ]] || fail "通常版のメニューバーテンプレートPDFが見つかりません: $app_path"
    [[ -f "$app_path/Contents/Resources/ja.lproj/Localizable.strings" ]] || fail "通常版の日本語文字列カタログが見つかりません: $app_path"
    [[ -f "$app_path/Contents/Resources/en.lproj/Localizable.strings" ]] || fail "通常版の英語文字列カタログが見つかりません: $app_path"
  else
    ls_ui_element="$(plutil -extract LSUIElement raw -o - "$info_plist" 2>/dev/null || true)"
    case "$ls_ui_element" in
      false|0) ;;
      *) fail "Debug版はLSUIElement=falseで確認用Windowを表示する必要があります: $app_path" ;;
    esac
    [[ -f "$app_path/Contents/Resources/ja.lproj/Localizable.strings" ]] || fail "Debug版の日本語文字列カタログが見つかりません: $app_path"
    [[ -f "$app_path/Contents/Resources/en.lproj/Localizable.strings" ]] || fail "Debug版の英語文字列カタログが見つかりません: $app_path"
  fi

  if ! codesign --verify --deep --strict --verbose=2 "$app_path" >/dev/null 2>&1; then
    fail "コード署名の検証に失敗しました: $app_path"
  fi

  signed_metadata="$(codesign -dvv "$app_path" 2>&1)"
  signed_identifier="$(printf '%s\n' "$signed_metadata" | sed -n 's/^Identifier=//p' | head -n 1)"
  [[ "$signed_identifier" == "$bundle_id" ]] || fail "署名のIdentifierとInfo.plistのbundle IDが一致しません: $app_path"

  if [[ "$signed_metadata" == *"Signature=adhoc"* ]] || ! grep -q '^Authority=' <<<"$signed_metadata"; then
    fail "ad-hoc署名または信頼できる署名者のない.appです: $app_path"
  fi

  requirement_metadata="$(codesign -d -r- "$app_path" 2>&1)"
  requirement="$(printf '%s\n' "$requirement_metadata" | sed -n -E 's/^[[:space:]]*(#[[:space:]]*)?designated => //p' | tail -n 1)"
  [[ -n "$requirement" ]] || fail "Designated Requirementを読み取れません: $app_path"
  [[ "$requirement" == *"identifier \"$bundle_id\""* ]] || fail "Designated Requirementにbundle IDが含まれません: $app_path"

  certificate_directory="$(mktemp -d "${TMPDIR:-/tmp}/koedex-signing.XXXXXX")" || fail "署名者証明書の検証用ディレクトリを作成できません。"
  certificate_prefix="$certificate_directory/certificate"
  if ! codesign -d --extract-certificates="$certificate_prefix" "$app_path" >/dev/null 2>&1; then
    rm -rf "$certificate_directory"
    fail "署名者証明書を抽出できません: $app_path"
  fi
  leaf_certificate="${certificate_prefix}0"
  if [[ ! -f "$leaf_certificate" ]]; then
    rm -rf "$certificate_directory"
    fail "署名者証明書を読み取れません: $app_path"
  fi
  signer_fingerprint="$(shasum -a 1 "$leaf_certificate" | awk '{ print toupper($1) }')"
  rm -rf "$certificate_directory"
  [[ "$signer_fingerprint" =~ ^[[:xdigit:]]{40}$ ]] || fail "署名者証明書のSHA-1を読み取れません: $app_path"

  validated_bundle_id="$bundle_id"
  validated_requirement="$requirement"
  validated_signer_fingerprint="$signer_fingerprint"

  if [[ "$output_mode" == "standard" ]]; then
    echo "検証OK: $(basename "$app_path")"
    echo "  bundle ID: $bundle_id"
    echo "  コード署名: 有効（非ad-hoc）"
    echo "  Designated Requirement: 取得済み"
    echo "  署名者証明書: 取得済み"
  fi
}

if [[ "$output_mode" == "signer-fingerprint" ]]; then
  verify_app "$2"
  printf '%s\n' "$validated_signer_fingerprint"
  exit 0
fi

if [[ "$#" -eq 1 ]]; then
  verify_app "$1"
  exit 0
fi

verify_app "$1"
old_bundle_id="$validated_bundle_id"
old_requirement="$validated_requirement"
old_signer_fingerprint="$validated_signer_fingerprint"

verify_app "$2"
new_bundle_id="$validated_bundle_id"
new_requirement="$validated_requirement"
new_signer_fingerprint="$validated_signer_fingerprint"

[[ "$old_bundle_id" == "$new_bundle_id" ]] || fail "更新前後でbundle IDが変わっています。"
[[ "$old_requirement" == "$new_requirement" ]] || fail "更新前後でDesignated Requirementが変わっています。"
[[ "$old_signer_fingerprint" == "$new_signer_fingerprint" ]] || fail "更新前後で署名者証明書が変わっています。"

echo "更新互換性OK: bundle ID、Designated Requirement、署名者証明書は連続しています。"
