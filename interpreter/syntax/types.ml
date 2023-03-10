(* Generic Types *)

type type_idx = int32
type local_idx = int32
type name = Utf8.unicode

type null = NoNull | Null
type mut = Cons | Var
type init = Set | Unset
type 'a limits = {min : 'a; max : 'a option}

type type_addr = ..
type var = Stat of type_idx | Dyn of type_addr

type num_type = I32T | I64T | F32T | F64T
type vec_type = V128T
type heap_type = FuncHT | ExternHT | DefHT of var | BotHT
type ref_type = null * heap_type
type val_type = NumT of num_type | VecT of vec_type | RefT of ref_type | BotT

type result_type = val_type list
type instr_type = InstrT of result_type * result_type * local_idx list
type func_type = FuncT of result_type * result_type
type cont_type = ContT of var
type def_type = DefFuncT of func_type | DefContT of cont_type

type table_type = TableT of Int32.t limits * ref_type
type memory_type = MemoryT of Int32.t limits
type global_type = GlobalT of mut * val_type
type local_type = LocalT of init * val_type
type tag_type = TagT of var
type extern_type =
  | ExternFuncT of func_type
  | ExternTableT of table_type
  | ExternMemoryT of memory_type
  | ExternGlobalT of global_type
  | ExternTagT of tag_type

type export_type = ExportT of extern_type * name
type import_type = ImportT of extern_type * name * name
type module_type =
  | ModuleT of def_type list * import_type list * export_type list


(* Attributes *)

let num_size : num_type -> int = function
  | I32T | F32T -> 4
  | I64T | F64T -> 8

let vec_size : vec_type -> int = function
  | V128T -> 16

let is_num_type : val_type -> bool = function
  | NumT _ | BotT -> true
  | _ -> false

let is_vec_type : val_type -> bool = function
  | VecT _ | BotT -> true
  | _ -> false

let is_ref_type : val_type -> bool = function
  | RefT _ | BotT -> true
  | _ -> false

let defaultable : val_type -> bool = function
  | NumT _ -> true
  | VecT _ -> true
  | RefT (nul, _) -> nul = Null
  | BotT -> assert false


(* Projections *)

let as_syn_var = function
  | SynVar x -> x
  | SemVar _ -> assert false

let as_sem_var = function
  | SynVar _ -> assert false
  | SemVar x -> x

let as_func_def_type (dt : def_type) : func_type =
  match dt with
  | DefFuncT ft -> ft
  | _ -> assert false

let as_cont_def_type (dt : def_type) : cont_type =
  match dt with
  | DefContT ct -> ct
  | _ -> assert false

let extern_type_of_import_type (ImportT (et, _, _)) = et
let extern_type_of_export_type (ExportT (et, _)) = et


(* Filters *)

let funcs (ets : extern_type list) : func_type list =
  Lib.List.map_filter (function ExternFuncT ft -> Some ft | _ -> None) ets
let tables (ets : extern_type list) : table_type list =
  Lib.List.map_filter (function ExternTableT tt -> Some tt | _ -> None) ets
let memories (ets : extern_type list) : memory_type list =
  Lib.List.map_filter (function ExternMemoryT mt -> Some mt | _ -> None) ets
let globals (ets : extern_type list) : global_type list =
  Lib.List.map_filter (function ExternGlobalT gt -> Some gt | _ -> None) ets
let tags (ets : extern_type list) : tag_type list =
  Lib.List.map_filter (function ExternTagT t -> Some t | _ -> None) ets

let string_of_extern_type : extern_type -> string = function
  | ExternFuncT ft -> "func " ^ string_of_func_type ft
  | ExternTableT tt -> "table " ^ string_of_table_type tt
  | ExternMemoryT mt -> "memory " ^ string_of_memory_type mt
  | ExternGlobalT gt -> "global " ^ string_of_global_type gt
  | ExternTagT t -> "tag " ^ string_of_tag_type t


let string_of_export_type : export_type -> string = function
  | ExportT (et, name) ->
    "\"" ^ string_of_name name ^ "\" : " ^ string_of_extern_type et

let string_of_import_type : import_type -> string = function
  | ImportT (et, module_name, name) ->
    "\"" ^ string_of_name module_name ^ "\" \"" ^
      string_of_name name ^ "\" : " ^ string_of_extern_type et

