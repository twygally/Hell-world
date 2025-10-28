#!/usr/bin/env bash
set -euo pipefail
# Find and move duplicate files (by content) out of a directory tree.
# Keeps the FIRST encountered copy; moves all later duplicates to a target folder.
#
# Usage:
#   find_duplicates_keep_first.sh /path/to/scan /path/to/dupes_dir [--dry-run]
#
# Notes:
# - Duplicates are detected by SHA-256 of file content.
# - The kept file is the FIRST encountered during traversal.
# - Moved duplicates are renamed to "<hash>__<basename>" to avoid collisions.
# - Excludes the dupes_dir from scanning so we don't reprocess moved files.
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
case "$dupes_dir" in
  "$scan_dir"/*)
    echo "Note: dupes_dir is inside scan_dir; it will be excluded from scanning." >&2
    ;;
esac

# Make absolute paths for robust comparison
scan_dir="$(cd "$scan_dir" && pwd -P)"
dupes_dir="$(cd "$dupes_dir" && pwd -P)"

if [[ "$dry_run" == "--dry-run" ]]; then
  echo "Running in DRY RUN mode – no files will be moved."
fi

echo "Scanning directory: $scan_dir"
echo "Duplicates will be moved to: $dupes_dir"
echo "Strategy: Keep FIRST occurrence, move later duplicates"
echo ""

# Associative array: hash -> path of first file with that hash
declare -A SEEN

# Counters
file_count=0
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

echo "Processing files..."
echo ""

# Traverse files - disable errexit to avoid bash 5.2+ issues
set +e
while IFS= read -r -d '' file; do
  ((file_count++))

  # Show progress every 100 files
  if (( file_count % 100 == 0 )); then
    echo "  Processed $file_count files... (kept: $kept_count, moved: $moved_count)"
  fi

  # Compute SHA-256
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

  # Check if we've seen this hash before
  if [[ -z "${SEEN[$hash]+x}" ]]; then
    # First occurrence - keep it
    SEEN["$hash"]="$file"
    ((kept_count++))
  else
    # Duplicate found - move it
    base="$(basename -- "$file")"
    dest="$(unique_dest_path "$dupes_dir" "$hash" "$base")"

    if [[ "$dry_run" == "--dry-run" ]]; then
      echo "DUPLICATE: $file"
      echo "  (same as: ${SEEN[$hash]})"
      echo "  Would move to: $dest"
      echo ""
    else
      mv -- "$file" "$dest"
      echo "MOVED: $file"
      echo "  (duplicate of: ${SEEN[$hash]})"
      echo "  -> $dest"
      echo ""
    fi
    ((moved_count++))
  fi
done < <(find "$scan_dir" -type f -not -path "$dupes_dir/*" -print0)
set -e

# Print summary
echo ""
echo "========================================"
echo "=== Summary ==="
echo "========================================"
echo "Total files scanned: $file_count"
echo "Unique files kept (first occurrence): $kept_count"
echo "Duplicates moved: $moved_count"
echo "Files skipped (errors): $skipped_count"
echo "========================================"

if [[ "$dry_run" == "--dry-run" ]]; then
  echo ""
  echo "This was a DRY RUN. Run without --dry-run to actually move files."
fi
