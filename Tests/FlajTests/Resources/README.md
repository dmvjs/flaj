# TweenedTextGolden.gif

Golden fixture for `GIFExportTests.testTweenedTextExportMatchesGoldenByteForByte`.
Must byte-for-byte match the GIF produced by exporting the document built in
`DocumentFixtures.tweenedText()`.

## Regenerating

The export pipeline (`TimelineDocument.performGIFExport`) lives in the `Flaj`
executable target, not a library, so a plain script can't `import Flaj` to
call it — and on a machine without Xcode, `swift test` can't run the test
target at all to regenerate it from in there either. Instead, temporarily
wire the same document into the app itself and run it once via `swift run`:

1. Add a file `Sources/Flaj/_GoldenGenerator.swift` with a
   `@MainActor func generateGoldenFixturesIfRequested() -> Bool` that checks
   `CommandLine.arguments.contains("--generate-golden-fixtures")`, and if
   set, builds the exact same document as `DocumentFixtures.tweenedText()`
   and calls `doc.performGIFExport(to:)` with this file's path, then returns
   `true`.
2. Call it at the top of `AppDelegate.applicationDidFinishLaunching`,
   exiting immediately (`if generateGoldenFixturesIfRequested() { exit(0) }`)
   so it never opens a window.
3. Run `swift run Flaj --generate-golden-fixtures` from the repo root.
4. Delete `_GoldenGenerator.swift` and the call added in step 2.
5. Confirm `swift build` is still clean and `swift test` passes.

Only regenerate this when a change to the export pipeline, easing math, or
tween fixture is intentional — a diff here should always be explainable by a
specific source change, not silently re-recorded to make a test pass.

Note this file is only exactly reproducible on the machine/OS/font-rendering
stack it was recorded on (currently macOS 26, Helvetica) — text rendering
(anti-aliasing, hinting) isn't guaranteed byte-identical across OS versions.
If this test starts failing after an OS upgrade with the fixture's actual
frame content otherwise looking correct, that's most likely why: regenerate.
