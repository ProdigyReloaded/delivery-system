# DOSBox client bundle

This directory is where the portal's `/start` page loads the in-browser
Prodigy client from. Only `init.js` (hand-written glue wiring DOSBox's
`Module` to the page's `#status` / `#progress` / `#canvas` elements) and
this README are tracked; the bundle artifacts are gitignored and staged
by `apps/portal/fetch-start-bundle.sh`.

## Expected files

- `dosbox.js` - emscripten loader (built)
- `dosbox.wasm` - emscripten WASM binary (built)
- `loader.js` - generated virtual-filesystem data loader
- `rs-6.03.17.data` - packed Prodigy RS client image
- `init.js` - hand-written glue (tracked)

## How to populate

The emulator runtime is built by the public
`ProdigyReloaded/em-dosbox-packager` repo; the client bundle is packaged
from the private `ProdigyReloaded/client-bundles` repo. Either:

    apps/portal/fetch-start-bundle.sh --from-release

(downloads pinned artifacts from those repos' GitHub releases; the
client-bundles download requires an authenticated `gh`), or, with local
checkouts after running the packager:

    apps/portal/fetch-start-bundle.sh --from-local ../client-bundles/6.03.17

## Persistent client storage

`init.js` mounts IDBFS over the client's mutable files (`CACHE.DAT`,
`STAGE.DAT`) so they survive page reloads per browser: on boot it overlays
any saved copies onto the emulated C:; on a 10s timer and on `beforeunload`
it copies them back and `syncfs` to IndexedDB. This requires a runtime
built with IDBFS and the `expose-runtime.js` pre-js (em-dosbox-packager
v0.2.0+); with an older runtime `init.js` logs a warning and no-ops, and
the client still runs (no persistence).

When shipping a new client image (a different `rs-<version>.data`), bump
`__PRODIGY_CLIENT_VERSION` in `init.js` to match. A version mismatch makes
the boot skip the overlay and start fresh from the new image, avoiding
stale/incompatible cache carried across the upgrade.
