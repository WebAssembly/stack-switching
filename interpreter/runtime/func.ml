open Types
open Value

type 'inst t = 'inst func
and 'inst func =
  | AstFunc of deftype * 'inst * Ast.func
  | HostFunc of deftype * (value list -> value list)
  | ClosureFunc of deftype * 'inst func * value list

let alloc dt inst f =
  ignore (functype_of_comptype (expand_deftype dt));
  assert Free.((deftype dt).types = Set.empty);
  AstFunc (dt, inst, f)

let alloc_host dt f =
  ignore (functype_of_comptype (expand_deftype dt));
  HostFunc (dt, f)

let alloc_closure dt func vs =
  ignore (functype_of_comptype (expand_deftype dt));
  ClosureFunc (dt, func, vs)

let type_of = function
  | AstFunc (dt, _, _) -> dt
  | HostFunc (dt, _) -> dt
  | ClosureFunc (dt, _, _) -> dt