let string_of_module_type : module_type -> string = function
  | ModuleT (dts, its, ets) ->
    String.concat "" (
      List.mapi (fun i dt -> "type " ^ string_of_int i ^ " = " ^ string_of_def_type dt ^ "\n") dts @
      List.map (fun it -> "import " ^ string_of_import_type it ^ "\n") its @
      List.map (fun et -> "export " ^ string_of_export_type et ^ "\n") ets
    )

let string_of_tag_type (TagT x) = string_of_var x

let string_of_cont_type = function
  | ContT x -> string_of_var x

(* Dynamic Types *)

type type_addr += Addr of def_type Lib.Promise.t

let unwrap = function
  | Addr p -> p
  | _ -> assert false

let alloc_uninit () = Addr (Lib.Promise.make ())
let init x dt = Lib.Promise.fulfill (unwrap x) dt
let alloc dt = let x = alloc_uninit () in init x dt; x
let def_of x = Lib.Promise.value (unwrap x)

let () = string_of_addr' :=
  let inner = ref false in
  fun x ->
    if !inner then "..." else
    ( inner := true;
      try
        let s = string_of_def_type (def_of x) in
        inner := false; "(" ^ s ^ ")"
      with exn -> inner := false; raise exn
    )


(* Instantiation *)

let dyn_var_type c = function
  | Stat x -> Dyn (Lib.List32.nth c x)
  | Dyn a -> assert false

let dyn_num_type c = function
  | t -> t

let dyn_vec_type c = function
  | t -> t

let dyn_heap_type c = function
  | FuncHT -> FuncHT
  | ExternHT -> ExternHT
  | DefHT x -> DefHT (dyn_var_type c x)
  | BotHT -> BotHT

let dyn_ref_type c = function
  | (nul, t) -> (nul, dyn_heap_type c t)

let dyn_val_type c = function
  | NumT t -> NumT (dyn_num_type c t)
  | VecT t -> VecT (dyn_vec_type c t)
  | RefT t -> RefT (dyn_ref_type c t)
  | BotT -> BotT

let dyn_result_type c = function
  | ts -> List.map (dyn_val_type c) ts

let dyn_func_type c = function
  | FuncT (ts1, ts2) -> FuncT (dyn_result_type c ts1, dyn_result_type c ts2)

let dyn_cont_type c = function
  | ContT x -> ContT (dyn_var_type c x)

let dyn_def_type c = function
  | DefFuncT ft -> DefFuncT (dyn_func_type c ft)
  | DefContT x  -> DefContT (dyn_cont_type c x)

let dyn_local_type c = function
  | LocalT (init, t) -> LocalT (init, dyn_val_type c t)

let dyn_memory_type c = function
  | MemoryT lim -> MemoryT lim

let dyn_table_type c = function
  | TableT (lim, t) -> TableT (lim, dyn_ref_type c t)

let dyn_global_type c = function
  | GlobalT (mut, t) -> GlobalT (mut, dyn_val_type c t)

let dyn_tag_type c = function
  | TagT t -> TagT (dyn_var_type c t)

let dyn_extern_type c = function
  | ExternFuncT ft -> ExternFuncT (dyn_func_type c ft)
  | ExternTableT tt -> ExternTableT (dyn_table_type c tt)
  | ExternMemoryT mt -> ExternMemoryT (dyn_memory_type c mt)
  | ExternGlobalT gt -> ExternGlobalT (dyn_global_type c gt)
  | ExternTagT t -> ExternTagT (dyn_tag_type c t)

let dyn_export_type c = function
  | ExportT (et, name) -> ExportT (dyn_extern_type c et, name)

let dyn_import_type c = function
  | ImportT (et, module_name, name) ->
    ImportT (dyn_extern_type c et, module_name, name)

let dyn_module_type = function
  | ModuleT (dts, its, ets) ->
    let c = List.map (fun _ -> alloc_uninit ()) dts in
    List.iter2 (fun a dt -> init a (dyn_def_type c dt)) c dts;
    let its = List.map (dyn_import_type c) its in
    let ets = List.map (dyn_export_type c) ets in
    ModuleT ([], its, ets)
