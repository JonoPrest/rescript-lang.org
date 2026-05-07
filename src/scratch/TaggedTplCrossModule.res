// Use the tag from another module (the realistic postgres setup:
// one file constructs the client, every other file imports it).
let userId = 7

let run = async () => {
  let _ = await SqlBinding.sql`SELECT * FROM users WHERE id = ${userId}`
}
