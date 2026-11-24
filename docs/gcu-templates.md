# GCU text templates

Use a preserved Graphics Creation Utility recipe to create new content in an
existing Prodigy layout. The tool lists text runs and fills several in one pass.
It operates on files; it does not connect to a database, import content or run a
compiler.

## List and fill

From the umbrella source directory:

    mix prodigy.gcu list INPUT.RCP
    mix prodigy.gcu fill INPUT.RCP --output CUSTOM.RCP \
      --set 'Title:1=Welcome to Prodigy' \
      --set 'Body:1=Our lab is ready.'

The existing podbutil escript supports the same commands:

    podbutil gcu list INPUT.RCP
    podbutil gcu fill INPUT.RCP --output CUSTOM.RCP --set 'Title:1=New title'

Use the exact selectors printed by list; Title and Body above are examples.
A selector consists of a case-sensitive list name and a one-based text-run
number, separated by a colon. One named list may contain many independently
positioned strings. Every selector is resolved against the original input, so
shortening or clearing one run does not shift another replacement in that
invocation. An equals sign in replacement text is literal. Empty text is allowed;
after removing a run, a subsequent list invocation will number the remaining runs
again.

Output must be a new file. Unknown or repeated selectors, unsupported text,
invalid records, repeated output arguments and length overflows fail before any
output file is created. Existing files, including the input, are never overwritten.
The command returns exit status 2 for errors.

## Compile and view a copy

With an independently obtained compatible COOK.EXE, copy the edited recipe into a
disposable DOS working folder and run:

    COOK /KF CUSTOM.RCP

The compiler chooses its output object filename from the recipe header, which
may differ from CUSTOM.RCP. Keep the original recipe and previously compiled
object outside this folder. The tool does not change recipe identity, object ID,
partition, fields or navigation bindings.

Verify the resulting page in a suitable viewer or isolated Reception System lab
before importing it into a running service. Generating an object does not make it
a navigable page: a page format/template and any keyword mapping must reference
the element. This tool does not deploy or alter those bindings.

## Supported format and limits

The reader supports the observed GCULIST format whose prologue is the eight
bytes GCULIST plus NUL, followed by 50 02 00 01 and a little-endian 16-bit header
length. Header and list records have variable little-endian 16-bit payload
lengths. The list block length excludes its four-byte marker/length prefix.
The reader validates boundaries, ordered names and the declared list count.

Only printable ASCII text runs in stencil NAPLPS records (tag 07 02) are replaced.
The supported 8-bit stream uses printable GL bytes for text and GR bytes for
drawing instructions and operands. Editing a selected stencil containing other
encoding shifts, escape sequences or unsupported control bytes is rejected.
CR, LF and SI are preserved. Replacement text cannot contain line breaks,
controls or non-ASCII characters. There is no font fitting or automatic wrapping;
choose text that fits the existing layout.

Other record payloads, record order, graphics, cursor/position controls and the
original NAPLPS record (tag 0B 02) are retained byte for byte. Modified record and
enclosing list lengths are recalculated with explicit 16-bit overflow checks.
Input and output are limited to 16 MiB. Unknown records are retained, while
unknown prologue versions are rejected.

Tests construct small synthetic recipes; historical recipes and proprietary
compiler/client binaries are not distributed with this source.

Background: https://github.com/ProdigyReloaded/delivery-system/issues/53
