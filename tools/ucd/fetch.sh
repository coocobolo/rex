#!/bin/sh
# Downloads the UCD files the generators read into tools/ucd/<version>/.
#
#   tools/ucd/fetch.sh 17.0.0
#
# Then set tools/ucd/VERSION to the new version, run `zig build gen`,
# and review the diff of the generated tables.
set -eu
v=${1:?usage: tools/ucd/fetch.sh <unicode-version>}
dir=$(dirname "$0")/$v
base=https://www.unicode.org/Public/$v/ucd
mkdir -p "$dir"
for f in \
    UnicodeData.txt EastAsianWidth.txt PropList.txt DerivedCoreProperties.txt \
    extracted/DerivedGeneralCategory.txt \
    auxiliary/GraphemeBreakProperty.txt auxiliary/GraphemeBreakTest.txt \
    emoji/emoji-data.txt
do
    echo "fetch $base/$f"
    curl -fsSL "$base/$f" -o "$dir/$(basename "$f")"
done
