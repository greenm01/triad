# Triad: The Style Guide

We write clean code. This guide ensures every line of Triad is readable and maintainable. We don't settle for less. We follow the patterns established in `ec4x`.

## NEP-1: The Nim Way

Triad follows [NEP-1](https://nim-lang.org/docs/nep1.html) to the letter. 

### The Rules
- **Indents:** Use 2 spaces. No tabs.
- **Lines:** Use `nph` to wrap your code. Don't fight the formatter.
- **Naming:**
    - Types: `PascalCase`.
    - Variables and Procs: `camelCase`.
    - Constants: Use `camelCase`. Nim does not use `UPPER_SNAKE_CASE`.
- **Enums:** Make them pure. Use `{.pure.}`.
- **Getters:** Drop the `get`. `entity(...)` is better than `getEntity(...)`.
- **Setters:** Use the property name with a setter signature: `entity=`.

### The Tool
`nph` is our formatter. Run it on every file. Use `nph --check` to validate without writing. The style guide is the law; `nph` is the enforcer.

## DOD: Data and Dot Syntax

We separate data from logic. Data is passive. Logic is active. 

In Triad, we use **Pragmatic DOD**. Nim compiles `model.focusWindow(id)` into `focusWindow(model, id)`. It’s the same machine code, but it’s easier to read. 

### The Rule
Always use Nim’s dot syntax (UFCS). 

1. **State First:** Define your primary state (e.g., `Model`) as the first parameter.
2. **Dot Syntax:** Invoke procs with a dot.

### Why?
`model.windows.entity(winId)` reads naturally. It flows from left to right. It chains well: `model.findWindow(id).get().title` beats nested calls every time. Plus, your editor will actually help you.

## Performance: The Single Lookup

Never look up the same entity twice. It’s a waste of time.

### The Sin
Checking if an entity exists and then fetching it. That’s two hash table hits.

```nim
# BAD
if model.outputs.hasEntity(outputId):
  let output = model.outputs.getEntity(outputId)
```

### The Standard
Return an `Option[T]`. Do it once.

```nim
# GOOD
import std/options

let outputOpt = model.outputs.entity(outputId)
if outputOpt.isSome():
  let output = outputOpt.get()
```

If you need to mutate in place, use the `m` prefix. `mEntity` gives you a `var` reference directly.

## Overlays: Protect the Heap

Don't kill the heap with full-screen buffers. A screen-sized ARGB buffer eats tens of MiB and spikes the allocator.

Use mapped shm for full-screen surfaces. Render into a memfd-backed `PixelBuffer` view. Create the Wayland buffer from that file descriptor. 

Keep heap-backed buffers for tests or small UI like tabs and toasts. If it's screen-scale, keep it off the heap.
