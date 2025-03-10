open Source
open Ast
open Types

module Set = Set.Make(Int32)

type t =
{
  types : Set.t;
  globals : Set.t;
  tables : Set.t;
  memories : Set.t;
  tags : Set.t;
  funcs : Set.t;
  elems : Set.t;
  datas : Set.t;
  locals : Set.t;
  labels : Set.t;
}

let empty : t =
{
  types = Set.empty;
  globals = Set.empty;
  tables = Set.empty;
  memories = Set.empty;
  tags = Set.empty;
  funcs = Set.empty;
  elems = Set.empty;
  datas = Set.empty;
  locals = Set.empty;
  labels = Set.empty;
}

let union (s1 : t) (s2 : t) : t =
{
  types = Set.union s1.types s2.types;
  globals = Set.union s1.globals s2.globals;
  tables = Set.union s1.tables s2.tables;
  memories = Set.union s1.memories s2.memories;
  tags = Set.union s1.tags s2.tags;
  funcs = Set.union s1.funcs s2.funcs;
  elems = Set.union s1.elems s2.elems;
  datas = Set.union s1.datas s2.datas;
  locals = Set.union s1.locals s2.locals;
  labels = Set.union s1.labels s2.labels;
}

let types s = {empty with types = s}
let globals s = {empty with globals = s}
let tables s = {empty with tables = s}
let memories s = {empty with memories = s}
let tags s = {empty with tags = s}
let funcs s = {empty with funcs = s}
let elems s = {empty with elems = s}
let datas s = {empty with datas = s}
let locals s = {empty with locals = s}
let labels s = {empty with labels = s}

let idx' x' = Set.singleton x'
let idx x = Set.singleton x.it
let shift s = Set.map (Int32.add (-1l)) (Set.remove 0l s)

let (++) = union
let opt free xo = Lib.Option.get (Option.map free xo) empty
let list free xs = List.fold_left union empty (List.map free xs)

