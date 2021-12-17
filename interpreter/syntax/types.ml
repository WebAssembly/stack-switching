(* Types *)

type name = int list

and syn_var = int32
and sem_var = def_type Lib.Promise.t
and var = SynVar of syn_var | SemVar of sem_var

and nullability = NonNullable | Nullable
and num_type = I32Type | I64Type | F32Type | F64Type
and ref_type = nullability * heap_type
and heap_type =
  FuncHeapType | ExternHeapType | DefHeapType of var | BotHeapType

and value_type = NumType of num_type | RefType of ref_type | BotType
and result_type = value_type list
and func_type = FuncType of result_type * result_type
and cont_type = ContType of var
and def_type = FuncDefType of func_type | ContDefType of cont_type

type 'a limits = {min : 'a; max : 'a option}
type mutability = Immutable | Mutable
type resumability = Terminal | Resumable
type table_type = TableType of Int32.t limits * ref_type
type memory_type = MemoryType of Int32.t limits
type global_type = GlobalType of value_type * mutability
type tag_type = TagType of func_type * resumability  (* TODO: use index *)
type extern_type =
  | ExternFuncType of func_type
  | ExternTableType of table_type
  | ExternMemoryType of memory_type
  | ExternGlobalType of global_type
  | ExternTagType of tag_type

type export_type = ExportType of extern_type * name
type import_type = ImportType of extern_type * name * name
type module_type =
  ModuleType of def_type list * import_type list * export_type list

type pack_size = Pack8 | Pack16 | Pack32
type extension = SX | ZX


(* Attributes *)

let size = function
  | I32Type | F32Type -> 4
  | I64Type | F64Type -> 8

let packed_size = function
  | Pack8 -> 1
  | Pack16 -> 2
  | Pack32 -> 4

let is_syn_var = function SynVar _ -> true | SemVar _ -> false
let is_sem_var = function SemVar _ -> true | SynVar _ -> false

let is_num_type = function
  | NumType _ | BotType -> true
  | RefType _ -> false

let is_ref_type = function
  | NumType _ -> false
  | RefType _ | BotType -> true

let defaultable_num_type = function
  | _ -> true

let defaultable_ref_type = function
  | (nul, _) -> nul = Nullable

let defaultable_value_type = function
  | NumType t -> defaultable_num_type t
  | RefType t -> defaultable_ref_type t
  | BotType -> assert false


(* Projections *)

let as_syn_var = function
  | SynVar x -> x
  | SemVar _ -> assert false

let as_sem_var = function
  | SynVar _ -> assert false
  | SemVar x -> x

let as_func_def_type (dt : def_type) : func_type =
  match dt with
  | FuncDefType ft -> ft
  | _ -> assert false

let as_cont_def_type (dt : def_type) : cont_type =
  match dt with
  | ContDefType ct -> ct
  | _ -> assert false

let extern_type_of_import_type (ImportType (et, _, _)) = et
let extern_type_of_export_type (ExportType (et, _)) = et


(* Filters *)

let funcs =
  Lib.List.map_filter (function ExternFuncType t -> Some t | _ -> None)
let tables =
  Lib.List.map_filter (function ExternTableType t -> Some t | _ -> None)
let memories =
  Lib.List.map_filter (function ExternMemoryType t -> Some t | _ -> None)
let globals =
  Lib.List.map_filter (function ExternGlobalType t -> Some t | _ -> None)
let tags =
  Lib.List.map_filter (function ExternTagType t -> Some t | _ -> None)


(* Allocation *)

let alloc_uninit () = Lib.Promise.make ()
let init p dt = Lib.Promise.fulfill p dt
let alloc dt = let p = alloc_uninit () in init p dt; p

let def_of x = Lib.Promise.value x


(* Conversion *)

let sem_var_type c = function
  | SynVar x -> SemVar (Lib.List32.nth c x)
  | SemVar _ -> assert false

let sem_num_type c t = t

let sem_heap_type c = function
  | FuncHeapType -> FuncHeapType
  | ExternHeapType -> ExternHeapType
  | DefHeapType x -> DefHeapType (sem_var_type c x)
  | BotHeapType -> BotHeapType

let sem_ref_type c = function
  | (nul, t) -> (nul, sem_heap_type c t)

let sem_value_type c = function
  | NumType t -> NumType (sem_num_type c t)
  | RefType t -> RefType (sem_ref_type c t)
  | BotType -> BotType

let sem_stack_type c ts =
 List.map (sem_value_type c) ts


let sem_memory_type c (MemoryType lim) =
  MemoryType lim

let sem_table_type c (TableType (lim, t)) =
  TableType (lim, sem_ref_type c t)

let sem_global_type c (GlobalType (t, mut)) =
  GlobalType (sem_value_type c t, mut)

let sem_func_type c (FuncType (ins, out)) =
  FuncType (sem_stack_type c ins, sem_stack_type c out)

let sem_cont_type c (ContType x) =
  ContType (sem_var_type c x)

let sem_tag_type c (TagType (ft, res)) =
  TagType (sem_func_type c ft, res)

