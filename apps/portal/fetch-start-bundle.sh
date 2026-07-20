#!/bin/bash
set -e

# Populates apps/portal/priv/static/start with the DOSBox client bundle
# (dosbox.js, dosbox.wasm, loader.js, rs-<version>.data). These artifacts
# are not tracked in git; run this before building the server image or
# for local dev. init.js and README.md in that directory ARE tracked.
#
# Sources:
#   --from-local DIR    a packaged variant directory of the (private)
#                       ProdigyReloaded/client-bundles checkout, after
#                       running the em-dosbox-packager on it
#   --from-release      download from GitHub releases:
#                       runtime (dosbox.js/dosbox.wasm) from
#                       ProdigyReloaded/em-dosbox-packager, bundle
#                       (loader.js, rs-*.data) from
#                       ProdigyReloaded/client-bundles (private; needs an
#                       authenticated gh CLI)
#
# Options with --from-release:
#   --runtime-tag TAG   em-dosbox-packager release tag (default: latest)
#   --bundle-tag TAG    client-bundles release tag (default: latest)

DEST="$(cd "$(dirname "$0")" && pwd)/priv/static/start"
VARIANT_DATA_GLOB="rs-*.data"

usage() {
    sed -n '3,22p' "$0" | sed 's/^# \{0,1\}//'
    exit 1
}

MODE=""
SRC_DIR=""
RUNTIME_TAG=""
BUNDLE_TAG=""

while [ $# -gt 0 ]; do
    case "$1" in
        --from-local)   MODE=local; SRC_DIR="$2"; shift 2 ;;
        --from-release) MODE=release; shift ;;
        --runtime-tag)  RUNTIME_TAG="$2"; shift 2 ;;
        --bundle-tag)   BUNDLE_TAG="$2"; shift 2 ;;
        *) usage ;;
    esac
done

[ -n "$MODE" ] || usage
mkdir -p "$DEST"

case "$MODE" in
    local)
        [ -d "$SRC_DIR" ] || { echo "No such directory: $SRC_DIR"; exit 1; }
        for f in dosbox.js dosbox.wasm loader.js; do
            [ -f "$SRC_DIR/$f" ] || { echo "Missing $f in $SRC_DIR (run the packager first)"; exit 1; }
        done
        ls "$SRC_DIR"/$VARIANT_DATA_GLOB >/dev/null 2>&1 || { echo "Missing $VARIANT_DATA_GLOB in $SRC_DIR"; exit 1; }
        cp "$SRC_DIR"/dosbox.js "$SRC_DIR"/dosbox.wasm "$SRC_DIR"/loader.js "$SRC_DIR"/$VARIANT_DATA_GLOB "$DEST/"
        ;;
    release)
        command -v gh >/dev/null || { echo "gh CLI required for --from-release"; exit 1; }
        gh release download ${RUNTIME_TAG:+"$RUNTIME_TAG"} -R ProdigyReloaded/em-dosbox-packager \
            --pattern "dosbox.js" --pattern "dosbox.wasm" --dir "$DEST" --clobber
        gh release download ${BUNDLE_TAG:+"$BUNDLE_TAG"} -R ProdigyReloaded/client-bundles \
            --pattern "loader.js" --pattern "$VARIANT_DATA_GLOB" --dir "$DEST" --clobber
        ;;
esac

echo "Bundle staged in $DEST:"
ls -lh "$DEST"