let var_type = function
  | StatX x -> types (idx' x)
  | RecX _ -> empty

let num_type = function
  | I32T | I64T | F32T | F64T -> empty

let vec_type = function
  | V128T -> empty

let heap_type = function
  | AnyHT | NoneHT | EqHT
  | I31HT | StructHT | ArrayHT -> empty
  | FuncHT | NoFuncHT -> empty
  | ExnHT | NoExnHT -> empty
  | ExternHT | NoExternHT -> empty
  | ContHT | NoContHT -> empty
  | VarHT x -> var_type x
  | DefHT _ct -> empty  (* assume closed *)
  | BotHT -> empty

let ref_type = function
  | (_, t) -> heap_type t

let val_type = function
  | NumT t -> num_type t
  | VecT t -> vec_type t
  | RefT t -> ref_type t
  | BotT -> empty

(* let func_type (FuncT (ins, out)) = list val_type ins ++ list val_type out *)
let cont_type (ContT ht) = heap_type ht

let pack_type t = empty

let storage_type = function
  | ValStorageT t -> val_type t
  | PackStorageT t -> pack_type t

let field_type (FieldT (_mut, st)) = storage_type st

let struct_type (StructT fts) = list field_type fts
let array_type (ArrayT ft) = field_type ft
let func_type (FuncT (ts1, ts2)) = list val_type ts1 ++ list val_type ts2

let str_type = function
  | DefStructT st -> struct_type st
  | DefArrayT at -> array_type at
  | DefFuncT ft -> func_type ft
  | DefContT ct -> cont_type ct

let sub_type = function
  | SubT (_fin, hts, st) -> list heap_type hts ++ str_type st

let rec_type = function
  | RecT sts -> list sub_type sts

let def_type = function
  | DefT (rt, _i) -> rec_type rt

let global_type (GlobalT (_mut, t)) = val_type t
let table_type (TableT (_at, _lim, t)) = ref_type t
let memory_type (MemoryT (_at, _lim)) = empty
let tag_type (TagT dt) = def_type dt

let extern_type = function
  | ExternFuncT dt -> def_type dt
  | ExternTableT tt -> table_type tt
  | ExternMemoryT mt -> memory_type mt
  | ExternGlobalT gt -> global_type gt
  | ExternTagT et -> tag_type et

let block_type = function
  | VarBlockType x -> types (idx x)
  | ValBlockType t -> opt val_type t

let hdl = function
  | OnLabel x -> labels (idx x)
  | OnSwitch -> empty

let rec instr (e : instr) =
  match e.it with
  | Unreachable | Nop | Drop -> empty
  | Select tso -> list val_type (Lib.Option.get tso [])
  | RefIsNull | RefAsNonNull -> empty
  | RefTest t | RefCast t -> ref_type t
  | RefEq -> empty
  | RefNull t -> heap_type t
  | RefFunc x -> funcs (idx x)
  | RefI31 | I31Get _ -> empty
  | StructNew (x, _) | ArrayNew (x, _) | ArrayNewFixed (x, _) -> types (idx x)
  | ArrayNewElem (x, y) -> types (idx x) ++ elems (idx y)
  | ArrayNewData (x, y) -> types (idx x) ++ datas (idx y)
  | StructGet (x, _, _) | StructSet (x, _) -> types (idx x)
  | ArrayGet (x, _) | ArraySet x -> types (idx x)
  | ArrayLen -> empty
  | ArrayCopy (x, y) -> types (idx x) ++ types (idx y)
  | ArrayFill x -> types (idx x)
  | ArrayInitData (x, y) -> types (idx x) ++ datas (idx y)
  | ArrayInitElem (x, y) -> types (idx x) ++ elems (idx y)
  | ExternConvert _ -> empty
  | Const _ | Test _ | Compare _ | Unary _ | Binary _ | Convert _ -> empty
  | Block (bt, es) | Loop (bt, es) -> block_type bt ++ block es
  | If (bt, es1, es2) -> block_type bt ++ block es1 ++ block es2
  | Br x | BrIf x | BrOnNull x | BrOnNonNull x -> labels (idx x)
  | BrOnCast (x, t1, t2) | BrOnCastFail (x, t1, t2) ->
    labels (idx x) ++ ref_type t1 ++ ref_type t2
  | BrTable (xs, x) -> list (fun x -> labels (idx x)) (x::xs)
  | Return -> empty
  | Call x | ReturnCall x -> funcs (idx x)
  | CallRef x | ReturnCallRef x -> types (idx x)
  | CallIndirect (x, y) | ReturnCallIndirect (x, y) ->
     tables (idx x) ++ types (idx y)
  | ContNew x -> types (idx x)
  | ContBind (x, y) -> types (idx x) ++ types (idx y)
  | ResumeThrow (x, y, xys) -> types (idx x) ++ tags (idx y) ++ list (fun (x, y) -> tags (idx x) ++ hdl y) xys
  | Resume (x, xys) -> types (idx x) ++ list (fun (x, y) -> tags (idx x) ++ hdl y) xys
  | Suspend x -> tags (idx x)
  | Switch (x, z) -> types (idx x) ++ tags (idx z)
  | Throw x -> tags (idx x)
  | ThrowRef -> empty
  | TryTable (bt, cs, es) ->
    block_type bt ++ list catch cs ++ block es
  | LocalGet x | LocalSet x | LocalTee x -> locals (idx x)
  | GlobalGet x | GlobalSet x -> globals (idx x)
  | TableGet x | TableSet x | TableSize x | TableGrow x | TableFill x ->
    tables (idx x)
  | TableCopy (x, y) -> tables (idx x) ++ tables (idx y)
  | TableInit (x, y) -> tables (idx x) ++ elems (idx y)
  | ElemDrop x -> elems (idx x)
  | Load (x, _) | Store (x, _) | VecLoad (x, _) | VecStore (x, _)
  | VecLoadLane (x, _, _) | VecStoreLane (x, _, _)
  | MemorySize x | MemoryGrow x | MemoryFill x ->
    memories (idx x)
  | MemoryCopy (x, y) -> memories (idx x) ++ memories (idx y)
  | MemoryInit (x, y) -> memories (idx x) ++ datas (idx y)
  | DataDrop x -> datas (idx x)
  | VecConst _ | VecTest _
  | VecUnary _ | VecBinary _ | VecTernary _ | VecCompare _
  | VecConvert _ | VecShift _ | VecBitmask _
  | VecTestBits _ | VecUnaryBits _ | VecBinaryBits _ | VecTernaryBits _
  | VecSplat _ | VecExtract _ | VecReplace _ ->
    empty

and block (es : instr list) =
  let free = list instr es in {free with labels = shift free.labels}

and catch (c : catch) =
  match c.it with
  | Catch (x1, x2) | CatchRef (x1, x2) -> tags (idx x1) ++ labels (idx x2)
  | CatchAll x | CatchAllRef x -> labels (idx x)

let const (c : const) = block c.it

let global (g : global) = global_type g.it.gtype ++ const g.it.ginit
let func (f : func) =
  {(types (idx f.it.ftype) ++ block f.it.body) with locals = Set.empty}
let table (t : table) = table_type t.it.ttype ++ const t.it.tinit
let memory (m : memory) = memory_type m.it.mtype
let tag (e : tag) = empty

let segment_mode f (m : segment_mode) =
  match m.it with
  | Passive | Declarative -> empty
  | Active {index; offset} -> f (idx index) ++ const offset

let elem (s : elem_segment) =
  list const s.it.einit ++ segment_mode tables s.it.emode

let data (s : data_segment) =
  segment_mode memories s.it.dmode

let type_ (t : type_) = rec_type t.it

let export_desc (d : export_desc) =
  match d.it with
  | FuncExport x -> funcs (idx x)
  | TableExport x -> tables (idx x)
  | MemoryExport x -> memories (idx x)
  | GlobalExport x -> globals (idx x)
  | TagExport x -> tags (idx x)

let import_desc (d : import_desc) =
  match d.it with
  | FuncImport x -> types (idx x)
  | TableImport tt -> table_type tt
  | MemoryImport mt -> memory_type mt
  | GlobalImport gt -> global_type gt
  | TagImport et -> types (idx et)

let export (e : export) = export_desc e.it.edesc
let import (i : import) = import_desc i.it.idesc

let start (s : start) = funcs (idx s.it.sfunc)

let module_ (m : module_) =
  list type_ m.it.types ++
  list global m.it.globals ++
  list table m.it.tables ++
  list memory m.it.memories ++
  list tag m.it.tags ++
  list func m.it.funcs ++
  opt start m.it.start ++
  list elem m.it.elems ++
  list data m.it.datas ++
  list import m.it.imports ++
  list export m.it.exports
