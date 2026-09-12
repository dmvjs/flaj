# Flaj

A Flash successor for people who'd rather write JS/TS than ActionScript. Stage, timeline, layers, keyframes, classic motion tweens, reusable symbols, vector shapes, rulers and guides — frame code that's just JavaScript.

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

⌘Z / ⇧⌘Z undo/redo · ⌘O open · ⌘S save · ⇧⌘S save as · ⌘Return preview (opens a window sized to the Stage's exact pixel dimensions, like Flash's Test Movie). Delete/⌘X/⌘C/⌘V work on the current Stage selection; arrow keys nudge it 1pt (10pt with Shift).

⌥⇧⌘R toggle rulers · ⌘; toggle guide visibility — both under the View menu (see "Rulers & guides" below).

Double-click a placed symbol instance to edit its Timeline in place; Escape backs out one level (see "Symbols" below).

## Export

File → Export GIF… simulates the whole timeline frame by frame and writes it out, tweens and all. File → Export Web Page… writes a standalone HTML/JS/CSS bundle with the same playback engine — including a looping symbol's independent playback, not just its first frame.

## Format

`.flaj` files are plain JSON — layers, frame marks, scripts, placed text, placed shapes, tween settings, frame labels, ruler guides, a Library of reusable symbols (each with its own nested layers/timeline, the same shape the document's own Timeline has). Older files missing newer fields still open, including files saved before a symbol's content was a Timeline at all.

## Shapes

The Rectangle/Ellipse tools (Tools panel, or the toolbar) draw a shape by click-dragging across the Stage — hold Shift to constrain to a square/circle — with a live preview as you drag, rather than Flash's click-to-place-then-resize. A drawn shape is its own independent, always-selectable object (not Flash's classic shape-merge drawing model): Properties panel gives it fill color+opacity, stroke color+opacity+width, and position/size, with a resize handle on every corner. Shapes aren't tweenable yet — they render the same way in the live Stage, GIF export, and web export.

## Rulers & guides

⌥⇧⌘R (View menu) toggles pixel-only rulers along the Stage's top/left edges, with tick spacing that adapts to the current fit-to-panel scale so labels never crowd together. Drag out from either ruler to drop a guide — a horizontal or vertical layout line that snaps to nothing yet but stays exactly where you put it, draggable afterward, and removed by dragging it back off the Stage. ⌘; (View menu) hides/shows guides without deleting them; guides themselves are saved with the document.

## Symbols

Select a placed text box and Convert to Symbol (Properties panel, or right-click it on the Stage/a frame) to turn it into a reusable Library entry — every instance you then place keeps its own position/size/scale/rotation/opacity and can still be tweened independently, while sharing the symbol's own content.

A symbol's content isn't just one frame of text/font/style — it's a real Timeline of its own (layers, keyframes, tweens, the same shape the document's own Timeline has). Double-click a placed instance on the Stage to edit that Timeline in place: the Stage and frame grid switch to the symbol's own content, with a breadcrumb ("Scene 1 ▸ SymbolName") to navigate back out, or press Escape. Editing a symbol's Timeline updates every instance of it at once.

Once a symbol has more than one frame, every placed instance plays that Timeline independently and continuously — Flash's actual Movie Clip behavior — looping its own frames on its own clock regardless of what the parent Timeline (or the instance's own position/scale/rotation tween) is doing. This holds across the live Stage, GIF export, and the web export alike.

Give an instance a name (Properties panel) and it becomes scriptable the moment its keyframe is reached — addressable through the same `stage.setTransform`/`stage.tween`/`stage.setText` a script-created object uses, no separate API. See "Named symbol instances" in [`docs/SCRIPTING.md`](docs/SCRIPTING.md).
