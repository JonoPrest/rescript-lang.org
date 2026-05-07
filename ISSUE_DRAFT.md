# Tagged template literals: limitations & proposed alternative

## Background

ReScript v11.1 introduced two related mechanisms for working with JavaScript tagged template literals:

1. **Native ReScript tag functions** — any function with the signature `(array<string>, array<'param>) => 'output` can be used with backtick syntax. The compiler emits a **plain function call**.
2. **`@taggedTemplate` decorator on `external`** — for binding to JS tag functions. The compiler emits **real JS tagged-template syntax** at call sites, so JS-side tooling that introspects the literal (e.g. `gql`, `sql`, `css`, prettier plugins, syntax highlighting) keeps working.

In practice, several real-world JS libraries — most notably [`postgres`](https://github.com/porsager/postgres) — cannot be used through either mechanism without hitting fundamental limitations. This issue documents those limitations with reproducible examples and proposes an alternative.

> All compiled-JS snippets below are emitted by the actual ReScript compiler (v12.2.0) from the `.res` files in `src/scratch/` of this branch.

---

## Problem 1 — Cannot bind to a tag function that is constructed at runtime

The `postgres` library does not export a tag function. You construct a client by calling the default export, and the returned value _is_ the tag function:

```js
import postgres from "postgres";
const sql = postgres(process.env.DATABASE_URL);
const users = await sql`SELECT * FROM users WHERE id = ${userId}`;
```

`@taggedTemplate` requires an `external` binding, which can only point at a **statically-exported** value (`@module(...) ... = "name"` or `@val ... = "name"`). There is no syntax for "the result of calling this function is a tagged-template tag", so a direct binding to `postgres` is impossible.

---

## Problem 2 — The "re-export from raw JS" workaround silently breaks across module boundaries

A common workaround is to construct the client in a small JS file and re-export it under a static name, then bind to that:

```js
// sql_client.js — stand-in for: export const sql = postgres(process.env.DATABASE_URL)
const makeClient = () => {
  return (strings, ...values) => ({ strings, values });
};

export const sql = makeClient();
```

```res
// SqlBinding.res
type queryResult = {rows: array<string>}

@module("./sql_client.js") @taggedTemplate
external sql: (array<string>, array<'a>) => promise<queryResult> = "sql"
```

### 2a. Same-module usage works

```res
// TaggedTplReExport.res
let userId = 42

let run = async () => {
  let _users = await sql`SELECT * FROM users WHERE id = ${userId}`
}
```

Compiled JS (`src/scratch/TaggedTplReExport.jsx`):

```js
import * as Sql_clientJs from "./sql_client.js";

function sql(prim0, prim1) {
  return Sql_clientJs.sql(prim0, ...prim1);
}

async function run() {
  await Sql_clientJs.sql`SELECT * FROM users WHERE id = ${42}`;
}
```

✅ The call site on line 10 is a real tagged-template literal — `postgres` would accept it.

But notice lines 5–7: the compiler also emits a **wrapper function** that does a variadic spread (`Sql_clientJs.sql(prim0, ...prim1)`). This wrapper is what gets exported as `sql`. It is **not** a tagged-template invocation. Anything that imports `sql` from this module gets the wrapper, not the original tag.

### 2b. Cross-module usage silently falls back to a plain function call

The realistic setup for `postgres` is one file that constructs the client and many files that consume it:

```res
// TaggedTplCrossModule.res
let userId = 7

let run = async () => {
  let _ = await SqlBinding.sql`SELECT * FROM users WHERE id = ${userId}`
}
```

Compiled JS (`src/scratch/TaggedTplCrossModule.jsx`):

```js
import * as SqlBinding from "./SqlBinding.jsx";

async function run() {
  await SqlBinding.sql([`SELECT * FROM users WHERE id = `, ``], [7]);
}
```

❌ This is **not** a tagged template literal — it is a regular function call with two array arguments. `postgres` enforces tagged-template invocation (it relies on `strings.raw` and identity caching of the `TemplateStringsArray`) and will reject this at runtime.

The compiler can only emit real tagged-template syntax when the `@taggedTemplate` external is **in scope as the external itself**. Once the binding is exported from its defining module and re-imported, the consumer only sees the wrapper, and every call site degrades to a plain function call.

### 2c. Other ways the tag loses its semantics

The same degradation happens whenever the tag flows through any value-level boundary, even within a single module:

```res
// TaggedTplVariations.res
let runThroughParam = async (tag) => {
  let _ = await tag`SELECT * FROM users WHERE id = ${userId}`
}

let runViaCallback = async () => {
  await runThroughParam(sql)
}
```

Compiled JS:

```js
async function runThroughParam(tag) {
  await tag([`SELECT * FROM users WHERE id = `, ``], [42]);
}

async function runViaCallback() {
  return await runThroughParam(sql); // <- passes the wrapper, not the real tag
}
```

The moment `sql` is passed as a value, it becomes the wrapper, and any downstream call uses the variadic-spread form. There is no way to "carry" tagged-template semantics across an abstraction boundary.

---

## Problem 3 — Native ReScript tag functions never emit tagged-template syntax

For completeness: a tag function defined in pure ReScript (no `@taggedTemplate` decorator) **always** compiles to a plain function call, regardless of how it is invoked.

```res
// TaggedTplNative.res
type params = I(int) | S(string)

let s = (strings, parameters) => {
  Array.reduceWithIndex(parameters, Array.getUnsafe(strings, 0), (acc, param, i) => {
    let suffix = Array.getUnsafe(strings, i + 1)
    let p = switch param {
    | I(i) => Int.toString(i)
    | S(s) => s
    }
    acc ++ p ++ suffix
  })
}

let greeting = s`hello ${S("Ada")} you're ${I(36)} years old!`
```

Compiled JS:

```js
let greeting = s(
  [`hello `, ` you're `, ` years old!`],
  [
    { TAG: "S", _0: "Ada" },
    { TAG: "I", _0: 36 },
  ],
);
```

This means a ReScript-authored wrapper around `postgres` (e.g. one that converts typed parameters into the right shape before delegating) cannot itself be used as a tag for the underlying library.

---

## Summary of limitations

| #   | Limitation                                                                                   | Consequence                                                                                                                                                        |
| --- | -------------------------------------------------------------------------------------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------ |
| 1   | `@taggedTemplate` requires a static export                                                   | Cannot bind to libraries whose tag is constructed at runtime (`postgres`, any factory-returning-tag pattern).                                                      |
| 2   | The "re-export from raw JS" workaround emits a wrapper that loses tagged-template semantics. | Cross-module usage and any first-class use of the tag silently degrades to a plain function call, breaking libraries that require real tagged-template invocation. |
| 3   | Native ReScript tag functions never emit tagged-template syntax.                             | Cannot author a typed ReScript wrapper around a JS tag function.                                                                                                   |
| 4   | Placeholders are a single homogeneous `array<'param>`.                                       | Mixed-type interpolation requires a wrapper variant at every call site.                                                                                            |

---

## Proposed alternative — make "tagged template tag" a first-class type

The root cause of every limitation above is that "tagged-templateness" lives on the **binding site** (`@taggedTemplate` on an `external`) rather than on the **type** of the value. As soon as the value is referenced through any indirection — exported, imported, aliased, passed as a parameter, returned from a factory — the compiler loses track of it and falls back to a plain function call.

The proposal is to make tagged-template-ness a property of the **type** itself, so that the compiler can track it through:

- module imports/exports
- `let` aliases
- function parameters and return types
- record / variant fields
- runtime-constructed values (the `postgres` case)

…and emit real JS tagged-template syntax at _every_ call site that uses backtick syntax with such a value, no matter where the value came from.

### Sketch (open for discussion)

Two possible surfaces for the same underlying idea:

**A. A new type constructor**

```res
// Built-in type that the compiler treats specially.
type taggedTemplate<'param, 'output>

// Bindings drop the decorator; the type carries the meaning.
@module("./sql_client.js")
external sql: taggedTemplate<'a, promise<queryResult>> = "sql"

// Runtime construction (the postgres case) becomes expressible:
@module("postgres") external postgres: string => taggedTemplate<'a, promise<queryResult>> = "default"
let sql = postgres(connectionString)
```

**B. A type-level annotation that propagates**

```res
let sql: @taggedTemplate (array<string>, array<'a>) => promise<queryResult> = ...
```

Either form would let users write things like:

```res
// A function that accepts a tag and uses it — emits real tl syntax inside.
let findUser = async (sql: taggedTemplate<int, promise<queryResult>>, id) => {
  await sql`SELECT * FROM users WHERE id = ${id}`
}

// Cross-module use — also emits real tl syntax.
await SqlBinding.sql`SELECT * FROM users WHERE id = ${userId}`
```

### Compiler obligations

For a value `v` whose static type is the tagged-template type:

1. **Every** `` v`...` `` call site emits a real JS tagged template literal — never a plain function call, regardless of where `v` was bound or how many module/function boundaries it crossed.
2. The compiler does **not** emit a "wrapper function" that does variadic spread for these values. The exported binding is the underlying JS value itself.
3. Calling `v` as a regular function (`v(strings, params)`) is either rejected at type-check time or also emits tagged-template syntax (matching today's same-module behavior).
4. Type-checking still enforces the placeholder/output types end-to-end.

### Why this fixes the listed problems

| Problem                                  | How the proposal addresses it                                                                                   |
| ---------------------------------------- | --------------------------------------------------------------------------------------------------------------- |
| 1 — runtime-constructed tags             | Expressible: `postgres(...)` returns a `taggedTemplate<...>` and is usable directly.                            |
| 2a — wrapper-function leakage            | No wrapper emitted; the JS value is exported as-is.                                                             |
| 2b — cross-module degradation            | The type follows the value across modules, so call sites still emit tl syntax.                                  |
| 2c — first-class / pass-as-parameter use | Functions can declare `taggedTemplate<...>` parameters; the compiler emits tl syntax at call sites inside them. |
| 3 — ReScript-authored wrappers           | A ReScript function returning / forwarding a `taggedTemplate<...>` keeps its tl semantics.                      |

---

## Reproduction

All examples in this document are compiled by the current ReScript toolchain on this branch. The source `.res` files and the generated `.jsx` output live in `src/scratch/`:

| Source                                 | Compiled output                        |
| -------------------------------------- | -------------------------------------- |
| `src/scratch/TaggedTplBaseline.res`    | `src/scratch/TaggedTplBaseline.jsx`    |
| `src/scratch/SqlBinding.res`           | `src/scratch/SqlBinding.jsx`           |
| `src/scratch/TaggedTplReExport.res`    | `src/scratch/TaggedTplReExport.jsx`    |
| `src/scratch/TaggedTplCrossModule.res` | `src/scratch/TaggedTplCrossModule.jsx` |
| `src/scratch/TaggedTplVariations.res`  | `src/scratch/TaggedTplVariations.jsx`  |
| `src/scratch/TaggedTplNative.res`      | `src/scratch/TaggedTplNative.jsx`      |

Compiler version: `rescript 12.2.0`.
