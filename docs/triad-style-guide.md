# Triad Coding Style and Conventions

This document outlines the strict coding standards and stylistic conventions for the `triad` window manager. Our goal is to maintain a highly readable, maintainable, and idiomatic Nim codebase.

These conventions are drawn directly from the successful practices established in the `ec4x` engine.

## 1. NEP-1 Compliance (Nim Standard)

`triad` strictly adheres to [NEP-1 (Nim Enhancement Proposal 1)](https://nim-lang.org/docs/nep1.html). 

### Key NEP-1 Rules:
*   **Indentation:** Exactly **2 spaces**. No tabs.
*   **Line Wrapping:** Let `nph` decide mechanical line wrapping. Prefer
    readable short expressions where practical, but do not hand-wrap code in a
    way that fights the formatter.
*   **Naming Conventions:**
    *   Types and Macros: `PascalCase` (e.g., `WindowId`, `TagState`).
    *   Variables, Procs, and Constants: `camelCase` (e.g., `activeWindow`, `focusWindow`, `defaultMasterCount`). *Note: Constants do NOT use `UPPER_SNAKE_CASE` in Nim.*
*   **Enums:** All enums **MUST** be pure: `type LayoutMode {.pure.} = enum`.
*   **Getters:** Do **NOT** use the `get` prefix for getter functions.
    *   *Bad:* `proc getEntity(...)`
    *   *Good:* `proc entity(...)`
*   **Setters:** Setters should use the property name with a setter signature.
    *   `proc `entity=`(...)`

### Formatting Tool

`nph` is the required mechanical formatter for Nim-family files in this
repository. Run it on every touched `.nim`, `.nims`, and `.nimble` file before
the normal verification pass.

```sh
nph src/path/to/file.nim
nph --check src/path/to/file.nim
```

Use `nph --check` when validating formatting without writing changes. The style
guide remains the semantic source of truth; `nph` handles mechanical layout,
line wrapping, and import formatting. Do not hand-format code in a way that
fights the formatter.

---

## 2. Pragmatic DOD and Uniform Function Call Syntax (UFCS)

Data-Oriented Design (DOD) strictly separates data (structs/entities) from logic (systems/functions). Philosophically, strict DOD practitioners often prefer functional call syntax (`system(data)`) to visually emphasize that data is passive and does not "own" behavior.

However, in `triad` (following the exact conventions established in `ec4x`), we adopt a **Pragmatic DOD** approach. Because Nim compiles `model.focusWindow(id)` into `focusWindow(model, id)` with zero memory or structural difference, we retain 100% of the DOD cache-locality and performance benefits while gaining significant developer ergonomics.

Therefore, **we strictly use Nim's UFCS (dot syntax) for system logic.**

### The Convention:
1.  **First Parameter:** Systems and helper procs that operate on state must define the primary state struct (e.g., `Model`, `EntityManager`) as their **first parameter**.
2.  **Dot Syntax:** Always invoke these procs using the dot (`.`) syntax.

### Examples:

**Defining Logic (System Layer):**
```nim
# The model/state is always the first parameter
proc focusWindow*(model: var Model, winId: WindowId) =
  # implementation...

proc shellOutputName*(model: Model, outputId: OutputId): string =
  # implementation...
```

**Invoking Logic:**
```nim
# BAD: Breaks left-to-right reading flow
focusWindow(model, winId)
let name = shellOutputName(model, outputId)

# GOOD: Strict UFCS usage
model.focusWindow(winId)
let name = model.shellOutputName(outputId)
```

### Why We Use UFCS:
*   **Readability:** `model.windows.entity(winId)` reads naturally left-to-right (State -> Sub-Collection -> Action).
*   **Chaining:** Enables fluent API design without deep nesting: `model.findWindow(id).get().title` vs `get(findWindow(model, id)).title`.
*   **Discoverability:** Typing `model.` in an LSP-enabled editor instantly lists all applicable systems and queries that can act upon the state.

---

## 3. EntityManager Access and Performance

When querying the `EntityManager`, we must prioritize single-lookup performance. Using a "double lookup" pattern is strictly forbidden.

### The Double Lookup Anti-Pattern
Checking for existence and then retrieving the entity results in two separate hash table operations.

```nim
# BAD: Double lookup, non-NEP-1 naming
if model.outputs.hasEntity(outputId):             # Lookup 1
  let output = model.outputs.getEntity(outputId)  # Lookup 2
```

### The `Option[T]` Standard
To prevent double lookups, the primary retrieval function must be named `entity` (NEP-1 compliant) and return an `Option[T]`.

```nim
# GOOD: Single lookup, NEP-1 compliant
import std/options

let outputOpt = model.outputs.entity(outputId)    # Single lookup
if outputOpt.isSome():
  let output = outputOpt.get()
  # ...
```

### Mutating Entities (Var Fetching)
If you are certain an entity exists and need to mutate it in place without extracting the `Option`, use the mutating prefix `m` (e.g., `mEntity`) to return a `var` reference directly from the known index.

```nim
# For guaranteed in-place mutation:
proc mEntity*[ID, T](manager: var EntityManager[ID, T]; id: ID): var T =
  manager.data[manager.index[id]]
```
