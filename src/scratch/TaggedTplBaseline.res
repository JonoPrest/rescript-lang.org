// Demo 1 (baseline) — @taggedTemplate on a directly-exported tag function.
// Mirrors the official docs example for `bun`.
type result = {exitCode: int}

@module("bun") @taggedTemplate
external sh: (array<string>, array<string>) => promise<result> = "$"

let filename = "index.res"

let run = async () => {
  let _result = await sh`ls ${filename}`
}