let sem_extern_type c = function
  | ExternFuncType ft -> ExternFuncType (sem_func_type c ft)
  | ExternTableType tt -> ExternTableType (sem_table_type c tt)
  | ExternMemoryType mt -> ExternMemoryType (sem_memory_type c mt)
  | ExternGlobalType gt -> ExternGlobalType (sem_global_type c gt)
  | ExternTagType et -> ExternTagType (sem_tag_type c et)


let sem_def_type c = function
  | FuncDefType ft -> FuncDefType (sem_func_type c ft)
  | ContDefType ct -> ContDefType (sem_cont_type c ct)


let sem_export_type c (ExportType (et, name)) =
  ExportType (sem_extern_type c et, name)

let sem_import_type c (ImportType (et, module_name, name)) =
  ImportType (sem_extern_type c et, module_name, name)

let sem_module_type (ModuleType (dts, its, ets)) =
  let c = List.map (fun _ -> alloc_uninit ()) dts in
  List.iter2 (fun x dt -> init x (sem_def_type c dt)) c dts;
  let its = List.map (sem_import_type c) its in
  let ets = List.map (sem_export_type c) ets in
  ModuleType ([], its, ets)


(* String conversion *)

let string_of_name n =
  let b = Buffer.create 16 in
  let escape uc =
    if uc < 0x20 || uc >= 0x7f then
      Buffer.add_string b (Printf.sprintf "\\u{%02x}" uc)
    else begin
      let c = Char.chr uc in
      if c = '\"' || c = '\\' then Buffer.add_char b '\\';
      Buffer.add_char b c
    end
  in
  List.iter escape n;
  Buffer.contents b

let rec string_of_var =
  let inner = ref false in
  function
  | SynVar x -> I32.to_string_u x
  | SemVar x ->
    if !inner then "..." else
    ( inner := true;
      try
        let s = string_of_def_type (def_of x) in
        inner := false; "(" ^ s ^ ")"
      with exn -> inner := false; raise exn
    )

and string_of_nullability = function
  | NonNullable -> ""
  | Nullable -> "null "

and string_of_num_type = function
  | I32Type -> "i32"
  | I64Type -> "i64"
  | F32Type -> "f32"
  | F64Type -> "f64"

and string_of_heap_type = function
  | FuncHeapType -> "func"
  | ExternHeapType -> "extern"
  | DefHeapType x -> string_of_var x
  | BotHeapType -> "something"

and string_of_ref_type = function
  | (nul, t) ->
    "(ref " ^ string_of_nullability nul ^ string_of_heap_type t ^ ")"

and string_of_value_type = function
  | NumType t -> string_of_num_type t
  | RefType t -> string_of_ref_type t
  | BotType -> "(something)"

and string_of_result_type ts =
  "[" ^ String.concat " " (List.map string_of_value_type ts) ^ "]"

and string_of_func_type = function
  | FuncType (ins, out) ->
    string_of_result_type ins ^ " -> " ^ string_of_result_type out

and string_of_cont_type = function
  | ContType x -> string_of_var x

and string_of_def_type = function
  | FuncDefType ft -> "func " ^ string_of_func_type ft
  | ContDefType ct -> "cont " ^ string_of_cont_type ct


let string_of_limits {min; max} =
  I32.to_string_u min ^
  (match max with None -> "" | Some n -> " " ^ I32.to_string_u n)

let string_of_memory_type = function
  | MemoryType lim -> string_of_limits lim

let string_of_table_type = function
  | TableType (lim, t) -> string_of_limits lim ^ " " ^ string_of_ref_type t

let string_of_global_type = function
  | GlobalType (t, Immutable) -> string_of_value_type t
  | GlobalType (t, Mutable) -> "(mut " ^ string_of_value_type t ^ ")"

let string_of_tag_type = function
  | TagType (ft, Terminal) -> "exception " ^ string_of_func_type ft
  | TagType (ft, Resumable) -> string_of_func_type ft

let string_of_extern_type = function
  | ExternFuncType ft -> "func " ^ string_of_func_type ft
  | ExternTableType tt -> "table " ^ string_of_table_type tt
  | ExternMemoryType mt -> "memory " ^ string_of_memory_type mt
  | ExternGlobalType gt -> "global " ^ string_of_global_type gt
  | ExternTagType et -> "tag " ^ string_of_tag_type et

let string_of_export_type (ExportType (et, name)) =
  "\"" ^ string_of_name name ^ "\" : " ^ string_of_extern_type et

let string_of_import_type (ImportType (et, module_name, name)) =
  "\"" ^ string_of_name module_name ^ "\" \"" ^
    string_of_name name ^ "\" : " ^ string_of_extern_type et

let string_of_module_type (ModuleType (dts, its, ets)) =
  String.concat "" (
    List.mapi (fun i dt -> "type " ^ string_of_int i ^ " = " ^ string_of_def_type dt ^ "\n") dts @
    List.map (fun it -> "import " ^ string_of_import_type it ^ "\n") its @
    List.map (fun et -> "export " ^ string_of_export_type et ^ "\n") ets
  )
