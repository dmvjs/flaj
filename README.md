# Flaj

A Flash successor for people who'd rather write JS/TS than ActionScript. Stage, timeline, layers, keyframes, classic motion tweens — frame code that's just JavaScript.

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

## Export

File → Export GIF… simulates the whole timeline frame by frame and writes it out, tweens and all.

## Format

`.flaj` files are plain JSON — layers, frame marks, scripts, placed text, tween settings. Older files missing newer fields still open.
