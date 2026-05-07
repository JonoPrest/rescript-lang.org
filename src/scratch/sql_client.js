// Stand-in for the user's hack:
//   import postgres from "postgres"
//   export const sql = postgres(process.env.DATABASE_URL)
//
// We only care about the compiled JS shape, not running it. This exports
// a runtime-constructed tag function under the name `sql`.
const makeClient = () => {
  return (strings, ...values) => ({ strings, values });
};

export const sql = makeClient();
