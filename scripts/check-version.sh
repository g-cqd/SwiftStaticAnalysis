#!/bin/bash
#
# Check version consistency across all files
#
# This script ensures the version number is consistent across:
# - VERSION file
# - Sources/swa/main.swift
# - README.md
# - Documentation files
#
# Usage: ./scripts/check-version.sh
#

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
cd "$PROJECT_ROOT"

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
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

# Check main.swift
MAIN_VERSION=$(grep -oE 'version: "[0-9]+\.[0-9]+\.[0-9]+"' Sources/swa/main.swift | grep -oE '[0-9]+\.[0-9]+\.[0-9]+' || echo "NOT_FOUND")
if [ "$MAIN_VERSION" != "$VERSION" ]; then
    echo -e "${RED}MISMATCH: Sources/swa/main.swift has version '$MAIN_VERSION'${NC}"
    ERRORS=$((ERRORS + 1))
else
    echo -e "${GREEN}OK: Sources/swa/main.swift${NC}"
fi

# Check README.md
README_VERSION=$(grep -oE 'from: "[0-9]+\.[0-9]+\.[0-9]+"' README.md | head -1 | grep -oE '[0-9]+\.[0-9]+\.[0-9]+' || echo "NOT_FOUND")
if [ "$README_VERSION" != "$VERSION" ]; then
    echo -e "${RED}MISMATCH: README.md has version '$README_VERSION'${NC}"
    ERRORS=$((ERRORS + 1))
else
    echo -e "${GREEN}OK: README.md${NC}"
fi

# Check CLIReference.md
CLI_REF_VERSION=$(grep -oE 'from: "[0-9]+\.[0-9]+\.[0-9]+"' Sources/SwiftStaticAnalysis/SwiftStaticAnalysis.docc/Articles/CLIReference.md | head -1 | grep -oE '[0-9]+\.[0-9]+\.[0-9]+' || echo "NOT_FOUND")
if [ "$CLI_REF_VERSION" != "$VERSION" ]; then
    echo -e "${RED}MISMATCH: CLIReference.md has version '$CLI_REF_VERSION'${NC}"
    ERRORS=$((ERRORS + 1))
else
    echo -e "${GREEN}OK: CLIReference.md${NC}"
fi

# Check GettingStarted.md
GETTING_STARTED_VERSION=$(grep -oE 'from: "[0-9]+\.[0-9]+\.[0-9]+"' Sources/SwiftStaticAnalysis/SwiftStaticAnalysis.docc/GettingStarted.md | head -1 | grep -oE '[0-9]+\.[0-9]+\.[0-9]+' || echo "NOT_FOUND")
if [ "$GETTING_STARTED_VERSION" != "$VERSION" ]; then
    echo -e "${RED}MISMATCH: GettingStarted.md has version '$GETTING_STARTED_VERSION'${NC}"
    ERRORS=$((ERRORS + 1))
else
    echo -e "${GREEN}OK: GettingStarted.md${NC}"
fi

# Check CHANGELOG.md has entry for this version
if ! grep -q "## \[$VERSION\]" CHANGELOG.md; then
    echo -e "${YELLOW}WARNING: CHANGELOG.md missing entry for version $VERSION${NC}"
fi

if [ $ERRORS -gt 0 ]; then
    echo -e "\n${RED}Version check failed with $ERRORS error(s)${NC}"
    echo -e "Run the following to update all versions:"
    echo -e "  sed -i '' 's/OLD_VERSION/$VERSION/g' Sources/swa/main.swift README.md Sources/SwiftStaticAnalysis/SwiftStaticAnalysis.docc/Articles/CLIReference.md Sources/SwiftStaticAnalysis/SwiftStaticAnalysis.docc/GettingStarted.md"
    exit 1
fi

echo -e "\n${GREEN}Version check passed! All files have version $VERSION${NC}"
exit 0
