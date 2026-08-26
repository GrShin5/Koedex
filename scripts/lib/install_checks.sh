#!/bin/bash
# Shared, read-only probes for the local installation scripts.

koedex_keychain_state() {
  local output status
  output="$(security find-identity -v -p codesigning 2>&1)"; status=$?
  KOEDEX_KEYCHAIN_OUTPUT="$output"
  if [[ $status -ne 0 ]]; then
    printf '%s\n' inaccessible
  elif [[ "$output" == *'"Koedex Dev"'* ]]; then
    printf '%s\n' found
  else
    printf '%s\n' absent
  fi
}

koedex_openssl3_candidates() {
  local path_candidate brew_prefix candidate
  if [[ "$#" -gt 0 ]]; then
    printf '%s\n' "$@"
    return 0
  fi
  path_candidate="$(command -v openssl 2>/dev/null || true)"
  brew_prefix="$(brew --prefix openssl@3 2>/dev/null || true)"
  for candidate in "$path_candidate" "${brew_prefix:+$brew_prefix/bin/openssl}" \
    /opt/homebrew/opt/openssl@3/bin/openssl /usr/local/opt/openssl@3/bin/openssl; do
    [[ -n "$candidate" && -x "$candidate" ]] || continue
    candidate="$(cd "$(dirname "$candidate")" && pwd -P)/$(basename "$candidate")"
    case "|${seen:-}|" in *"|$candidate|"*) continue ;; esac
    seen="${seen:-}|$candidate"
    printf '%s\n' "$candidate"
  done
}

koedex_find_openssl3() {
  local candidate version
  while IFS= read -r candidate; do
    version="$("$candidate" version 2>&1 || true)"
    if [[ "$version" == OpenSSL\ 3* ]]; then
      printf '%s\n' "$candidate"
      return 0
    fi
  done < <(koedex_openssl3_candidates "$@")
  return 1
}

koedex_install_target_exists() {
  [[ "$#" -eq 1 ]] || return 2
  [[ -e "$1" || -L "$1" ]]
}

koedex_codesign_failure_class() {
  local text="$1"
  if [[ "$text" == *"User interaction is not allowed"* || "$text" == *"keychain"* || "$text" == *"Keychain"* ]]; then
    printf '%s\n' keychain-inaccessible
  elif [[ "$text" == *"code object is not signed at all"* || "$text" == *"invalid signature"* || "$text" == *"a sealed resource is missing or invalid"* ]]; then
    printf '%s\n' signature-corrupt
  else
    printf '%s\n' signature-verification-failed
  fi
}
