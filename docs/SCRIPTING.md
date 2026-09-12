# Frame scripting

Any keyframe can carry a script, run once each time the playhead enters that
frame. Types for everything below are in [`flaj.d.ts`](flaj.d.ts).

## Execution model

Per frame: any tweens started with `stage.tween()` advance first, then every
layer's script for that frame runs, top to bottom. Scripts only attach to
keyframes — a plain in-between frame can't carry one.

A top-level `const`/`let` only takes effect the first time its line runs.
Loop back to a frame whose script declares `const x = ...` and that line is
skipped the second time through rather than throwing "already declared" —
`x` keeps whatever value it had. Anything that isn't a fresh top-level
declaration (reassignment, a `let` inside a function, `stage.tween(...)`
itself) runs every time as normal.

Pressing Play from a full stop clears all of this — stage objects, in-flight
tweens, and which `const`/`let` names have already run — so a restart
behaves like the movie has never played. `gotoAndPlay`/`goto` calls from
inside a running script don't: they're just navigation, same as a paused
menu frame sending you back to `play()`.

## Playback control

```js
stop();
play();
gotoAndStop(12);
gotoAndPlay(12);
goto(12);
```

`gotoAndStop`/`gotoAndPlay` clamp to the document's full frame range and run
the destination frame's script immediately. `goto` is the odd one out:
it repositions the playhead without touching play/stop state, and clamps to
the last frame that actually has content, not the document's nominal length
— handy for a menu that jumps around a short loop without ever falling off
the end into blank frames.

### Frame labels

Any keyframe can carry a name — set it in the Properties panel's "Frame
Label" field when a keyframe is selected on the Timeline (shown there as a
small red flag). All three navigation functions above accept a label
instead of a frame number:

```js
gotoAndPlay('start');
gotoAndStop('menu');
goto('loop');
```

A label is looked up by exact match across every layer, so one shared
"labels" or "actions" layer works the same as scattering them across
whichever layers happen to have the relevant keyframes. Calling with a
label that doesn't exist anywhere logs a console warning and leaves the
playhead where it was — it doesn't jump to frame 0 or throw.

A label starting with `#` doubles as a deep link in the exported web
page — the moment the playhead actually reaches that frame, the page's URL
fragment updates to match, becoming a real, back/forward-navigable browser
history entry. Opening the exported page with a URL that already ends in a
matching `#label` starts there instead of frame 1. Native-app-only
playback (no exported page to have a URL) ignores this — a `#`-prefixed
label works everywhere `gotoAndStop('#menu')` would, it just doesn't do
anything extra outside the browser.

## Stage

```js
stage.size(800, 450);
bg.color('#111827');
bg.color('cornflowerblue');   // any CSS color keyword
bg.color('transparent');
```

`stage.size` resizes the Stage itself (both dimensions clamp to a minimum
of 1px) — everything already placed keeps its own pixel coordinates, so
this is about changing the render surface's size, not repositioning or
rescaling its content to fit.

## Stage objects

Script-created objects are separate from anything placed with the Text tool
on the Timeline — they exist only at runtime, addressed by whatever `id` you
give them.

```js
stage.addText('title', 'Game Over', 40, 120);
stage.setText('title', 'Try Again');
stage.setTransform('title', { opacity: 0 });
stage.tween('title', { opacity: 1, y: 100 }, 20, 'easeOut');
```

`addText` is a no-op if `id` is already taken — ids are stable handles you
create once, not something you recreate every frame. `tween` animates
whichever of `x`, `y`, `scale`, `rotation`, `opacity`, `fontSize` you pass;
a second tween call on the same object+property replaces the one already in
flight rather than stacking. Easing is `'linear'` (default), `'easeIn'`,
`'easeOut'`, or `'easeInOut'`.

### Named symbol instances

A symbol instance placed on the Timeline (see "Symbols" in the README) can
carry an instance name, set in the Properties panel's "Name" field when the
instance is selected. The moment the playhead reaches that instance's
keyframe, it's addressable through the exact same `stage.setTransform`/
`stage.tween`/`stage.setText` calls above — same `id` namespace as a
script-created object, so `stage.addText('badge1', ...)` is a no-op if
`'badge1'` is already a spawned instance, same as colliding with any other
`addText`.

```js
// Symbol instance placed on the Timeline named "badge1":
stage.tween('badge1', { x: 300, rotation: 15 }, 20, 'easeOut');
```

Spawning is a one-time snapshot, not a live link back to the Library: once
an instance has spawned, further edits to its symbol or its Timeline
placement don't retroactively move it — it's an independent object from
then on, same as anything else `stage.addText` created.

If the symbol has more than one frame (see "Symbols" in the README — a
placed instance normally plays its symbol's frames independently and
continuously, looping on its own), spawning freezes it: the snapshot is
always taken from the symbol's frame 1, regardless of which frame the
instance's loop actually happened to be showing at the moment it spawned.
A spawned instance never keeps looping — like everything else about it,
its appearance is a one-time copy, not a live reflection of the symbol.

## Click-through (clickTag)

The banner-ad "clickTAG" convention — a plain property, not a method:

```js
stage.clickTag = 'https://example.com';
```

Once set, the whole Stage becomes one big link: click anywhere on it (over
placed text and stage objects too, not just empty background) and it opens
that URL in a new window/tab, cursor and all. Usually set once in frame 1's
script and left alone — it stays in effect for the rest of the movie, same
behavior in the native app's own preview and the exported page. The
exported page also makes it keyboard-reachable (Tab to it, Enter or Space
to activate) — the native app's own preview is mouse/trackpad-only.

## Console

```js
console.log('score:', score);
console.warn('low on lives');
console.error('missing enemy id', id);
trace('same as console.log');
```

Output lands in the Debug Console tagged with the frame it ran on.
