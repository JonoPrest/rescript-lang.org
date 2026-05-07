// Demo 3 — native ReScript tag function.
// No @taggedTemplate decorator: this is just a regular function with the
// tag-function signature, used with the backtick syntax.
type params =
  | I(int)
  | S(string)

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

let name = "Ada"
let age = 36
let greeting = s`hello ${S(name)} you're ${I(age)} years old!`
