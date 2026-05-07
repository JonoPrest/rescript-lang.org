# Tagged template literals: limitations & proposed alternative

## Background

ReScript v11.1 introduced two mechanisms for working with JavaScript tagged template literals:

1. **Native ReScript tag functions** — any function with the signature `(array<string>, array<'param>) => 'output` can be used with backtick syntax. Compiles to a **plain function call**.
2. **`@taggedTemplate` decorator on `external`** — for binding to JS tag functions. Compiles to **real JS tagged-template syntax** at call sites, so JS-side tooling that introspects the literal (`gql`, `sql`, `css`, prettier plugins, syntax highlighting) keeps working.

Several real-world JS libraries — most notably [`postgres`](https://github.com/porsager/postgres) — cannot be used through either mechanism. This issue documents the limitations and proposes an alternative.

---

## Problem 1 — Cannot bind to a tag function constructed at runtime

`postgres` does not export a tag function. The default export is a factory; the value it returns _is_ the tag:

```js
import postgres from "postgres";
const sql = postgres(process.env.DATABASE_URL);
const users = await sql`SELECT * FROM users WHERE id = ${userId}`;
```

`@taggedTemplate` only attaches to `external` bindings, which point at statically-exported names. There is no syntax for "this runtime value is a tagged-template tag", so `postgres` cannot be bound directly.

---

## Problem 2 — The "re-export from raw JS" workaround silently breaks

The usual workaround is to construct the client in a small JS file under a static export, and bind to that:

```js
// sql_client.js
import postgres from "postgres";
export const sql = postgres(process.env.DATABASE_URL);
```

```res
type queryResult = {rows: array<string>}

@module("./sql_client.js") @taggedTemplate
external sql: (array<string>, array<'a>) => promise<queryResult> = "sql"
```

### 2a. Same-module usage works

```res
let run = async () => {
  let _ = await sql`SELECT * FROM users WHERE id = ${userId}`
}
```

Compiled JS:

```js
import * as Sql_clientJs from "./sql_client.js";

function sql(prim0, prim1) {
  return Sql_clientJs.sql(prim0, ...prim1);
}

async function run() {
  await Sql_clientJs.sql`SELECT * FROM users WHERE id = ${42}`;
}
```

The call site emits a real tagged-template literal. But the compiler also emits a **wrapper** (`function sql`) that does a variadic spread, and **that wrapper is what gets exported**. Anything importing `sql` from this module gets the wrapper, not the tag.

### 2b. Cross-module usage falls back to a plain function call

```res
// In some other module
let run = async () => {
  let _ = await SqlBinding.sql`SELECT * FROM users WHERE id = ${userId}`
}
```

Compiled JS:

```js
import * as SqlBinding from "./SqlBinding.jsx";

async function run() {
  await SqlBinding.sql([`SELECT * FROM users WHERE id = `, ``], [7]);
}
```

This is **not** a tagged template literal. `postgres` enforces tagged-template invocation (it relies on `strings.raw` and identity caching of the `TemplateStringsArray`) and rejects this at runtime.

The compiler can only emit real tl syntax when the `@taggedTemplate` external is in scope **as the external itself**. Once it crosses a module boundary, the consumer only sees the wrapper.

### 2c. Same problem when the tag flows through any value

```res
let runThroughParam = async tag => {
  let _ = await tag`SELECT * FROM users WHERE id = ${userId}`
}
runThroughParam(sql)
```

Compiled JS:

```js
async function runThroughParam(tag) {
  await tag([`SELECT * FROM users WHERE id = `, ``], [42]);
}
```

The moment the tag is passed as a value, every downstream call uses variadic spread.

---

## Problem 3 — Native ReScript tag functions never emit tl syntax

A tag function defined in pure ReScript (no decorator) always compiles to a plain function call:

```res
let s = (strings, parameters) => { /* ... */ }
let greeting = s`hello ${S("Ada")} you're ${I(36)} years old!`
```

```js
let greeting = s(
  [`hello `, ` you're `, ` years old!`],
  [
    { TAG: "S", _0: "Ada" },
    { TAG: "I", _0: 36 },
  ],
);
```

So a ReScript-authored wrapper around `postgres` (e.g. one converting typed parameters before delegating) cannot itself be used as a tag.

---

## Summary

| #   | Limitation                                                        | Consequence                                                                         |
| --- | ----------------------------------------------------------------- | ----------------------------------------------------------------------------------- |
| 1   | `@taggedTemplate` requires a static export.                       | Cannot bind to factory-returning-tag libraries (`postgres` and similar).            |
| 2   | The re-export workaround emits a wrapper that loses tl semantics. | Cross-module use and any first-class use silently degrade to a plain function call. |
| 3   | Native ReScript tag functions never emit tl syntax.               | Cannot author a typed ReScript wrapper around a JS tag function.                    |

---

## Proposed alternative — make "tagged-template tag" a first-class type

The root cause of every limitation above is that tagged-templateness lives on the **binding site** rather than the **type** of the value. The moment the value is exported, imported, aliased, passed as a parameter, or returned from a factory, the compiler loses track of it.

The proposal is to make tagged-templateness a property of the **type** itself, so the compiler tracks it through module boundaries, `let` aliases, function parameters and return types, record/variant fields, and runtime-constructed values — and emits real JS tagged-template syntax at _every_ call site that uses backtick syntax with such a value.

### Sketch

A new abstract type in the standard library — `TaggedTemplate.t<'param, 'output>` — that the compiler treats specially. Putting it under a stdlib module (the same way `Promise.t<'a>` lives under `Promise`) keeps it out of the global namespace:

```res
@module("./sql_client.js")
external sql: TaggedTemplate.t<'a, promise<queryResult>> = "sql"

// Runtime construction becomes expressible:
@module("postgres")
external postgres: string => TaggedTemplate.t<'a, promise<queryResult>> = "default"

let sql = postgres(connectionString)
```

Because it is a real type, it composes naturally — it can be written in function signatures, returned from factories, stored in records, etc.:

```res
// Cross-module use still emits tl syntax:
await SqlBinding.sql`SELECT * FROM users WHERE id = ${userId}`

// Functions accepting a tag use tl syntax inside:
let findUser = async (sql: TaggedTemplate.t<int, promise<queryResult>>, id) => {
  await sql`SELECT * FROM users WHERE id = ${id}`
}
```

### Compiler obligations

For a value `v` whose static type is the tagged-template type:

1. Every `` v`...` `` call site emits a real JS tagged template literal — regardless of how many module/function boundaries `v` crossed.
2. No variadic-spread wrapper is generated; the JS value is exported as-is.
3. Calling `v` as a regular function (`v(strings, params)`) is either rejected at type-check time or compiles to tl syntax.
4. Placeholder and output types are still type-checked end-to-end.

### Why this fixes everything above

| Problem                                  | How the proposal addresses it                                               |
| ---------------------------------------- | --------------------------------------------------------------------------- |
| 1 — runtime-constructed tags             | `postgres(...)` returns a `TaggedTemplate.t<...>` and is usable directly.   |
| 2a — wrapper-function leakage            | No wrapper emitted; JS value exported as-is.                                |
| 2b — cross-module degradation            | Type follows the value across modules; call sites emit tl syntax.           |
| 2c — first-class / pass-as-parameter use | Functions declare `TaggedTemplate.t<...>` parameters; tl syntax preserved.  |
| 3 — ReScript-authored wrappers           | A ReScript function returning a `TaggedTemplate.t<...>` keeps tl semantics. |
