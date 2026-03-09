#!/usr/bin/env bash
set -euo pipefail

OLD_REF="${1:-origin/dev}"
NEW_REF="${2:-HEAD}"
CONTRACT_TARGET="${3:-src/contracts/SavingCircles.sol:SavingCircles}"

ROOT_DIR="$(git rev-parse --show-toplevel)"
TMP_DIR="$(mktemp -d)"
OLD_DIR="$TMP_DIR/old"
NEW_DIR="$TMP_DIR/new"

cleanup() {
  git -C "$ROOT_DIR" worktree remove "$OLD_DIR" --force >/dev/null 2>&1 || true
  git -C "$ROOT_DIR" worktree remove "$NEW_DIR" --force >/dev/null 2>&1 || true
  rm -rf "$TMP_DIR"
}
trap cleanup EXIT

require_cmd() {
  local cmd="$1"
  if ! command -v "$cmd" >/dev/null 2>&1; then
    echo "Missing required command: $cmd"
    exit 1
  fi
}

ensure_node_modules_link() {
  local target_dir="$1"
  if [[ -d "$ROOT_DIR/node_modules" && ! -e "$target_dir/node_modules" ]]; then
    ln -s "$ROOT_DIR/node_modules" "$target_dir/node_modules"
  fi
}

prepare_worktree() {
  local ref="$1"
  local dir="$2"

  git -C "$ROOT_DIR" worktree add --detach "$dir" "$ref" >/dev/null

  if [[ -f "$dir/.gitmodules" ]]; then
    git -C "$dir" submodule sync --recursive >/dev/null
    git -C "$dir" submodule update --init --recursive >/dev/null
  fi

  ensure_node_modules_link "$dir"
}

build_info_dir_for() {
  local workdir="$1"
  local out_dir

  out_dir="$(cd "$workdir" && forge config --json | jq -r '.out // "out"')"
  echo "$workdir/$out_dir/build-info"
}

compile_for_validation() {
  local workdir="$1"
  local label="$2"

  echo "Compiling $label at $workdir ..."
  (
    cd "$workdir"
    forge clean
    forge build --build-info --extra-output storageLayout
  ) >/dev/null

  local build_info_dir
  build_info_dir="$(build_info_dir_for "$workdir")"

  if [[ ! -d "$build_info_dir" ]]; then
    echo "Build info directory not found for $label: $build_info_dir"
    echo "Make sure foundry.toml enables build_info."
    exit 1
  fi

  if ! find "$build_info_dir" -type f -name '*.json' | grep -q .; then
    echo "No build info JSON files found for $label in $build_info_dir"
    exit 1
  fi
}

echo "Running OpenZeppelin upgrade safety validation for $CONTRACT_TARGET"
echo "Old ref: $OLD_REF"
echo "New ref: $NEW_REF"

require_cmd git
require_cmd jq
require_cmd forge
require_cmd npx

prepare_worktree "$OLD_REF" "$OLD_DIR"
compile_for_validation "$OLD_DIR" "$OLD_REF"

if [[ "$NEW_REF" == "HEAD" ]]; then
  compile_for_validation "$ROOT_DIR" "$NEW_REF"
  NEW_BUILD_INFO_DIR="$(build_info_dir_for "$ROOT_DIR")"
else
  prepare_worktree "$NEW_REF" "$NEW_DIR"
  compile_for_validation "$NEW_DIR" "$NEW_REF"
  NEW_BUILD_INFO_DIR="$(build_info_dir_for "$NEW_DIR")"
fi

OLD_BUILD_INFO_DIR="$(build_info_dir_for "$OLD_DIR")"

OLD_REF_BUILD_INFO_LINK="$TMP_DIR/old-build-info"
ln -s "$OLD_BUILD_INFO_DIR" "$OLD_REF_BUILD_INFO_LINK"

echo "Validating upgrade safety with @openzeppelin/upgrades-core ..."
OZ_UPGRADES_SILENCE_WARNINGS=true npx --yes @openzeppelin/upgrades-core validate "$NEW_BUILD_INFO_DIR" \
  --contract "$CONTRACT_TARGET" \
  --reference "old-build-info:$CONTRACT_TARGET" \
  --referenceBuildInfoDirs "$OLD_REF_BUILD_INFO_LINK" \
  --requireReference

echo "Upgrade safety check passed for $CONTRACT_TARGET"
