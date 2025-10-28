#!/usr/bin/env bash
set -euo pipefail
# Find and move duplicate files (by content) out of a directory tree.
# Keeps the first encountered copy; moves the rest to a target folder.
#
# Usage:
#   find_duplicates.sh /path/to/scan /path/to/dupes_dir [--dry-run]
#
# Notes:
# - Duplicates are detected by SHA-256 of file content.
# - The kept file is simply the first encountered during traversal.
# - Moved duplicates are renamed to "<hash>__<basename>" to avoid collisions.
# - Excludes the dupes_dir from scanning so we don't reprocess moved files.
# - Symlinks are followed by default; files they point to are hashed directly.
# - Requires bash 4+ (for associative arrays).

if [[ $# -lt 2 || $# -gt 3 ]]; then
  echo "Usage: $0 <scan_dir> <dupes_dir> [--dry-run]" >&2
  exit 1
fi

scan_dir="$1"
dupes_dir="$2"
dry_run="${3:-}"

if [[ ! -d "$scan_dir" ]]; then
  echo "Error: scan_dir does not exist or is not a directory: $scan_dir" >&2
  exit 1
fi

mkdir -p "$dupes_dir"

# Prevent pathological case: dupes_dir inside scan_dir.
# We'll exclude it from traversal either way, but warn the user.
case "$dupes_dir" in
  "$scan_dir"/*)
    echo "Note: dupes_dir is inside scan_dir; it will be excluded from scanning." >&2
    ;;
esac

# Make absolute paths for robust comparison
scan_dir="$(cd "$scan_dir" && pwd -P)"
dupes_dir="$(cd "$dupes_dir" && pwd -P)"

# Associative array: hash -> kept_path
declare -A SEEN

# Counters for summary
kept_count=0
moved_count=0
skipped_count=0

# Helper: create unique destination path to avoid overwrites
unique_dest_path() {
  local dest_dir="$1"
  local hash="$2"
  local base="$3"
  local candidate="${dest_dir}/${hash}__${base}"
  if [[ ! -e "$candidate" ]]; then
    printf '%s\n' "$candidate"
    return
  fi
  local n=1
  while :; do
    candidate="${dest_dir}/${hash}__${n}__${base}"
    [[ ! -e "$candidate" ]] && { printf '%s\n' "$candidate"; return; }
    ((n++))
  done
}

if [[ "$dry_run" == "--dry-run" ]]; then
  echo "Running in DRY RUN mode – no files will be moved."
fi

# Traverse files using process substitution to avoid subshell issues
# -type f : only files (follows symlinks by default)
# -not -path "$dupes_dir/*" : ignore files inside the dupes_dir
# -print0 : NUL-delimited for safety
while IFS= read -r -d '' file; do
  # Compute SHA-256; take only the hash
  # On macOS, 'shasum -a 256' is commonly available; on Linux, 'sha256sum' is common.
  # We'll try sha256sum first, then fallback to shasum.
  hash=""
  if command -v sha256sum >/dev/null 2>&1; then
    if hash="$(sha256sum -- "$file" 2>/dev/null | awk '{print $1}')"; then
      : # Success
    else
      echo "Warning: Failed to hash file (skipping): $file" >&2
      ((skipped_count++))
      continue
    fi
  elif command -v shasum >/dev/null 2>&1; then
    if hash="$(shasum -a 256 -- "$file" 2>/dev/null | awk '{print $1}')"; then
      : # Success
    else
      echo "Warning: Failed to hash file (skipping): $file" >&2
      ((skipped_count++))
      continue
    fi
  else
    echo "Error: neither sha256sum nor shasum found on PATH." >&2
    exit 1
  fi

  # If we haven't seen this content, mark it as the keeper
  if [[ -z "${SEEN[$hash]+x}" ]]; then
    SEEN["$hash"]="$file"
    ((kept_count++))
    # Optional: uncomment to log kept originals
    # echo "KEEP : $file"
  else
    # Duplicate detected – move it to dupes_dir
    base="$(basename -- "$file")"
    dest="$(unique_dest_path "$dupes_dir" "$hash" "$base")"
    if [[ "$dry_run" == "--dry-run" ]]; then
      echo "MOVE : $file -> $dest"
    else
      mv -- "$file" "$dest"
      echo "Moved duplicate: $file -> $dest"
    fi
    ((moved_count++))
  fi
done < <(find "$scan_dir" -type f -not -path "$dupes_dir/*" -print0)

# Print summary
echo ""
echo "=== Summary ==="
echo "Unique files kept: $kept_count"
echo "Duplicates moved: $moved_count"
echo "Files skipped (errors): $skipped_count"
