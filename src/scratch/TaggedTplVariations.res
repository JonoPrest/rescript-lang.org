// Probing when @taggedTemplate falls back to a plain (variadic) call.
type queryResult = {rows: array<string>}

@module("./sql_client.js") @taggedTemplate
external sql: (array<string>, array<'a>) => promise<queryResult> = "sql"

let userId = 42

// Variation A — direct call site (expected: real tagged template literal)
let runDirect = async () => {
  let _ = await sql`SELECT * FROM users WHERE id = ${userId}`
}

// Variation B — alias the tag through a let binding, then use it
let runAliased = async () => {
  let mySql = sql
  let _ = await mySql`SELECT * FROM users WHERE id = ${userId}`
}

// Variation C — pass the tag through a function parameter
let runThroughParam = async tag => {
  let _ = await tag`SELECT * FROM users WHERE id = ${userId}`
}

let runViaCallback = async () => {
  await runThroughParam(sql)
}

// Variation D — partial / first-class use (call as a regular function)
let runAsFunction = async () => {
  let _ = await sql(["SELECT * FROM users WHERE id = ", ""], [userId])
}
