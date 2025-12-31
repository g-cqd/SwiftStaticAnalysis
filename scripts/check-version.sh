#!/bin/bash
#
# Check and optionally fix version consistency across all files
#
# This script ensures the version number is consistent across:
# - VERSION file (single source of truth)
# - Sources/swa/main.swift
# - README.md
# - Documentation files
#
# Usage:
#   ./scripts/check-version.sh          # Check only
#   ./scripts/check-version.sh --fix    # Check and auto-fix discrepancies
#

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
cd "$PROJECT_ROOT"

# Parse arguments
AUTO_FIX=false
if [ "$1" = "--fix" ] || [ "$1" = "-f" ]; then
    AUTO_FIX=true
fi

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

# Get version from VERSION file (single source of truth)
if [ ! -f "VERSION" ]; then
    echo -e "${RED}ERROR: VERSION file not found${NC}"
    exit 1
fi

VERSION=$(cat VERSION | tr -d '[:space:]')

if [ -z "$VERSION" ]; then
    echo -e "${RED}ERROR: VERSION file is empty${NC}"
    exit 1
fi

echo "Checking version consistency (expected: $VERSION)..."

ERRORS=0
FIXED=0

# Function to check and optionally fix a file
check_and_fix() {
    local file="$1"
    local pattern="$2"
    local current_version="$3"
    local display_name="$4"

    if [ "$current_version" = "NOT_FOUND" ]; then
        echo -e "${RED}ERROR: Could not find version in $display_name${NC}"
        ERRORS=$((ERRORS + 1))
        return
    fi

    if [ "$current_version" != "$VERSION" ]; then
        if [ "$AUTO_FIX" = true ]; then
            # Auto-fix the version
            sed -i '' "s/$current_version/$VERSION/g" "$file"
            echo -e "${BLUE}FIXED: $display_name ($current_version → $VERSION)${NC}"
            FIXED=$((FIXED + 1))
        else
            echo -e "${RED}MISMATCH: $display_name has version '$current_version'${NC}"
            ERRORS=$((ERRORS + 1))
        fi
    else
        echo -e "${GREEN}OK: $display_name${NC}"
    fi
}

# Check main.swift
MAIN_VERSION=$(grep -oE 'version: "[0-9]+\.[0-9]+\.[0-9]+"' Sources/swa/main.swift | grep -oE '[0-9]+\.[0-9]+\.[0-9]+' || echo "NOT_FOUND")
check_and_fix "Sources/swa/main.swift" 'version: "X"' "$MAIN_VERSION" "Sources/swa/main.swift"

# Check README.md
README_VERSION=$(grep -oE 'from: "[0-9]+\.[0-9]+\.[0-9]+"' README.md | head -1 | grep -oE '[0-9]+\.[0-9]+\.[0-9]+' || echo "NOT_FOUND")
check_and_fix "README.md" 'from: "X"' "$README_VERSION" "README.md"

# Check CLIReference.md
CLI_REF_VERSION=$(grep -oE 'from: "[0-9]+\.[0-9]+\.[0-9]+"' Sources/SwiftStaticAnalysis/SwiftStaticAnalysis.docc/Articles/CLIReference.md | head -1 | grep -oE '[0-9]+\.[0-9]+\.[0-9]+' || echo "NOT_FOUND")
check_and_fix "Sources/SwiftStaticAnalysis/SwiftStaticAnalysis.docc/Articles/CLIReference.md" 'from: "X"' "$CLI_REF_VERSION" "CLIReference.md"

# Check GettingStarted.md
GETTING_STARTED_VERSION=$(grep -oE 'from: "[0-9]+\.[0-9]+\.[0-9]+"' Sources/SwiftStaticAnalysis/SwiftStaticAnalysis.docc/GettingStarted.md | head -1 | grep -oE '[0-9]+\.[0-9]+\.[0-9]+' || echo "NOT_FOUND")
check_and_fix "Sources/SwiftStaticAnalysis/SwiftStaticAnalysis.docc/GettingStarted.md" 'from: "X"' "$GETTING_STARTED_VERSION" "GettingStarted.md"

# Check CHANGELOG.md has entry for this version
if ! grep -q "## \[$VERSION\]" CHANGELOG.md; then
    echo -e "${YELLOW}WARNING: CHANGELOG.md missing entry for version $VERSION${NC}"
fi

# Summary
if [ $FIXED -gt 0 ]; then
    echo -e "\n${BLUE}Fixed $FIXED file(s)${NC}"
fi

if [ $ERRORS -gt 0 ]; then
    echo -e "\n${RED}Version check failed with $ERRORS error(s)${NC}"
    if [ "$AUTO_FIX" = false ]; then
        echo -e "Run with --fix to auto-fix: ./scripts/check-version.sh --fix"
    fi
    exit 1
fi

echo -e "\n${GREEN}Version check passed! All files have version $VERSION${NC}"
exit 0
