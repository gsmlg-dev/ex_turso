#!/usr/bin/env bash

align_rust_toolchain() {
  if [[ "$(uname -s)" != "Darwin" || "$(uname -m)" != "arm64" ]]; then
    return
  fi

  if ! command -v rustup >/dev/null 2>&1; then
    return
  fi

  local active
  active="$(rustup show active-toolchain 2>/dev/null | awk '{print $1}')"

  if [[ "${active}" != *"x86_64-apple-darwin"* ]]; then
    return
  fi

  local candidate="${active/x86_64-apple-darwin/aarch64-apple-darwin}"

  if rustup toolchain list | awk '{print $1}' | grep -Fxq "${candidate}"; then
    export RUSTUP_TOOLCHAIN="${candidate}"
    return
  fi

  echo "Active rustup toolchain ${active} builds x86_64 NIFs on arm64 macOS." >&2
  echo "Install ${candidate} or set RUSTUP_TOOLCHAIN to an arm64 toolchain." >&2
  exit 65
}
