#!/usr/bin/env bash
set -euo pipefail
# Find and move duplicate files (by content) out of a directory tree.
# Keeps the LAST encountered copy; moves all earlier duplicates to a target folder.
#
# Usage:
#   find_duplicates_keep_last.sh /path/to/scan /path/to/dupes_dir [--dry-run]
#
# Notes:
# - Duplicates are detected by SHA-256 of file content.
# - The kept file is the LAST encountered during traversal.
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
echo ""

# Associative arrays:
# hash -> list of files with that hash (space-separated, will be parsed carefully)
declare -A hash_to_files
# file -> hash lookup
declare -A file_to_hash

# Arrays for all files
declare -a all_files

# Counters
file_count=0
skipped_count=0

echo "Phase 1: Scanning and hashing all files..."

# Collect all files and hash them
set +e
while IFS= read -r -d '' file; do
  ((file_count++))

  # Show progress every 100 files
  if (( file_count % 100 == 0 )); then
    echo "  Processed $file_count files..."
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

  # Store the file and its hash
  all_files+=("$file")
  file_to_hash["$file"]="$hash"

  # Append to the list of files with this hash
  # We use a delimiter that won't appear in file paths
  if [[ -z "${hash_to_files[$hash]+x}" ]]; then
    hash_to_files["$hash"]="$file"
  else
    hash_to_files["$hash"]+=$'\x1E'"$file"  # ASCII Record Separator
  fi

done < <(find "$scan_dir" -type f -not -path "$dupes_dir/*" -print0)
set -e

echo "  Completed: $file_count files processed"
echo ""

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

echo "Phase 2: Identifying and moving duplicates..."

kept_count=0
moved_count=0
duplicate_groups=0

# Process each hash group
# Temporarily disable errexit for this section
set +e
for hash in "${!hash_to_files[@]}"; do
  # Split the file list by the delimiter
  IFS=$'\x1E' read -ra files_array <<< "${hash_to_files[$hash]}"

  # If only one file has this hash, it's unique
  if [[ ${#files_array[@]} -eq 1 ]]; then
    ((kept_count++))
    continue
  fi

  # Multiple files with same hash = duplicates!
  ((duplicate_groups++))
  num_files=${#files_array[@]}

  echo "Found $num_files duplicates (keeping last):"

  # Keep the LAST file, move all earlier ones
  last_idx=$((num_files - 1))
  for i in "${!files_array[@]}"; do
    file="${files_array[$i]}"

    if [[ $i -eq $last_idx ]]; then
      # This is the last one - keep it
      echo "  KEEP: $file"
      ((kept_count++))
    else
      # This is an earlier duplicate - move it
      base="$(basename -- "$file")"
      dest="$(unique_dest_path "$dupes_dir" "$hash" "$base")"

      if [[ "$dry_run" == "--dry-run" ]]; then
        echo "  MOVE: $file -> $dest"
      else
        mv -- "$file" "$dest"
        echo "  MOVE: $file -> $dest"
      fi
      ((moved_count++))
    fi
  done
  echo ""
done
set -e

# Print summary
echo "=== Summary ==="
echo "Total files scanned: $file_count"
echo "Unique files (no duplicates): $((kept_count - duplicate_groups))"
echo "Duplicate groups found: $duplicate_groups"
echo "Files kept (last of each group): $duplicate_groups"
echo "Duplicates moved: $moved_count"
echo "Files skipped (errors): $skipped_count"

if [[ "$dry_run" == "--dry-run" ]]; then
  echo ""
  echo "This was a DRY RUN. Run without --dry-run to actually move files."
fi
