// Demo 2 — the user's "re-export" workaround for `postgres`.
// `sql` is constructed at runtime in sql_client.js and re-exported.
// We bind via @taggedTemplate the same way as the bun example.
type queryResult = {rows: array<string>}

@module("./sql_client.js") @taggedTemplate
external sql: (array<string>, array<'a>) => promise<queryResult> = "sql"

let userId = 42

let run = async () => {
  let _users = await sql`SELECT * FROM users WHERE id = ${userId}`
}
