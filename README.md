# Flaj

A Flash successor for people who'd rather write JS/TS than ActionScript. Stage, timeline, layers, keyframes, classic motion tweens, reusable symbols, vector shapes, grouping, rulers and guides — frame code that's just JavaScript.

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

F5 insert frame · F6 keyframe · F7 blank keyframe · Shift-F5 remove frames · ⌥⌫ clear frame — same shortcuts as Flash, and the same behavior: F5/Shift-F5 shift every later keyframe (and its content/scripts/labels/tweens) on that layer forward or back, rather than leaving them where they were; Clear Frame is the separate, non-shifting "empty this frame in place" command. Right-click a frame for these plus Cut/Copy/Paste Frames, Select All Frames, and Reverse Frames (which correctly reverses a tween's direction too, not just its frame order).

A keyframe's Frame Label (Properties panel) has a Type, matching Flash's: Name (the default — addressable by `gotoAndPlay`/`gotoAndStop`), Comment (documentation only, excluded from label lookup and never a valid navigation target), and Anchor (also addressable, and updates the exported page's URL fragment when reached — picking it just toggles the leading "#" that behavior already keyed off of).

⌘Z / ⇧⌘Z undo/redo · ⌘O open · ⌘S save · ⇧⌘S save as · ⌘Return preview (opens a window sized to the Stage's exact pixel dimensions, like Flash's Test Movie). Delete/⌘X/⌘C/⌘V work on the current Stage selection; arrow keys nudge it 1pt (10pt with Shift). ⌘G group · ⇧⌘G ungroup (see "Multi-select & grouping" below).

⌥⇧⌘R toggle rulers · ⌘; toggle guide visibility — both under the View menu (see "Rulers & guides" below).

Double-click a placed symbol instance to edit its Timeline in place; Escape backs out one level (see "Symbols" below).

## Timeline

Matches Flash's own frame glyphs: a filled dot marks a keyframe with content, a hollow dot a blank keyframe, a small italic *a* above a keyframe's dot means it carries a script, and a hollow rectangle with a trailing tick closes out a plain extended span. A tween's span is tinted and colored by what it's tweening — blue for text/symbol/group ("motion"), green for a shape — with an arrow drawn the length of the span, and a thin rule separates each layer's row from the next. A frame label shows a red flag (Name), a blue anchor (Anchor), or a dimmed comment bubble (Comment) depending on its Type.

## Export

File → Export GIF… simulates the whole timeline frame by frame and writes it out, tweens and all. File → Export Web Page… writes a standalone HTML/JS/CSS bundle with the same playback engine — including a looping symbol's independent playback, not just its first frame.

## Format

`.flaj` files are plain JSON — layers (including mask/masked state), frame marks, scripts, placed text, placed shapes, placed groups, tween settings, frame labels, ruler guides, a Library of reusable symbols (each with its own nested layers/timeline, the same shape the document's own Timeline has). Older files missing newer fields still open, including files saved before a symbol's content was a Timeline at all.

## Shapes

The Rectangle/Ellipse tools (Tools panel, or the toolbar) draw a shape by click-dragging across the Stage — hold Shift to constrain to a square/circle — with a live preview as you drag, rather than Flash's click-to-place-then-resize. A drawn shape is its own independent, always-selectable object (not Flash's classic shape-merge drawing model): Properties panel gives it fill color+opacity, stroke color+opacity+width, stroke style (solid/dashed/dotted), a corner radius for rectangles, and position/size, with a resize handle on every corner. Shapes are tweenable exactly like text/symbols (Insert → Create Tween) — position/size/stroke width/corner radius ease on one curve, fill/stroke color and every opacity ease independently on their own, while stroke style holds at the start keyframe's value across the span — across the live Stage, GIF export, and web export alike.

## Multi-select & grouping

Shift-click or Cmd-click adds another Stage object to the current selection; dragging any one selected object moves all of them together. Right-click (or ⌘G) on a multi-selection of 2+ objects → Group bundles them into a Group — a lightweight, non-reusable container distinct from a Symbol (a Group has no Library entry and no independent Timeline of its own; a Symbol does). A Group moves and resizes as one unit — resizing proportionally rescales every bundled child. Right-click a Group → Ungroup (or ⇧⌘G) dissolves it back into independent objects at their original positions; there's no double-click-to-edit-one-member mode yet, so editing a single member means Ungroup, edit, then re-group. Groups can bundle text, shapes, and symbol instances (a nested symbol keeps looping independently); they aren't tweenable yet. Web export renders every bundled child; a nested symbol's own loop is captured once at export-render time rather than kept continuously current the way it is natively.

## Masking

Right-click a layer → Mask turns it into a mask layer (never itself drawn on Stage, only used as a clip stencil); right-click the layer(s) directly below it → Masked clips them to whatever the mask layer's own content covers at each frame. Any content kind — text, a shape, or a symbol instance — can be the mask source on the live Stage and in GIF export; web export currently only supports a shape (rectangle/ellipse) as the mask source, via CSS `clip-path` — a text- or symbol-sourced mask still renders correctly in the app and in exported GIFs, just unclipped in the exported web page for now. A mask can't itself be masked, and a masked layer can't itself become a mask.

## Rulers & guides

⌥⇧⌘R (View menu) toggles pixel-only rulers along the Stage's top/left edges, with tick spacing that adapts to the current fit-to-panel scale so labels never crowd together. Drag out from either ruler to drop a guide — a horizontal or vertical layout line that snaps to nothing yet but stays exactly where you put it, draggable afterward, and removed by dragging it back off the Stage. ⌘; (View menu) hides/shows guides without deleting them; guides themselves are saved with the document.

## Onion skinning

The square-stack icon in the Timeline toggles onion skinning — ghosted, flat-tinted (blue before the playhead, orange after) previews of nearby frames' content layered behind the current frame, with a ±1–5 frame range adjuster next to the toggle. Covers every content kind (placed text, symbol instances, and shapes) and every tween in progress. Editor-only: it never appears in GIF or web export output.

## Color pickers

Every color swatch in the app (Stage color, fill/stroke, text color, filter colors, web export page background) opens a small popover anchored right next to the swatch, not the system's separate floating color panel — click, pick, done, without a window appearing somewhere else on screen. Opacity is always its own slider alongside the swatch rather than folded into the color itself.

## Symbols

Select a placed text box and Convert to Symbol (Properties panel, or right-click it on the Stage/a frame) to turn it into a reusable Library entry — every instance you then place keeps its own position/size/scale/rotation/opacity and can still be tweened independently, while sharing the symbol's own content.

A symbol's content isn't just one frame of text/font/style — it's a real Timeline of its own (layers, keyframes, tweens, the same shape the document's own Timeline has). Double-click a placed instance on the Stage to edit that Timeline in place: the Stage and frame grid switch to the symbol's own content, with a breadcrumb ("Scene 1 ▸ SymbolName") to navigate back out, or press Escape. Editing a symbol's Timeline updates every instance of it at once.

Once a symbol has more than one frame, every placed instance plays that Timeline independently and continuously — Flash's actual Movie Clip behavior — looping its own frames on its own clock regardless of what the parent Timeline (or the instance's own position/scale/rotation tween) is doing. This holds across the live Stage, GIF export, and the web export alike.

Give an instance a name (Properties panel) and it becomes scriptable the moment its keyframe is reached — addressable through the same `stage.setTransform`/`stage.tween`/`stage.setText` a script-created object uses, no separate API. See "Named symbol instances" in [`docs/SCRIPTING.md`](docs/SCRIPTING.md).
