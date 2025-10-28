#!/usr/bin/env bash
set -euo pipefail
# DEBUG version - shows what files are being processed

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

# Make absolute paths for robust comparison
scan_dir="$(cd "$scan_dir" && pwd -P)"
dupes_dir="$(cd "$dupes_dir" && pwd -P)"

echo "=== DEBUG INFO ==="
echo "Scanning directory: $scan_dir"
echo "Duplicates directory: $dupes_dir"
echo ""

# First, let's see how many files find discovers
echo "Finding files with: find \"$scan_dir\" -type f -not -path \"$dupes_dir/*\" -print0"
file_count=$(find "$scan_dir" -type f -not -path "$dupes_dir/*" -print0 2>/dev/null | tr -cd '\0' | wc -c)
echo "Total files found by find: $file_count"
echo ""

if [[ $file_count -eq 0 ]]; then
  echo "ERROR: No files found! The find command returned no results."
  echo "This could mean:"
  echo "  1. The directory is empty"
  echo "  2. There are no regular files (only directories, symlinks, etc.)"
  echo "  3. Permission issues preventing file access"
  exit 1
fi

# Associative array: hash -> kept_path
declare -A SEEN

# Counters
kept_count=0
moved_count=0
skipped_count=0
processed_count=0

if [[ "$dry_run" == "--dry-run" ]]; then
  echo "Running in DRY RUN mode – no files will be moved."
fi
echo ""

# Traverse files
set +e
while IFS= read -r -d '' file; do
  ((processed_count++))
  echo "[$processed_count] Processing: $file"

  # Compute SHA-256
  hash=""
  if command -v sha256sum >/dev/null 2>&1; then
    if hash="$(sha256sum -- "$file" 2>/dev/null | awk '{print $1}')"; then
      echo "    Hash: ${hash:0:16}..."
    else
      echo "    WARNING: Failed to hash (skipping)"
      ((skipped_count++))
      continue
    fi
  elif command -v shasum >/dev/null 2>&1; then
    if hash="$(shasum -a 256 -- "$file" 2>/dev/null | awk '{print $1}')"; then
      echo "    Hash: ${hash:0:16}..."
    else
      echo "    WARNING: Failed to hash (skipping)"
      ((skipped_count++))
      continue
    fi
  else
    echo "Error: neither sha256sum nor shasum found on PATH." >&2
    exit 1
  fi

  # Check for duplicates
  if [[ -z "${SEEN[$hash]+x}" ]]; then
    SEEN["$hash"]="$file"
    ((kept_count++))
    echo "    Status: KEEP (first occurrence)"
  else
    echo "    Status: DUPLICATE of ${SEEN[$hash]}"
    ((moved_count++))
  fi
  echo ""
done < <(find "$scan_dir" -type f -not -path "$dupes_dir/*" -print0)
set -e

# Print summary
echo ""
echo "=== Summary ==="
echo "Files processed in loop: $processed_count"
echo "Unique files kept: $kept_count"
echo "Duplicates found: $moved_count"
echo "Files skipped (errors): $skipped_count"
