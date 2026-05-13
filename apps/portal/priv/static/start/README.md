# DOSBox client bundle

This directory is where the portal's `/start` page loads the in-browser
Prodigy client from. The bundle itself is **not committed** - it's
produced by a separate project that builds em-dosbox under emscripten
and packages the Prodigy RS virtual filesystem alongside it.

## Expected files

When populated, this directory should contain:

- `dosbox.js` - emscripten loader (compiled)
- `dosbox.wasm` - emscripten WASM binary
- `loader.js` - generated virtual-filesystem data loader
- `rs-6.03.17.data` - packed Prodigy RS client image
- `init.js` - hand-written glue that wires DOSBox's `Module` to the
  page's `#status` / `#progress` / `#canvas` elements

## How to populate

Until the build pipeline is integrated, operators drop a pre-built
bundle in by hand. The source project lives at:

  <TODO: publish the dosbox build project + releases URL>

and the portal's Docker build will eventually `curl` a pinned release
tarball into this directory. For local dev, copy the five files above
into this directory from wherever you built them; they're listed in
`.gitignore` so they won't be tracked.
