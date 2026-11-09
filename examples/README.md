# Example corpus

Each program is self-contained. Its matching `.out` is exact UTF-8 stdout;
print built-ins do not add newlines. All 16 programs run through AST/IR/native
Wasm and browser Wasm tests. Outputs are compared byte-for-byte, without trimming.

| Program | Coverage |
| --- | --- |
| `01_hello` | Hello world and explicit newline |
| `02_arithmetic` | Precedence, negative division and remainder |
| `03_booleans` | Booleans, conditional expressions, short-circuit safety |
| `04_strings` | Concatenation, quotes, tab, backslash escapes |
| `05_unit_and_sequence` | Unit arguments/bindings and ordered effects |
| `06_let_and_shadowing` | Nested lets and non-recursive shadowing |
| `07_factorial` | Recursive function |
| `08_mutual_recursion` | Top-level and local mutually recursive groups |
| `09_closures` | Lexical capture across later shadowing |
| `10_higher_order` | First-class functions, composition, partial application |
| `11_polymorphic_tuples` | Let polymorphism and tuple parameter patterns |
| `12_options` | User-defined parametric options |
| `13_nested_patterns` | Nested variants/tuples, literals and wildcards |
| `14_variant_tree` | Recursive trees and two-parameter result types |
| `15_list_library` | User-defined lists with map, filter, left fold |
| `interpreter` | Arithmetic-expression interpreter and pretty-printer written in Tern |
