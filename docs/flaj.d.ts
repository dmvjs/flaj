/**
 * Ambient globals available to frame scripts. Point your editor at this file
 * (or `/// <reference path=".../flaj.d.ts" />` at the top of a script) for
 * autocomplete — it isn't consumed by the app itself. See SCRIPTING.md for
 * the prose version with examples and the execution model.
 */

/** Stops the playhead. */
declare function stop(): void;

/** Resumes playback from wherever the playhead currently is. */
declare function play(): void;

/** Moves to `frame` and stops there. Clamped to 1...totalFrames. */
declare function gotoAndStop(frame: number): void;

/** Moves to `frame` and plays from there. Clamped to 1...totalFrames. */
declare function gotoAndPlay(frame: number): void;

/**
 * Repositions the playhead to `frame` without changing whether the movie is
 * playing or stopped. Clamped to 1...contentLength (the last frame with any
 * content), not the document's full addressable range.
 */
declare function goto(frame: number): void;

declare const bg: {
    /**
     * Sets the Stage background. Accepts a 6-digit hex string ("#ff0000"),
     * a bare CSS color keyword ("cornflowerblue"), or "transparent".
     */
    color(value: string): void;
};

type Easing = "linear" | "easeIn" | "easeOut" | "easeInOut";

interface StageObjectTransform {
    x?: number;
    y?: number;
    scale?: number;
    /** Degrees. */
    rotation?: number;
    /** 0...1. */
    opacity?: number;
    fontSize?: number;
}

declare const stage: {
    /** Resizes the Stage itself. */
    size(width: number, height: number): void;

    /**
     * Creates a text object at (x, y) in Stage pixel coordinates, addressed
     * afterward by `id`. A no-op if `id` is already in use — ids are stable
     * handles, not re-creatable mid-run.
     */
    addText(id: string, text: string, x: number, y: number): void;

    /** Updates an existing text object's content. No-op if `id` is unknown. */
    setText(id: string, text: string): void;

    /**
     * Updates any subset of an object's transform immediately, no
     * animation. Omitted keys are left unchanged.
     */
    setTransform(id: string, transform: StageObjectTransform): void;

    /**
     * Animates any subset of `transform`'s properties from their current
     * value to the given target, over `frames` frames starting now. A
     * second call for the same object+property replaces whichever tween on
     * it was already in flight.
     */
    tween(id: string, transform: StageObjectTransform, frames: number, easing?: Easing): void;
};

declare const console: {
    log(...args: unknown[]): void;
    warn(...args: unknown[]): void;
    error(...args: unknown[]): void;
};

/** ActionScript-style alias for console.log. */
declare function trace(...args: unknown[]): void;
