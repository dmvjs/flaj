# Flaj

A Flash successor for people who'd rather write JS/TS than ActionScript. Stage, timeline, layers, keyframes, classic motion tweens, reusable symbols — frame code that's just JavaScript.

## Running

```
swift run
```

macOS 14+, Swift 5.9 toolchain. Building and running the app doesn't need Xcode — Command Line Tools are enough.

## Testing

```
swift test
```

This does need a full Xcode install; XCTest doesn't link against Command Line Tools alone on macOS.

## Frame scripting

Any keyframe can carry JS, evaluated when the playhead enters it:

```js
stop();
bg.color('#111');
stage.tween('title', { x: 200, opacity: 1 }, 20, 'easeOut');
```

Full reference and execution model: [`docs/SCRIPTING.md`](docs/SCRIPTING.md). Types for editor autocomplete: [`docs/flaj.d.ts`](docs/flaj.d.ts).

## Shortcuts

F5 insert frame · F6 keyframe · F7 blank keyframe · Shift-F5 remove frames — same as Flash.

⌘Z / ⇧⌘Z undo/redo · ⌘O open · ⌘S save · ⇧⌘S save as · ⌘Return preview (opens a window sized to the Stage's exact pixel dimensions, like Flash's Test Movie). Delete/⌘X/⌘C/⌘V work on the current Stage selection.

## Export

File → Export GIF… simulates the whole timeline frame by frame and writes it out, tweens and all. File → Export Web Page… writes a standalone HTML/JS/CSS bundle with the same playback engine.

## Format

`.flaj` files are plain JSON — layers, frame marks, scripts, placed text, tween settings, frame labels, a Library of reusable symbols. Older files missing newer fields still open.

## Symbols

Select a placed text box and Convert to Symbol (Properties panel, or right-click it on the Stage/a frame) to turn it into a reusable Library entry — every instance you then place shares that text/font/style, but keeps its own position/size/scale/rotation/opacity and can still be tweened independently. Editing a symbol's content updates every instance at once.

Give an instance a name (Properties panel) and it becomes scriptable the moment its keyframe is reached — addressable through the same `stage.setTransform`/`stage.tween`/`stage.setText` a script-created object uses, no separate API. See "Named symbol instances" in [`docs/SCRIPTING.md`](docs/SCRIPTING.md).
