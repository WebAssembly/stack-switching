open Types
open Value

type 'inst t = 'inst func
and 'inst func =
  | AstFunc of deftype * 'inst * Ast.func
  | HostFunc of deftype * (value list -> value list)
  | ClosureFunc of deftype * 'inst func * value list

val alloc : deftype -> 'inst -> Ast.func -> 'inst func
val alloc_host : deftype -> (value list -> value list) -> 'inst func
val alloc_closure : deftype -> 'inst func -> value list -> 'inst func

val type_of : 'inst func -> deftype
