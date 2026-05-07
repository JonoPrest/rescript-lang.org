type queryResult = {rows: array<string>}

@module("./sql_client.js") @taggedTemplate
external sql: (array<string>, array<'a>) => promise<queryResult> = "sql"
