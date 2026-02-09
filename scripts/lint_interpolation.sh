#!/bin/bash
# Lint check: Flag potentially broken Julia string interpolation with array indexing.
#
# In Julia, "$var[i]" interpolates `var` then appends literal "[i]".
# The correct form is "$(var[i])".
#
# This script searches for the pattern `$identifier[` inside string literals
# in Julia source files and reports matches as warnings.
#
# Usage:
#   bash scripts/lint_interpolation.sh [directory]
#   (defaults to src/)
#
# Exit code:
#   0 - no issues found
#   1 - potential interpolation bugs found

set -euo pipefail

SEARCH_DIR="${1:-src}"

# Pattern: dollar sign followed by an identifier (letters, digits, underscore)
# immediately followed by an opening bracket. This catches "$var[" but not "$(var[".
PATTERN='\$[a-zA-Z_][a-zA-Z0-9_]*\['

# Use grep to find matches, excluding comments and non-string contexts is hard
# statically, so we report all matches for manual review.
MATCHES=$(grep -rn --include='*.jl' -E "$PATTERN" "$SEARCH_DIR" 2>/dev/null || true)

if [ -n "$MATCHES" ]; then
    echo "WARNING: Potentially broken string interpolation found!"
    echo ""
    echo "In Julia, \"\\\$var[i]\" interpolates \`var\` then appends literal \"[i]\"."
    echo "Use \"\\\$(var[i])\" instead for array indexing."
    echo ""
    echo "Matches:"
    echo "$MATCHES"
    echo ""
    echo "Please review each match and fix if inside a string literal."
    exit 1
else
    echo "OK: No broken string interpolation patterns found in $SEARCH_DIR/"
    exit 0
fi
