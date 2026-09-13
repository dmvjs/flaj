// Flaj web player — reimplements the playback/tween/frame-script runtime
// from TimelineModel.swift and the rendering rules from StageView.swift, so
// an exported page behaves like the movie actually running, not a recording
// of one run through it. Ported by hand rather than shared source with the
// Swift app, so a behavioral change on one side needs the same change made
// here (see docs/SCRIPTING.md).
//
// Declarative placed-text tweens run as real Web Animations
// (element.animate), not per-tick JS-recomputed positions — once a span's
// Animation is created it plays on the browser's own compositor-driven
// clock, untouched by this file, until the playhead crosses into a
// different span. That's the source of both the smoothness (real interp at
// display refresh rate, not the movie's fps) and the efficiency (no JS work
// at all for a tween in progress). A `requestAnimationFrame` loop still
// runs, but only to detect *integer* frame-boundary crossings — for running
// frame scripts and swapping in the next span — never to drive motion.
(function () {
  'use strict';

  const doc = JSON.parse(document.getElementById('flaj-document').textContent);
  const frameEl = document.getElementById('flaj-frame');
  const stageEl = document.getElementById('flaj-stage');
  const textLayerEl = document.getElementById('flaj-text-layer');
  const objectsLayerEl = document.getElementById('flaj-objects-layer');
  const shapesLayerEl = document.getElementById('flaj-shapes-layer');
  const groupsLayerEl = document.getElementById('flaj-groups-layer');

  let stageWidth = doc.stageWidth;
  let stageHeight = doc.stageHeight;
  let stageColor = doc.stageColorHex;
  let fps = doc.fps;
  const totalFrames = doc.totalFrames;

  let playhead = 1;
  let isPlaying = false;
  let rafHandle = null;
  let frameOriginTime = null; // performance.now() timestamp `playhead` was last exactly entered
  const stageObjects = new Map(); // id -> {text,x,y,fontSize,color,scale,rotation,opacity}
  let activeTweens = [];
  const declaredTopLevelBindings = new Set();

  // ---- frame-mark helpers (mirrors TLLayer in TimelineModel.swift) ----

  function isKeyframe(frames, frame) {
    const mark = frames[frame - 1];
    return !!mark && (mark.type === 'keyframe' || mark.type === 'emptyKeyframe');
  }

  function governingKeyframe(frames, frame) {
    let i = frame - 1;
    while (i >= 0 && i < frames.length) {
      const type = frames[i].type;
      if (type === 'keyframe' || type === 'emptyKeyframe') return i + 1;
      if (type === 'plain' || type === 'tween') { i -= 1; continue; }
      return null;
    }
    return null;
  }

  function tweenTarget(frames, startKeyframe) {
    let i = startKeyframe; // 0-based index of the frame right after startKeyframe
    if (i < 0 || i >= frames.length || frames[i].type !== 'tween') return null;
    while (i < frames.length) {
      const type = frames[i].type;
      if (type === 'tween') { i += 1; continue; }
      if (type === 'keyframe' || type === 'emptyKeyframe') return i + 1;
      return null;
    }
    return null;
  }

  // ---- masking (mirrors TimelineDocument.maskingLayer(for:) in TimelineModel.swift) ----
  // `LayerKind`'s synthesized Codable encodes a plain case as a one-key
  // object (e.g. `{"mask": {}}`), never a bare string — layerKind() reads
  // that key back out.

  function layerKind(layer) {
    return layer.kind ? Object.keys(layer.kind)[0] : 'normal';
  }

  /// The mask layer currently clipping `doc.layers[layerIndex]`, walking
  /// layers in their real Timeline order exactly like the Swift original
  /// — `null` for a mask layer itself, for `masked: false`, or once a
  /// non-masked layer has broken the run back to the nearest mask above.
  function maskingLayerFor(layerIndex) {
    let activeMask = null;
    for (let i = 0; i < doc.layers.length; i++) {
      const l = doc.layers[i];
      if (layerKind(l) === 'mask') {
        activeMask = l;
      } else if (!l.masked) {
        activeMask = null;
      }
      if (i === layerIndex) return layerKind(l) === 'mask' ? null : activeMask;
    }
    return null;
  }

  // Web export v1 only supports a shape-sourced mask (rectangle/ellipse) —
  // a text- or symbol-sourced mask is a native-Stage/GIF-export-only
  // capability for now (see PropertiesPanelView/StageView's own doc
  // comments on "most basic first" scoping elsewhere in this codebase).
  // Returns null (mask skipped, content renders unclipped) when the mask
  // layer's *current* governing keyframe isn't a shape.
  function maskShapeGeometryAtFrame(maskLayer, frame) {
    const kf = governingKeyframe(maskLayer.frames, Math.floor(frame));
    const base = kf != null && maskLayer.shapeFrames && maskLayer.shapeFrames[kf];
    if (!base) return null;
    const endKf = tweenTarget(maskLayer.frames, kf);
    const end = endKf != null ? maskLayer.shapeFrames[endKf] : null;
    if (!end || endKf <= kf) return base;
    const rawT = (frame - kf) / (endKf - kf);
    const t = easedProgress(maskLayer.tweenSettings[kf], rawT);
    return {
      kind: base.kind,
      x: base.x + (end.x - base.x) * t,
      y: base.y + (end.y - base.y) * t,
      width: base.width + (end.width - base.width) * t,
      height: base.height + (end.height - base.height) * t,
      cornerRadius: base.cornerRadius + ((end.cornerRadius || 0) - (base.cornerRadius || 0)) * t
    };
  }

  function clipPathFor(shape) {
    if (shape.kind === 'ellipse') {
      return `ellipse(${shape.width / 2}px ${shape.height / 2}px at ${shape.x + shape.width / 2}px ${shape.y + shape.height / 2}px)`;
    }
    const inset = `inset(${shape.y}px ${stageWidth - (shape.x + shape.width)}px ${stageHeight - (shape.y + shape.height)}px ${shape.x}px`;
    return shape.cornerRadius ? `${inset} round ${shape.cornerRadius}px)` : `${inset})`;
  }

  // A masked layer's element lives inside a full-Stage-sized wrapper
  // (`inset: 0`, same coordinate frame as the Stage itself) rather than
  // directly in its usual layer container — that's what lets `clipPathFor`
  // express the mask's geometry in plain Stage-pixel coordinates instead
  // of needing to translate into the masked element's own, independently
  // positioned/tweened local box. Recomputed every tick in syncMaskWraps
  // (below) rather than as a Web Animation of its own: the mask's geometry
  // and the masked content's geometry can tween independently and on
  // different spans, and a masked layer's *default* container can itself
  // change (text vs. shape), both easier to keep correct with a plain
  // per-tick recompute than by trying to model it as WAAPI keyframes.
  const layerMaskWraps = new Map(); // layerIndex -> wrapper div

  function maskAwareParent(layerIndex, defaultParent) {
    const mask = maskingLayerFor(layerIndex);
    if (!mask) {
      const existing = layerMaskWraps.get(layerIndex);
      if (existing) { existing.remove(); layerMaskWraps.delete(layerIndex); }
      return defaultParent;
    }
    let wrap = layerMaskWraps.get(layerIndex);
    if (!wrap) {
      wrap = document.createElement('div');
      wrap.className = 'flaj-mask-wrap';
      layerMaskWraps.set(layerIndex, wrap);
    }
    if (wrap.parentElement !== defaultParent) defaultParent.appendChild(wrap);
    return wrap;
  }

  function syncMaskWraps(frame) {
    for (let i = 0; i < doc.layers.length; i++) {
      const mask = maskingLayerFor(i);
      const wrap = layerMaskWraps.get(i);
      if (!wrap) continue; // nothing currently rendered under this layer needs clipping
      const shape = mask ? maskShapeGeometryAtFrame(mask, frame) : null;
      wrap.style.clipPath = shape ? clipPathFor(shape) : 'none';
    }
  }

  function contentLength() {
    let last = 1;
    for (const layer of doc.layers) {
      layer.frames.forEach((mark, i) => { if (mark.type !== 'empty') last = Math.max(last, i + 1); });
    }
    return last;
  }

  // ---- easing (mirrors TweenSettings/EaseFamily in StageObject.swift) ----

  function bounceOut(t) {
    const n1 = 7.5625, d1 = 2.75;
    if (t < 1 / d1) return n1 * t * t;
    if (t < 2 / d1) { t -= 1.5 / d1; return n1 * t * t + 0.75; }
    if (t < 2.5 / d1) { t -= 2.25 / d1; return n1 * t * t + 0.9375; }
    t -= 2.625 / d1;
    return n1 * t * t + 0.984375;
  }

  function easeInFamily(family, t) {
    switch (family) {
      case 'sine': return 1 - Math.cos(t * Math.PI / 2);
      case 'quad': return t * t;
      case 'cubic': return t * t * t;
      case 'back': { const c1 = 1.70158, c3 = c1 + 1; return c3 * t * t * t - c1 * t * t; }
      case 'elastic': {
        if (t <= 0 || t >= 1) return t;
        const c4 = (2 * Math.PI) / 3;
        return -Math.pow(2, 10 * t - 10) * Math.sin((t * 10 - 10.75) * c4);
      }
      case 'bounce': return 1 - bounceOut(1 - t);
      default: return t; // linear
    }
  }

  function easedProgress(settings, t) {
    const clamped = Math.min(Math.max(t, 0), 1);
    if (!settings || settings.family === 'linear') return clamped;
    let curved;
    if (settings.direction === 'easeIn') {
      curved = easeInFamily(settings.family, clamped);
    } else if (settings.direction === 'easeOut') {
      curved = 1 - easeInFamily(settings.family, 1 - clamped);
    } else {
      curved = clamped < 0.5
        ? easeInFamily(settings.family, clamped * 2) / 2
        : 1 - easeInFamily(settings.family, (1 - clamped) * 2) / 2;
    }
    const blend = Math.min(Math.max(settings.amount ?? 100, 0), 100) / 100;
    return clamped + (curved - clamped) * blend;
  }

  function spinDegrees(settings, t) {
    if (!settings || !settings.rotate || settings.rotate === 'none') return 0;
    const direction = settings.rotate === 'cw' ? 1 : -1;
    return direction * 360 * (settings.rotateTimes || 0) * easedProgress(settings, t);
  }

  const SIMPLE_EASING = {
    linear: t => t,
    easeIn: t => t * t,
    easeOut: t => 1 - (1 - t) * (1 - t),
    easeInOut: t => (t < 0.5 ? 2 * t * t : 1 - Math.pow(-2 * t + 2, 2) / 2)
  };

  // CSS's linear() easing function takes evenly-spaced output samples and
  // interpolates between them — the one native timing function expressive
  // enough to reproduce a non-monotonic curve like bounce/elastic exactly
  // (cubic-bezier() can't). Sampling a plain 0...1 function this way is how
  // *any* of these curves becomes a real, GPU/compositor-friendly CSS
  // easing instead of JS recomputing a position every tick.
  function cssLinearEasing(sample) {
    const steps = 40;
    const values = [];
    for (let i = 0; i <= steps; i++) values.push(sample(i / steps).toFixed(4));
    return `linear(${values.join(', ')})`;
  }

  function cssEasingForTween(settings) {
    if (!settings || settings.family === 'linear') return 'linear';
    return cssLinearEasing(t => easedProgress(settings, t));
  }

  function cssEasingForSimple(name) {
    const fn = SIMPLE_EASING[name] || SIMPLE_EASING.linear;
    return name === 'linear' ? 'linear' : cssLinearEasing(fn);
  }

  // ---- placed text: real Web Animations per tween span ----
  // (mirrors TLLayer.interpolatedPlacedText, but the interpolation itself
  // happens natively — this only computes the two keyframes' endpoints.)

  const layerVisuals = new Map(); // layerIndex -> { kf, element, animations: Animation[] }

  function textAlignStyle(alignment) {
    switch (alignment) {
      case 'center': return { textAlign: 'center', justifyContent: 'center' };
      case 'trailing': return { textAlign: 'right', justifyContent: 'flex-end' };
      default: return { textAlign: 'left', justifyContent: 'flex-start' };
    }
  }

  // Properties that don't interpolate over a span at all, tweened or not —
  // fixed at the start keyframe's value for the span's whole duration,
  // exactly like TLLayer.interpolatedPlacedText only carries forward
  // x/y/width/height/fontSize (from `tweenSettings`) and colorHex/opacity
  // (from `colorTweenSettings`), spreading everything else from `base`.
  function applyStaticTextStyle(el, base) {
    el.textContent = base.text;
    el.style.fontFamily = base.fontName + ', sans-serif';
    el.style.fontWeight = base.bold ? 'bold' : 'normal';
    el.style.fontStyle = base.italic ? 'italic' : 'normal';
    el.style.textShadow = textShadowCSS(base);
    const align = textAlignStyle(base.alignment);
    el.style.textAlign = align.textAlign;
    el.style.justifyContent = align.justifyContent;
  }

  // ---- symbol instances (mirrors TLLayer.interpolatedSymbolInstance) ----
  // A Library symbol (doc.library) holds the shared text/font/style
  // content; a placed instance (layer.symbolFrames[kf]) holds only its own
  // geometry. This normalizes either kind of keyframe content — plain
  // placed text, or a resolved symbol instance — into one PlacedText-
  // shaped object, so every function below it (applyStaticTextStyle,
  // boxKeyframe, colorKeyframe, createLayerVisual) can stay agnostic to
  // which kind actually governs a given span.

  function findSymbol(symbolID) {
    return (doc.library || []).find(s => s.id === symbolID) || null;
  }

  // A symbol's shared content is a real Timeline — `symbol.layers[0]` —
  // the same nested shape FlajSymbol carries natively (see StageObject.swift).
  // A placed instance plays it independently of the parent, looping its
  // own frames continuously (Flash's actual Movie Clip behavior) — see
  // symbolLocalFrame/applySymbolLoopFrame below for the per-tick side of
  // this; `symbolContent` itself only ever resolves frame 1, used for a
  // span's initial box/color Web Animation endpoints (see createLayerVisual),
  // which are about the *instance's own* geometry/opacity tween, not which
  // frame of the symbol is showing — that's applied separately, every
  // tick, so it can keep advancing independently of whether the instance
  // itself is mid-tween or sitting still.
  function symbolContent(symbol) {
    const layer = symbol.layers && symbol.layers[0];
    return (layer && layer.textFrames && layer.textFrames[1]) || null;
  }

  // Mirrors FlajSymbol.localFrame in StageObject.swift exactly — see its
  // doc comment for why this counts from the instance's own governing
  // keyframe rather than wall-clock time or absolute frame 0.
  function symbolLocalFrame(symbol, parentFrame, governingKeyframe) {
    const span = Math.max(symbol.totalFrames || 1, 1);
    const elapsed = parentFrame - governingKeyframe;
    return (((elapsed % span) + span) % span) + 1;
  }

  // Same channel-wise sRGB lerp as TimelineDocument.interpolateHex in
  // TimelineModel.swift, so a color tween authored inside a symbol's own
  // Timeline eases through the same intermediate colors here as it would
  // natively, not just jump at the midpoint.
  // "#rrggbb" -> [r, g, b], 0...255 each. Shared by lerpHexColor (easing
  // between two colors) and textShadowCSS (turning a filter's colorHex +
  // opacity into one rgba() CSS color) below — the one place either needs
  // to actually read hex digits apart.
  function hexComponents(hex) {
    let s = (hex || '#000000').trim();
    if (s.charAt(0) === '#') s = s.slice(1);
    const v = parseInt(s, 16);
    const n = Number.isNaN(v) ? 0 : v;
    return [(n >> 16) & 0xFF, (n >> 8) & 0xFF, n & 0xFF];
  }

  function lerpHexColor(fromHex, toHex, t) {
    const from = hexComponents(fromHex), to = hexComponents(toHex);
    const lerp = (a, b) => Math.round(a + (b - a) * t);
    const byte = (n) => n.toString(16).padStart(2, '0').toUpperCase();
    return '#' + byte(lerp(from[0], to[0])) + byte(lerp(from[1], to[1])) + byte(lerp(from[2], to[2]));
  }

  // Mirrors PropertiesPanelView/StageView's own Drop Shadow + Glow
  // rendering (see StageView's placedTextFilters) as CSS text-shadow —
  // glow is offset (0, 0), drop shadow carries its own offsetX/offsetY;
  // both can be present at once, same as the two stacked SwiftUI shadows
  // natively. Returns 'none' (a valid, explicit "no shadow" text-shadow
  // value) when neither filter is set, rather than an empty string, so a
  // span that starts with a shadow and moves to a keyframe without one
  // actually clears it instead of leaving the old value in place.
  function textShadowCSS(content) {
    const layers = [];
    if (content.glow) {
      const [r, g, b] = hexComponents(content.glow.colorHex);
      layers.push(`0px 0px ${content.glow.blur}px rgba(${r}, ${g}, ${b}, ${content.glow.opacity})`);
    }
    if (content.dropShadow) {
      const [r, g, b] = hexComponents(content.dropShadow.colorHex);
      layers.push(`${content.dropShadow.offsetX}px ${content.dropShadow.offsetY}px ${content.dropShadow.blur}px rgba(${r}, ${g}, ${b}, ${content.dropShadow.opacity})`);
    }
    return layers.length > 0 ? layers.join(', ') : 'none';
  }

  // Mirrors TLLayer.interpolatedPlacedText in TimelineModel.swift, scoped
  // to a symbol's own layer — real tween support (fontSize/scale/rotation
  // eased linearly against the curve's own progress, opacity/color against
  // colorTweenSettings' own, independently) for a symbol's internal
  // Timeline, not a discrete jump between keyframes.
  function interpolatedSymbolContent(layer, frame) {
    const kf = governingKeyframe(layer.frames, frame);
    const base = kf != null ? layer.textFrames[kf] : null;
    if (!base) return null;
    const endKf = tweenTarget(layer.frames, kf);
    const end = endKf != null ? layer.textFrames[endKf] : null;
    if (!end || endKf <= kf) return base;
    const rawT = (frame - kf) / (endKf - kf);
    const t = easedProgress(layer.tweenSettings[kf], rawT);
    const colorT = easedProgress(layer.colorTweenSettings[kf], rawT);
    return {
      text: base.text, fontName: base.fontName, bold: base.bold, italic: base.italic, alignment: base.alignment,
      dropShadow: base.dropShadow, glow: base.glow,
      fontSize: base.fontSize + (end.fontSize - base.fontSize) * t,
      scale: (base.scale ?? 1) + ((end.scale ?? 1) - (base.scale ?? 1)) * t,
      rotation: (base.rotation ?? 0) + ((end.rotation ?? 0) - (base.rotation ?? 0)) * t,
      opacity: base.opacity + (end.opacity - base.opacity) * colorT,
      colorHex: lerpHexColor(base.colorHex, end.colorHex, colorT)
    };
  }

  function resolvePlacement(layer, kf) {
    if (layer.textFrames[kf]) return layer.textFrames[kf];
    const instance = layer.symbolFrames && layer.symbolFrames[kf];
    if (!instance) return null;
    const symbol = findSymbol(instance.symbolID);
    const content = symbol && symbolContent(symbol);
    if (!content) return null; // orphaned/empty reference — render nothing rather than throw
    return {
      text: content.text, fontName: content.fontName, fontSize: content.fontSize,
      bold: content.bold, italic: content.italic, colorHex: content.colorHex, alignment: content.alignment,
      dropShadow: content.dropShadow, glow: content.glow,
      x: instance.x, y: instance.y, width: instance.width, height: instance.height,
      // Compounded with the symbol's own (frame-1) values, not just the
      // instance's — same reasoning as StageSymbolInstanceView natively:
      // both are real, independent tweenable quantities that must combine,
      // not one silently overriding the other. This only ever reflects
      // frame 1 (used for this span's Web Animation endpoints, built once
      // at span creation) — the live per-tick value as the symbol loops is
      // applySymbolLoopFrame's job below.
      opacity: instance.opacity * (content.opacity ?? 1),
      scale: instance.scale * (content.scale ?? 1),
      rotation: instance.rotation + (content.rotation ?? 0)
    };
  }

  function boxKeyframe(placement, spinDeg) {
    const scale = placement.scale ?? 1;
    const rotation = (placement.rotation ?? 0) + spinDeg;
    return {
      left: placement.x + 'px', top: placement.y + 'px',
      width: placement.width + 'px', height: placement.height + 'px',
      fontSize: placement.fontSize + 'px',
      transform: `scale(${scale}) rotate(${rotation}deg)`
    };
  }

  function colorKeyframe(placement) {
    return { color: placement.colorHex, opacity: String(placement.opacity) };
  }

  /// Every checkpoint inside [kf, endKf] on a text/symbol-instance layer —
  /// the span's own start/end plus any property keyframes (Flash's diamond
  /// marker; see TLLayer.isPropertyKeyframe on the Swift side, which this
  /// mirrors exactly: any textFrames/symbolFrames entry inside the span
  /// counts, no separate "type" field needed). Always resolved through
  /// resolvePlacement so a symbol instance's compounded content, not just
  /// its own instance fields, is what gets checkpointed.
  function tweenCheckpoints(layer, kf, endKf) {
    const dict = layer.textFrames[kf] ? layer.textFrames : layer.symbolFrames;
    return Object.keys(dict).map(Number).filter(f => f >= kf && f <= endKf).sort((a, b) => a - b)
      .map(frame => ({ frame, placement: resolvePlacement(layer, frame) }));
  }

  /// Turns a list of {frame, placement} checkpoints into a WAAPI keyframe
  /// array, plus the `easing` to pass in `animate()`'s own options object.
  ///
  /// Exactly two checkpoints (the common case: no property keyframes)
  /// returns that pair verbatim plus an animation-level easing — unchanged
  /// from before property keyframes existed.
  ///
  /// Three or more (a real property keyframe present) resamples the whole
  /// piecewise-eased curve into `steps` evenly-spaced value keyframes with
  /// a flat top-level 'linear' timing between them, mirroring
  /// TLLayer.checkpointBracket's bracket-and-locally-ease logic on the
  /// Swift side. This is the same technique
  /// resampleCombinedSymbolLoopKeyframes already uses to bake an arbitrary
  /// curve into something every engine plays back correctly — needed here
  /// because a per-keyframe `easing` using the baked `linear(...)` timing
  /// function (as opposed to a keyword easing) was verified NOT to apply
  /// correctly in a real WKWebView: it silently fell back to plain linear
  /// interpolation instead of the intended curve.
  ///
  /// `numericFields` lists which of `keyframeBuilder`'s placement fields to
  /// linearly interpolate per sample; `hexFields` lists which to interpolate
  /// as colors instead (via lerpHexColor) — every other field just comes
  /// along from the bracketing low checkpoint unchanged, same as `result = base`
  /// in the Swift interpolation functions this mirrors.
  function checkpointedKeyframes(checkpoints, kf, endKf, settings, keyframeBuilder, numericFields, hexFields) {
    if (checkpoints.length <= 2) {
      const frames = checkpoints.map(cp => {
        const offset = endKf > kf ? (cp.frame - kf) / (endKf - kf) : 0;
        const obj = keyframeBuilder(cp.placement, offset);
        obj.offset = offset;
        return obj;
      });
      return { frames, easing: cssEasingForTween(settings) };
    }
    const steps = 40;
    const frames = [];
    for (let i = 0; i <= steps; i++) {
      const sampleOffset = i / steps;
      const sampleFrame = kf + sampleOffset * (endKf - kf);
      let lo = checkpoints[0], hi = checkpoints[checkpoints.length - 1];
      for (let j = 0; j < checkpoints.length - 1; j++) {
        if (sampleFrame >= checkpoints[j].frame && sampleFrame <= checkpoints[j + 1].frame) {
          lo = checkpoints[j]; hi = checkpoints[j + 1];
          break;
        }
      }
      const localT = hi.frame > lo.frame ? (sampleFrame - lo.frame) / (hi.frame - lo.frame) : 0;
      const t = easedProgress(settings, localT);
      const placement = { ...lo.placement };
      for (const field of numericFields) {
        placement[field] = lo.placement[field] + ((hi.placement[field] ?? lo.placement[field]) - lo.placement[field]) * t;
      }
      for (const field of hexFields) {
        placement[field] = lerpHexColor(lo.placement[field], hi.placement[field], t);
      }
      const obj = keyframeBuilder(placement, sampleOffset);
      obj.offset = sampleOffset;
      frames.push(obj);
    }
    return { frames, easing: 'linear' };
  }

  /// Builds the DOM element + (for a tween span) its two independent Web
  /// Animations for the span governed by keyframe `kf` on `layer` — called
  /// once per span, not per frame. Position/size/rotation ease on
  /// `tweenSettings`; color/opacity ease separately on
  /// `colorTweenSettings` — same start/end frames, their own curve, two
  /// concurrent `animate()` calls on the same element (exactly what the Web
  /// Animations API is for), not one animation forced to share a curve
  /// across unrelated properties.
  function createLayerVisual(layer, kf, layerIndex) {
    const base = resolvePlacement(layer, kf);
    const el = document.createElement('div');
    el.className = 'flaj-text';
    applyStaticTextStyle(el, base);
    maskAwareParent(layerIndex, textLayerEl).appendChild(el);

    const endKf = tweenTarget(layer.frames, kf);
    const end = endKf != null ? resolvePlacement(layer, endKf) : null;
    const animations = [];

    // If this span's content is a symbol instance whose symbol has more
    // than one frame, remember enough (which symbol/instance, and this
    // span's own governing keyframe) to keep advancing its independent
    // internal loop every tick — see applySymbolLoopFrame, called from
    // syncLayerVisual.
    const instance = layer.symbolFrames && layer.symbolFrames[kf];
    const symbol = instance && findSymbol(instance.symbolID);
    const loop = symbol && (symbol.totalFrames || 1) > 1 ? { symbol, kf, instance } : null;
    const endInstance = loop && endKf != null && layer.symbolFrames && layer.symbolFrames[endKf];

    if (endKf != null && end && endKf > kf) {
      const durationMs = ((endKf - kf) / fps) * 1000;
      const boxSettings = layer.tweenSettings[kf];
      const colorSettings = layer.colorTweenSettings[kf];

      if (loop && endInstance) {
        // The placed instance is *also* classic-tweened while its symbol
        // independently loops — two differently-timed, differently-eased
        // curves whose combined value (product for opacity/scale, sum for
        // rotation) no single CSS easing function could express as one
        // two-point animation. Resampled into an evenly spaced keyframe
        // list instead — the same trick cssLinearEasing already uses to
        // bake a single non-monotonic curve into a browser-native
        // `linear()` timing function, just applied to the combined
        // *values* themselves rather than one progress scalar — so this
        // still plays as one real, compositor-driven Web Animation
        // instead of a per-tick JS override fighting it every paint.
        const { boxFrames, colorFrames } = resampleCombinedSymbolLoopKeyframes(
          instance, endInstance, boxSettings, colorSettings, symbol, kf, endKf
        );
        const boxAnimation = el.animate(boxFrames, { duration: durationMs, easing: 'linear', fill: 'both' });
        boxAnimation.pause();
        animations.push(boxAnimation);

        const colorAnimation = el.animate(colorFrames, { duration: durationMs, easing: 'linear', fill: 'both' });
        colorAnimation.pause();
        animations.push(colorAnimation);
      } else {
        const totalSpin = spinDegrees(boxSettings, 1);
        const checkpoints = tweenCheckpoints(layer, kf, endKf);
        const box = checkpointedKeyframes(
          checkpoints, kf, endKf, boxSettings,
          (placement, offset) => boxKeyframe(placement, totalSpin * offset),
          ['x', 'y', 'width', 'height', 'fontSize', 'scale', 'rotation'], []
        );
        const boxAnimation = el.animate(box.frames, { duration: durationMs, fill: 'both', easing: box.easing });
        boxAnimation.pause();
        animations.push(boxAnimation);

        const color = checkpointedKeyframes(checkpoints, kf, endKf, colorSettings, colorKeyframe, ['opacity'], ['colorHex']);
        const colorAnimation = el.animate(color.frames, { duration: durationMs, fill: 'both', easing: color.easing });
        colorAnimation.pause();
        animations.push(colorAnimation);
      }
    } else {
      Object.assign(el.style, boxKeyframe(base, 0), colorKeyframe(base));
    }

    return { kf, element: el, animations, loop };
  }

  // See createLayerVisual's own comment on why this exists. Samples the
  // *combined* instance+content value of every box/color property at
  // `steps` evenly spaced points across [kf, endKf] — the same 40-step
  // granularity cssLinearEasing already uses for a single curve — and
  // returns two ready-to-animate WAAPI keyframe arrays. `boxSettings`/
  // `colorSettings` govern the *instance's* own tween exactly as they
  // always have; the symbol's own internal easing is already baked into
  // whatever interpolatedSymbolContent returns at each sampled frame, so
  // the two curves' shapes both survive despite being flattened into one
  // list of plain values with `easing: 'linear'` between them.
  function resampleCombinedSymbolLoopKeyframes(instanceBase, instanceEnd, boxSettings, colorSettings, symbol, kf, endKf) {
    const steps = 40;
    const layer = symbol.layers && symbol.layers[0];
    const totalSpin = spinDegrees(boxSettings, 1);
    const lerp = (a, b, t) => a + (b - a) * t;
    const boxFrames = [];
    const colorFrames = [];
    for (let i = 0; i <= steps; i++) {
      const rawT = i / steps;
      const boxT = easedProgress(boxSettings, rawT);
      const colorT = easedProgress(colorSettings, rawT);
      // Floored: governingKeyframe/interpolatedSymbolContent index straight
      // into the frames array assuming an integer frame number (mirroring
      // TLLayer's own Int-typed `frame` parameters natively) — a fractional
      // sample here would silently miss the array and throw. The symbol's
      // own loop only ever actually advances on integer frame boundaries
      // anyway (see applySymbolLoopFrame's identical Math.floor), so this
      // matches its real behavior, not just working around the indexing.
      const parentFrame = Math.floor(kf + rawT * (endKf - kf));
      const local = symbolLocalFrame(symbol, parentFrame, kf);
      const content = (layer && interpolatedSymbolContent(layer, local)) || {};
      const instScale = lerp(instanceBase.scale ?? 1, instanceEnd.scale ?? 1, boxT);
      const instRotation = lerp(instanceBase.rotation ?? 0, instanceEnd.rotation ?? 0, boxT) + totalSpin * boxT;
      const instOpacity = lerp(instanceBase.opacity ?? 1, instanceEnd.opacity ?? 1, colorT);
      boxFrames.push({
        offset: rawT,
        left: lerp(instanceBase.x, instanceEnd.x, boxT) + 'px',
        top: lerp(instanceBase.y, instanceEnd.y, boxT) + 'px',
        width: lerp(instanceBase.width, instanceEnd.width, boxT) + 'px',
        height: lerp(instanceBase.height, instanceEnd.height, boxT) + 'px',
        fontSize: (content.fontSize ?? 24) + 'px',
        transform: `scale(${instScale * (content.scale ?? 1)}) rotate(${instRotation + (content.rotation ?? 0)}deg)`
      });
      colorFrames.push({
        offset: rawT,
        color: content.colorHex ?? '#000000',
        opacity: String(instOpacity * (content.opacity ?? 1))
      });
    }
    return { boxFrames, colorFrames };
  }

  // Advances a looping symbol instance's own internal frame independently
  // of its span's box/color Web Animation — called every tick regardless
  // of whether the span itself just changed, since the loop keeps
  // advancing even while the instance sits mid-span doing nothing else.
  //
  // text/fontFamily/fontWeight/fontStyle always apply directly: textContent
  // isn't a CSS property WAAPI can touch at all, and the other three only
  // support *discrete* (not eased) keyframing, not worth resampling for
  // when a direct write already gets them exactly right every tick.
  // fontSize/color/opacity/scale/rotation are different — those genuinely
  // interpolate, and when the instance itself is *also* classic-tweened,
  // createLayerVisual already baked the correct combined value straight
  // into that Web Animation (see resampleCombinedSymbolLoopKeyframes), so
  // writing them here too would be redundant at best and would lose the
  // fight against the running Animation's own per-paint reapplication at
  // worst. They're only written here for the untweened case (no Animation
  // exists at all — see createLayerVisual's `else` branch — so this is the
  // only thing keeping them in sync as the loop advances).
  function applySymbolLoopFrame(visual, frame) {
    if (!visual.loop) return;
    const { symbol, kf, instance } = visual.loop;
    const layer = symbol.layers && symbol.layers[0];
    if (!layer) return;
    const local = symbolLocalFrame(symbol, frame, kf);
    const content = interpolatedSymbolContent(layer, local);
    if (!content) return;
    const el = visual.element;
    el.textContent = content.text;
    el.style.fontFamily = content.fontName + ', sans-serif';
    el.style.fontWeight = content.bold ? 'bold' : 'normal';
    el.style.fontStyle = content.italic ? 'italic' : 'normal';
    el.style.textShadow = textShadowCSS(content); // not WAAPI-animated by anything, so always safe to set directly
    if (visual.animations.length > 0) return;
    el.style.fontSize = content.fontSize + 'px';
    el.style.color = content.colorHex;
    el.style.opacity = String(instance.opacity * content.opacity);
    el.style.transform = `scale(${instance.scale * content.scale}) rotate(${instance.rotation + content.rotation}deg)`;
  }

  // ---- shapes (mirrors StagePlacedShapeView/TLLayer.interpolatedPlacedShape) ----
  // Tweenable exactly like placed text — two independent Web Animations
  // per span (position/size/strokeWidth/cornerRadius on the box curve,
  // fill/stroke color and every opacity on the color curve), same split
  // createLayerVisual already uses. `kind` (rectangle vs. ellipse) and
  // `strokeStyle` (solid/dashed/dotted) never interpolate, so both are
  // set once at element-creation time, not part of either animated
  // keyframe set — border-radius still needs computing per shape though,
  // since an ellipse's 50% and a rectangle's cornerRadius-in-px are two
  // different animatable values, not a fixed constant like borderStyle.

  function hexWithAlpha(hex, opacity) {
    const [r, g, b] = hexComponents(hex);
    return `rgba(${r}, ${g}, ${b}, ${opacity})`;
  }

  function shapeBorderRadius(shape) {
    return shape.kind === 'ellipse' ? '50%' : (shape.cornerRadius + 'px');
  }

  function shapeBoxKeyframe(shape) {
    return {
      left: shape.x + 'px', top: shape.y + 'px',
      width: shape.width + 'px', height: shape.height + 'px',
      borderWidth: shape.strokeWidth + 'px',
      borderRadius: shapeBorderRadius(shape)
    };
  }

  function shapeColorKeyframe(shape) {
    return {
      backgroundColor: hexWithAlpha(shape.fillColorHex, shape.fillOpacity),
      borderColor: hexWithAlpha(shape.strokeColorHex, shape.strokeOpacity),
      opacity: String(shape.opacity)
    };
  }

  const layerShapeVisuals = new Map(); // layerIndex -> { kf, element, animations }

  function createShapeVisual(layer, kf, layerIndex) {
    const base = layer.shapeFrames[kf];
    const el = document.createElement('div');
    el.className = 'flaj-shape';
    el.style.borderStyle = base.strokeStyle; // CSS's own keyword values are literally "solid"/"dashed"/"dotted"
    maskAwareParent(layerIndex, shapesLayerEl).appendChild(el);

    const endKf = tweenTarget(layer.frames, kf);
    const end = endKf != null ? layer.shapeFrames[endKf] : null;
    const animations = [];

    if (endKf != null && end && endKf > kf) {
      const durationMs = ((endKf - kf) / fps) * 1000;
      // Same checkpoint mechanism as the text/symbol path (see
      // tweenCheckpoints/checkpointedKeyframes) — a property keyframe here
      // is just an extra shapeFrames entry at an intermediate .tween frame.
      const frames = Object.keys(layer.shapeFrames).map(Number).filter(f => f >= kf && f <= endKf).sort((a, b) => a - b);
      const checkpoints = frames.map(frame => ({ frame, placement: layer.shapeFrames[frame] }));

      const box = checkpointedKeyframes(
        checkpoints, kf, endKf, layer.tweenSettings[kf], shapeBoxKeyframe,
        ['x', 'y', 'width', 'height', 'strokeWidth', 'cornerRadius'], []
      );
      const boxAnimation = el.animate(box.frames, { duration: durationMs, fill: 'both', easing: box.easing });
      boxAnimation.pause();
      animations.push(boxAnimation);

      const color = checkpointedKeyframes(
        checkpoints, kf, endKf, layer.colorTweenSettings[kf], shapeColorKeyframe,
        ['fillOpacity', 'strokeOpacity', 'opacity'], ['fillColorHex', 'strokeColorHex']
      );
      const colorAnimation = el.animate(color.frames, { duration: durationMs, fill: 'both', easing: color.easing });
      colorAnimation.pause();
      animations.push(colorAnimation);
    } else {
      Object.assign(el.style, shapeBoxKeyframe(base), shapeColorKeyframe(base));
    }

    return { kf, element: el, animations };
  }

  // Same reuse-vs-recreate/time-sync/play-pause logic as syncLayerVisual's
  // own text path — see its doc comment for why forceTimeSync exists.
  function syncShapeVisual(layerIndex, layer, kf, frame, forceTimeSync) {
    let visual = layerShapeVisuals.get(layerIndex);
    if (!visual || visual.kf !== kf) {
      if (visual) { visual.animations.forEach(a => a.cancel()); visual.element.remove(); }
      visual = createShapeVisual(layer, kf, layerIndex);
      layerShapeVisuals.set(layerIndex, visual);
      forceTimeSync = true;
    }
    for (const animation of visual.animations) {
      if (forceTimeSync) animation.currentTime = ((frame - kf) / fps) * 1000;
      if (isPlaying) {
        if (animation.playState !== 'running') animation.play();
      } else if (animation.playState === 'running') {
        animation.pause();
      }
    }
  }

  function removeShapeVisual(layerIndex) {
    const visual = layerShapeVisuals.get(layerIndex);
    if (visual) { visual.animations.forEach(a => a.cancel()); visual.element.remove(); layerShapeVisuals.delete(layerIndex); }
  }

  // ---- groups (mirrors StagePlacedGroupView in StageView.swift) ----
  // Not tweenable in v1 (see PlacedGroup's own doc comment) — a plain div
  // per governing keyframe, rebuilt whenever the keyframe changes, same
  // idiom shapes originally used before shape tweening existed. Renders
  // every bundled text/shape/symbol child at its own position relative to
  // the group's own origin. A nested symbol's independent loop is only
  // resolved once, at the moment this element is built, not kept
  // per-tick current the way a top-level symbol instance is — a real,
  // documented web-export-only limitation (the native Stage/GIF export
  // path re-resolves it every frame via `doc.playhead` reactively;
  // matching that here would mean per-tick DOM updates for every group
  // with a nested symbol, out of scope for v1's "groups are static"
  // starting point).

  const layerGroupVisuals = new Map(); // layerIndex -> { kf, element }

  function appendGroupShapeChild(container, shape) {
    const el = document.createElement('div');
    el.className = 'flaj-shape';
    el.style.left = shape.x + 'px';
    el.style.top = shape.y + 'px';
    el.style.width = shape.width + 'px';
    el.style.height = shape.height + 'px';
    el.style.backgroundColor = hexWithAlpha(shape.fillColorHex, shape.fillOpacity);
    el.style.borderStyle = shape.strokeStyle;
    el.style.borderWidth = shape.strokeWidth + 'px';
    el.style.borderColor = hexWithAlpha(shape.strokeColorHex, shape.strokeOpacity);
    el.style.borderRadius = shapeBorderRadius(shape);
    el.style.opacity = String(shape.opacity);
    container.appendChild(el);
  }

  function appendGroupTextChild(container, text) {
    const el = document.createElement('div');
    el.className = 'flaj-text';
    applyStaticTextStyle(el, text);
    el.style.left = text.x + 'px';
    el.style.top = text.y + 'px';
    el.style.width = text.width + 'px';
    el.style.height = text.height + 'px';
    el.style.color = text.colorHex;
    el.style.opacity = String(text.opacity);
    el.style.transform = `scale(${text.scale}) rotate(${text.rotation}deg)`;
    container.appendChild(el);
  }

  function appendGroupSymbolChild(container, instance, frame, groupKf) {
    const symbol = findSymbol(instance.symbolID);
    const layer = symbol && symbol.layers && symbol.layers[0];
    if (!layer) return;
    const local = symbolLocalFrame(symbol, frame, groupKf);
    const content = interpolatedSymbolContent(layer, local);
    if (!content) return;
    const el = document.createElement('div');
    el.className = 'flaj-text';
    applyStaticTextStyle(el, content);
    el.style.left = instance.x + 'px';
    el.style.top = instance.y + 'px';
    el.style.width = instance.width + 'px';
    el.style.height = instance.height + 'px';
    el.style.color = content.colorHex;
    el.style.opacity = String(instance.opacity * content.opacity);
    el.style.transform = `scale(${instance.scale * content.scale}) rotate(${instance.rotation + content.rotation}deg)`;
    container.appendChild(el);
  }

  function createGroupVisual(layer, kf, frame) {
    const group = layer.groupFrames[kf];
    const el = document.createElement('div');
    el.className = 'flaj-group';
    el.style.left = group.x + 'px';
    el.style.top = group.y + 'px';
    el.style.width = group.width + 'px';
    el.style.height = group.height + 'px';
    el.style.opacity = String(group.opacity);
    el.style.transform = `rotate(${group.rotation}deg)`;
    (group.shapes || []).forEach(s => appendGroupShapeChild(el, s));
    (group.texts || []).forEach(t => appendGroupTextChild(el, t));
    (group.symbols || []).forEach(s => appendGroupSymbolChild(el, s, frame, kf));
    groupsLayerEl.appendChild(el);
    return { kf, element: el };
  }

  function syncGroupVisual(layerIndex, layer, kf, frame) {
    const visual = layerGroupVisuals.get(layerIndex);
    if (!visual || visual.kf !== kf) {
      if (visual) visual.element.remove();
      layerGroupVisuals.set(layerIndex, createGroupVisual(layer, kf, frame));
    }
  }

  function removeGroupVisual(layerIndex) {
    const visual = layerGroupVisuals.get(layerIndex);
    if (visual) { visual.element.remove(); layerGroupVisuals.delete(layerIndex); }
  }

  /// Makes sure `layerIndex` is showing the right span for `frame` (an
  /// integer for a routine tick, but can be fractional for an explicit
  /// scrub mid-span). Reuses the existing Animations untouched when the
  /// span hasn't changed and `forceTimeSync` isn't set — that's what leaves
  /// in-progress motion alone to keep running on its own native clock.
  function syncLayerVisual(layerIndex, layer, frame, forceTimeSync) {
    // A mask layer's own content is never drawn directly on Stage — only
    // used as a clip stencil (see maskingLayerFor/syncMaskWraps) for
    // whatever it masks, mirroring StageContentView's identical skip.
    if (layerKind(layer) === 'mask') {
      const existing = layerVisuals.get(layerIndex);
      if (existing) { existing.animations.forEach(a => a.cancel()); existing.element.remove(); layerVisuals.delete(layerIndex); }
      removeShapeVisual(layerIndex);
      removeGroupVisual(layerIndex);
      return;
    }

    const kf = governingKeyframe(layer.frames, Math.floor(frame));

    // A shape/group keyframe is mutually exclusive with text/symbol
    // content on the same layer (see TLLayer in TimelineModel.swift) —
    // handled entirely separately from the text/symbol Web-Animation
    // machinery below (own animations, own visuals map), via
    // createShapeVisual/syncShapeVisual and createGroupVisual/
    // syncGroupVisual above.
    const shape = kf != null && layer.shapeFrames && layer.shapeFrames[kf];
    if (shape) {
      const existingText = layerVisuals.get(layerIndex);
      if (existingText) { existingText.animations.forEach(a => a.cancel()); existingText.element.remove(); layerVisuals.delete(layerIndex); }
      removeGroupVisual(layerIndex);
      if (layer.hidden) { removeShapeVisual(layerIndex); return; }
      syncShapeVisual(layerIndex, layer, kf, frame, forceTimeSync);
      return;
    }
    removeShapeVisual(layerIndex);

    const group = kf != null && layer.groupFrames && layer.groupFrames[kf];
    if (group) {
      const existingText = layerVisuals.get(layerIndex);
      if (existingText) { existingText.animations.forEach(a => a.cancel()); existingText.element.remove(); layerVisuals.delete(layerIndex); }
      if (layer.hidden) { removeGroupVisual(layerIndex); return; }
      syncGroupVisual(layerIndex, layer, kf, frame);
      return;
    }
    removeGroupVisual(layerIndex);

    const existing = layerVisuals.get(layerIndex);

    // A named instance already spawned into `stageObjects` (see
    // spawnNamedInstances) is rendered by renderStageObjects instead —
    // it's now a live, script-controlled object, not Timeline-authored
    // content, mirroring StageView's identical suppression in the native app.
    const instance = kf != null && layer.symbolFrames && layer.symbolFrames[kf];
    const spawned = instance && instance.name && stageObjects.has(instance.name);

    if (kf == null || layer.hidden || !resolvePlacement(layer, kf) || spawned) {
      if (existing) { existing.animations.forEach(a => a.cancel()); existing.element.remove(); layerVisuals.delete(layerIndex); }
      return;
    }

    let visual = existing;
    if (!visual || visual.kf !== kf) {
      if (visual) { visual.animations.forEach(a => a.cancel()); visual.element.remove(); }
      visual = createLayerVisual(layer, kf, layerIndex);
      layerVisuals.set(layerIndex, visual);
      forceTimeSync = true; // a freshly created span always needs its clock set once
    }

    for (const animation of visual.animations) {
      if (forceTimeSync) animation.currentTime = ((frame - kf) / fps) * 1000;
      if (isPlaying) {
        if (animation.playState !== 'running') animation.play();
      } else if (animation.playState === 'running') {
        animation.pause();
      }
    }
    applySymbolLoopFrame(visual, Math.floor(frame));
  }

  function syncAllLayerVisuals(frame, forceTimeSync) {
    doc.layers.forEach((layer, i) => syncLayerVisual(i, layer, frame, forceTimeSync));
    syncMaskWraps(frame);
  }

  // ---- stage (script-created) objects ----
  // Dynamic and only known once a script actually calls stage.tween(), so
  // (unlike the declarative placed-text spans above) these stay
  // JS-recomputed each tick — but from a fractional, continuously-advancing
  // frame number, so motion is still smooth between logical frame
  // boundaries, just not fully compositor-offloaded.

  function makeStageObjectNode(obj) {
    const div = document.createElement('div');
    div.className = 'flaj-object';
    div.textContent = obj.text;
    div.style.left = obj.x + 'px';
    div.style.top = obj.y + 'px';
    div.style.fontSize = obj.fontSize + 'px';
    div.style.fontFamily = (obj.fontName || 'Helvetica') + ', sans-serif';
    div.style.fontWeight = obj.bold ? 'bold' : 'normal';
    div.style.fontStyle = obj.italic ? 'italic' : 'normal';
    div.style.color = obj.color;
    div.style.opacity = String(obj.opacity);
    div.style.transform = `translate(-50%, -50%) scale(${obj.scale}) rotate(${obj.rotation}deg)`;
    return div;
  }

  function renderStageObjects() {
    objectsLayerEl.replaceChildren();
    for (const obj of stageObjects.values()) {
      objectsLayerEl.appendChild(makeStageObjectNode(obj));
    }
  }

  const stageObjectDefaults = { fontSize: 24, color: '#000000', scale: 1, rotation: 0, opacity: 1, fontName: 'Helvetica', bold: false, italic: false };

  // For every layer whose governing keyframe at `playhead` is a named
  // symbol instance not already spawned, creates a stage object from it —
  // same as a script calling stage.addText with that name (mirrors
  // TimelineDocument.spawnNamedInstances; keep both in lockstep). Runs
  // once per frame, before that frame's own scripts, so a frame-1 script
  // can address an instance placed on frame 1 immediately.
  function spawnNamedInstances() {
    for (const layer of doc.layers) {
      if (!isKeyframe(layer.frames, playhead)) continue;
      const instance = layer.symbolFrames && layer.symbolFrames[playhead];
      if (!instance || !instance.name || stageObjects.has(instance.name)) continue;
      const symbol = findSymbol(instance.symbolID);
      const content = symbol && symbolContent(symbol);
      if (!content) continue;
      stageObjects.set(instance.name, {
        ...stageObjectDefaults,
        text: content.text, x: instance.x + instance.width / 2, y: instance.y + instance.height / 2,
        fontSize: content.fontSize, color: content.colorHex, scale: instance.scale,
        rotation: instance.rotation, opacity: instance.opacity,
        fontName: content.fontName, bold: content.bold, italic: content.italic
      });
    }
  }

  // ---- frame scripts & the JS globals they run against ----
  // (mirrors TimelineDocument.makeJSContext in TimelineModel.swift)

  function preprocessForReentry(script) {
    const declRe = /^([ \t]*)(const|let)\s+([A-Za-z_$][A-Za-z0-9_$]*)\b/;
    return script.split('\n').map(line => {
      const m = declRe.exec(line);
      if (!m) return line;
      const name = m[3];
      if (declaredTopLevelBindings.has(name)) return '// (already declared) ' + line;
      declaredTopLevelBindings.add(name);
      return line;
    }).join('\n');
  }

  // Flash's "named anchor" convention: a frame label starting with "#"
  // updates the page's URL fragment when reached, making it a real
  // back/forward-navigable browser history entry and a valid deep link —
  // see the location.hash bootstrap check at the bottom of this file for
  // the read side. Runs once per frame actually entered (this function's
  // one call site per navigation path), never mid-tween.
  function updateNamedAnchor() {
    for (const layer of doc.layers) {
      const entry = (layer.frameLabels || {})[playhead];
      const label = entry && entry.type !== 'comment' ? entry.text : null;
      if (label && label.charAt(0) === '#' && location.hash !== label) {
        location.hash = label;
        return;
      }
    }
  }

  function runScriptsOnCurrentFrame() {
    updateNamedAnchor();
    spawnNamedInstances();
    for (const layer of doc.layers) {
      if (!isKeyframe(layer.frames, playhead)) continue;
      const script = layer.frameScripts[playhead];
      if (!script) continue;
      try {
        // Indirect eval — runs in global scope, same realm every call, so a
        // `const`/`let` from an earlier frame is still visible (and must be
        // skipped, not re-thrown) the way JSContext's shared context behaves.
        (0, eval)(preprocessForReentry(script));
      } catch (e) {
        console.error(e && e.message ? e.message : String(e));
      }
    }
    updateClickTag();
  }

  // The banner-ad clickTag convention: a script sets stage.clickTag to a
  // URL (a plain assignable property, not a method — see the `stage`
  // object below) and the *whole* Stage frame becomes one big link,
  // opening it in a new window/tab. Applied to #flaj-frame, not just the
  // background, so it wins over clicks on placed text/stage objects too —
  // mirrors StageView's identical clickTag overlay in the native app.
  // `stage` itself is a plain, persistent object, so once set this stays
  // in effect across frames without needing to be re-set each time —
  // checked after every script run regardless of whether *that* frame's
  // script touched it.
  //
  // A mouse-only onclick would make the whole-frame link unreachable by
  // keyboard — real banner placements get tabbed to and activated with
  // Enter/Space just like any other link, so this also gives #flaj-frame a
  // link role, a tab stop, and a matching keydown handler while active.
  function updateClickTag() {
    const url = stage.clickTag;
    const active = typeof url === 'string' && url.length > 0;
    const open = () => window.open(url, '_blank');
    frameEl.style.cursor = active ? 'pointer' : '';
    frameEl.onclick = active ? open : null;
    if (active) {
      frameEl.setAttribute('role', 'link');
      frameEl.setAttribute('aria-label', 'Open ' + url);
      frameEl.tabIndex = 0;
      frameEl.onkeydown = (e) => {
        if (e.key === 'Enter' || e.key === ' ') {
          e.preventDefault();
          open();
        }
      };
    } else {
      frameEl.removeAttribute('role');
      frameEl.removeAttribute('aria-label');
      frameEl.removeAttribute('tabindex');
      frameEl.onkeydown = null;
    }
  }

  function clamp(frame, lo, hi) { return Math.min(Math.max(frame, lo), hi); }

  // ---- the clock ----
  // requestAnimationFrame instead of setInterval: pauses automatically when
  // the tab/page isn't visible, and stays synced to the display's actual
  // refresh cycle. It only ever checks "has enough wall-clock time passed
  // to cross an integer frame boundary" — the visual motion in between is
  // never its job.

  function frameDurationMs() { return 1000 / fps; }

  function currentFractionalFrame(now) {
    if (frameOriginTime == null) return playhead;
    return playhead + Math.min(0.999, (now - frameOriginTime) / frameDurationMs());
  }

  function loop(now) {
    if (!isPlaying) { rafHandle = null; return; }
    if (frameOriginTime == null) frameOriginTime = now;

    // Bounded, not `while (isPlaying)`: a pathological fps/duration
    // shouldn't be able to wedge this in an unbounded synchronous loop.
    for (let guard = 0; guard < 1000 && now - frameOriginTime >= frameDurationMs(); guard++) {
      playhead = playhead >= contentLength() ? 1 : playhead + 1;
      frameOriginTime += frameDurationMs();
      runScriptsOnCurrentFrame();
      syncAllLayerVisuals(playhead, false);
      if (!isPlaying) { rafHandle = null; return; } // the script may have called stop()
    }

    advanceTweens(currentFractionalFrame(now));
    renderStageObjects();

    // A single-content-frame movie has nowhere left to advance to — with no
    // stage-object tween still in flight either, "looping" would just mean
    // re-running the same script forever. Settle instead, like a static
    // hand-authored page that ran its one <script> and is done.
    if (contentLength() <= 1 && activeTweens.length === 0) { isPlaying = false; rafHandle = null; return; }

    rafHandle = requestAnimationFrame(loop);
  }

  function stop() {
    isPlaying = false;
    for (const visual of layerVisuals.values()) visual.animations.forEach(a => a.pause());
  }

  function play() {
    isPlaying = true;
    frameOriginTime = null;
    runScriptsOnCurrentFrame();
    syncAllLayerVisuals(playhead, true);
    renderStageObjects();
    if (!isPlaying) return; // the frame's own script may have called stop()
    if (contentLength() <= 1 && activeTweens.length === 0) { isPlaying = false; return; }
    if (rafHandle == null) rafHandle = requestAnimationFrame(loop);
  }

  // Searches every layer's frameLabels in document order, earliest frame
  // first within a layer, for a deterministic result even if a label is
  // (unusually) duplicated. Silent on a miss — callers that mean to warn
  // (resolveFrame below) do that themselves; the deep-link bootstrap at the
  // bottom of this file deliberately doesn't, since an unrelated URL
  // fragment shouldn't spam a warning on every ordinary page load.
  function findLabeledFrame(label) {
    for (const layer of doc.layers) {
      const labels = layer.frameLabels || {};
      const frame = Object.keys(labels)
        .map(Number)
        .sort((a, b) => a - b)
        .find(f => labels[f].type !== 'comment' && labels[f].text === label);
      if (frame != null) return frame;
    }
    return null;
  }

  // gotoAndStop/gotoAndPlay/goto accept either a frame number or a frame
  // label (mirrors TimelineDocument.resolveFrameArgument in
  // TimelineModel.swift — keep both in lockstep).
  function resolveFrame(target) {
    if (typeof target !== 'string') return target;
    const frame = findLabeledFrame(target);
    if (frame == null) console.warn(`No frame labeled "${target}".`);
    return frame;
  }

  function gotoAndStop(target) {
    const frame = resolveFrame(target);
    if (frame == null) return;
    stop();
    playhead = clamp(frame, 1, totalFrames);
    frameOriginTime = null;
    runScriptsOnCurrentFrame();
    syncAllLayerVisuals(playhead, true);
    renderStageObjects();
  }

  function gotoAndPlay(target) {
    const frame = resolveFrame(target);
    if (frame == null) return;
    playhead = clamp(frame, 1, totalFrames);
    frameOriginTime = null;
    play();
  }

  function goto(target) {
    const frame = resolveFrame(target);
    if (frame == null) return;
    playhead = clamp(frame, 1, contentLength());
    frameOriginTime = null;
    runScriptsOnCurrentFrame();
    syncAllLayerVisuals(playhead, true);
    renderStageObjects();
  }

  // CSS already understands hex ("#ff0000"), named colors
  // ("cornflowerblue"), and "transparent" natively — no lookup table needed
  // here the way the Swift side needs one for SwiftUI's Color.
  const bg = {
    color(value) { stageColor = value; stageEl.style.backgroundColor = stageColor; }
  };

  function startTween(id, property, to, frames, easingName) {
    const obj = stageObjects.get(id);
    if (!obj) return;
    const from = obj[property];
    activeTweens = activeTweens.filter(tw => !(tw.id === id && tw.property === property));
    activeTweens.push({ id, property, from, to, startFrame: playhead, duration: Math.max(1, frames), easing: SIMPLE_EASING[easingName] || SIMPLE_EASING.linear });
  }

  function advanceTweens(frame) {
    if (!activeTweens.length) return;
    const remaining = [];
    for (const tw of activeTweens) {
      const obj = stageObjects.get(tw.id);
      if (!obj) continue;
      const rawT = (frame - tw.startFrame) / tw.duration;
      const t = tw.easing(Math.min(Math.max(rawT, 0), 1));
      obj[tw.property] = tw.from + (tw.to - tw.from) * t;
      if (rawT < 1) remaining.push(tw);
    }
    activeTweens = remaining;
  }

  const stage = {
    size(w, h) {
      stageWidth = Math.max(1, w);
      stageHeight = Math.max(1, h);
      stageEl.style.width = stageWidth + 'px';
      stageEl.style.height = stageHeight + 'px';
      fitStageToViewport();
    },
    addText(id, text, x, y) {
      if (stageObjects.has(id)) return; // ids are stable handles, not re-creatable
      stageObjects.set(id, { ...stageObjectDefaults, text, x, y });
      renderStageObjects();
      if (!isPlaying && rafHandle == null) rafHandle = requestAnimationFrame(loop); // a static page can still host a live object
    },
    setText(id, text) {
      const obj = stageObjects.get(id);
      if (!obj) return;
      obj.text = text;
      renderStageObjects();
    },
    setTransform(id, props) {
      const obj = stageObjects.get(id);
      if (!obj || !props) return;
      for (const key of ['x', 'y', 'scale', 'rotation', 'opacity']) {
        if (props[key] !== undefined) obj[key] = props[key];
      }
      renderStageObjects();
    },
    tween(id, props, frames, easing) {
      if (!props) return;
      for (const key of ['x', 'y', 'scale', 'rotation', 'opacity', 'fontSize']) {
        if (props[key] !== undefined) startTween(id, key, props[key], frames, easing);
      }
      if (!isPlaying && rafHandle == null) rafHandle = requestAnimationFrame(loop);
    }
  };

  const trace = console.log.bind(console);

  // Expose the runtime API as real globals — frame scripts run via indirect
  // eval in this same global scope, exactly like a bare <script> tag would
  // see them.
  Object.assign(window, { stop, play, gotoAndStop, gotoAndPlay, goto, bg, stage, trace });

  // ---- layout: fit + alignment ----
  //
  // #flaj-stage is transform: scale()'d, but a transform never changes an
  // element's own layout size — so #flaj-frame (unscaled, owns the
  // border/shadow) has its *actual* width/height set to match here. That's
  // what keeps the border hairline-crisp at any zoom instead of scaling up
  // fat with the content, and what makes body's flex alignment (the 9-point
  // StageAlignment grid) anchor against the Stage's real on-screen edges —
  // a corner alignment combined with `.cover`/`.none` genuinely hugs that
  // corner now, rather than scaling outward from a fixed center point
  // regardless of which corner was actually requested.

  function fitStageToViewport() {
    const viewportWidth = document.documentElement.clientWidth;
    const viewportHeight = document.documentElement.clientHeight;
    const scaleX = viewportWidth / stageWidth;
    const scaleY = viewportHeight / stageHeight;
    let scale;
    switch (doc.webExportFit) {
      case 'cover': scale = Math.max(scaleX, scaleY); break;
      case 'none': scale = 1; break;
      default: scale = Math.min(scaleX, scaleY); break; // contain
    }
    stageEl.style.transform = `scale(${scale})`;
    frameEl.style.width = (stageWidth * scale) + 'px';
    frameEl.style.height = (stageHeight * scale) + 'px';
  }

  // Maps each 9-point StageAlignment case to a (align-items, justify-content)
  // pair on <body>, which is how the empty space `.contain`/`.none` can
  // leave around the Stage gets distributed.
  const ALIGNMENT_TO_FLEX = {
    topLeading: ['flex-start', 'flex-start'], top: ['flex-start', 'center'], topTrailing: ['flex-start', 'flex-end'],
    leading: ['center', 'flex-start'], center: ['center', 'center'], trailing: ['center', 'flex-end'],
    bottomLeading: ['flex-end', 'flex-start'], bottom: ['flex-end', 'center'], bottomTrailing: ['flex-end', 'flex-end']
  };

  function applyAlignment() {
    const [alignItems, justifyContent] = ALIGNMENT_TO_FLEX[doc.webExportAlignment] || ALIGNMENT_TO_FLEX.center;
    document.body.style.alignItems = alignItems;
    document.body.style.justifyContent = justifyContent;
  }

  // ResizeObserver over the plain `window` resize event: it also catches a
  // host page resizing the <iframe> this is embedded in, the viewport
  // changing because a mobile browser's chrome (address bar) showed or
  // hid, and orientation changes — cases a bare `resize` listener doesn't
  // reliably cover.
  if (typeof ResizeObserver !== 'undefined') {
    new ResizeObserver(fitStageToViewport).observe(document.documentElement);
  } else {
    window.addEventListener('resize', fitStageToViewport);
  }

  stageEl.style.backgroundColor = stageColor;
  applyAlignment();
  stageEl.style.width = stageWidth + 'px';
  stageEl.style.height = stageHeight + 'px';
  fitStageToViewport(); // synchronous first fit — ResizeObserver's own initial callback is async and would otherwise flash unscaled content for a frame

  // Deep-linking: opening the page with a URL fragment matching a named
  // anchor (a "#"-prefixed frame label) starts there instead of frame 1 —
  // the read side of the named-anchor convention (see updateNamedAnchor).
  // Silent, not resolveFrame, if it doesn't match: plenty of pages arrive
  // with an unrelated hash (an analytics fragment, a host page's own
  // anchor) that was never meant as a Flaj frame reference.
  if (location.hash) {
    const startFrame = findLabeledFrame(location.hash);
    if (startFrame != null) playhead = clamp(startFrame, 1, totalFrames);
  }

  play();
})();
