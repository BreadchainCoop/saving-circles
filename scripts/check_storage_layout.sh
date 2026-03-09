#!/usr/bin/env bash
set -euo pipefail

OLD_REF="${1:-dev}"
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

link_deps() {
  local target_dir="$1"
  if [[ -d "$ROOT_DIR/node_modules" && ! -e "$target_dir/node_modules" ]]; then
    ln -s "$ROOT_DIR/node_modules" "$target_dir/node_modules"
  fi
  if [[ -d "$ROOT_DIR/lib" && ! -e "$target_dir/lib" ]]; then
    ln -s "$ROOT_DIR/lib" "$target_dir/lib"
  fi
}

inspect_layout() {
  local workdir="$1"
  local output_file="$2"
  local raw_file="$TMP_DIR/raw-$(basename "$output_file").txt"
  local canonical_file="$TMP_DIR/canonical-$(basename "$output_file")"

  if ! (cd "$workdir" && forge inspect "$CONTRACT_TARGET" storage-layout --json > "$raw_file"); then
    echo "forge inspect failed in $workdir"
    cat "$raw_file"
    return 1
  fi

  if ! jq -S . < "$raw_file" > "$output_file"; then
    echo "Failed to parse forge inspect output as JSON in $workdir"
    cat "$raw_file"
    return 1
  fi

  # Canonicalize layout by dropping compiler-internal IDs and normalizing type IDs.
  if ! jq -S '
      def norm_type:
        gsub("t_struct\\(([^)]*)\\)[0-9]+_storage"; "t_struct(\\1)_storage");

      {
        storage: [.storage[] | {label, slot, offset, type: (.type | norm_type)}],
        structs: (
          .types
          | to_entries
          | map(.value)
          | map(select(.label | startswith("struct ")))
          | map({
              label,
              members: [.members[] | {label, slot, offset, type: (.type | norm_type)}]
            })
          | sort_by(.label)
        )
      }
    ' "$output_file" > "$canonical_file"; then
    echo "Failed to canonicalize storage layout in $workdir"
    cat "$output_file"
    return 1
  fi
}

echo "Comparing storage layout for $CONTRACT_TARGET"
echo "Old ref: $OLD_REF"
echo "New ref: $NEW_REF"

git -C "$ROOT_DIR" worktree add --detach "$OLD_DIR" "$OLD_REF" >/dev/null
link_deps "$OLD_DIR"
inspect_layout "$OLD_DIR" "$TMP_DIR/old-layout.json"

if [[ "$NEW_REF" == "HEAD" ]]; then
  inspect_layout "$ROOT_DIR" "$TMP_DIR/new-layout.json"
else
  git -C "$ROOT_DIR" worktree add --detach "$NEW_DIR" "$NEW_REF" >/dev/null
  link_deps "$NEW_DIR"
  inspect_layout "$NEW_DIR" "$TMP_DIR/new-layout.json"
fi

if diff -u \
  "$TMP_DIR/canonical-old-layout.json" \
  "$TMP_DIR/canonical-new-layout.json"; then
  echo "Storage layout check passed: no differences detected."
else
  echo "Storage layout check failed: differences detected."
  exit 1
fi
