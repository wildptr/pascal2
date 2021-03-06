open Batteries

type typ =
  | IntType
  | BoolType
  | ArrayType of typ * int

let elt_type_of = function
  | ArrayType (typ, _) -> typ
  | _ -> failwith "elt_type_of"

let rec align_of_type = function
  | IntType -> 4
  | BoolType -> 1
  | ArrayType (typ, _) -> align_of_type typ

let rec size_of_type = function
  | IntType -> 4
  | BoolType -> 1
  | ArrayType (typ, n) -> size_of_type typ * n (* TODO: align *)

let is_aggregate_type = function
  | IntType -> false
  | BoolType -> false
  | ArrayType _ -> true

type var = {
  name : string;
  qual_name : string;
  typ : typ;
  gid : int;
  lid : int;
  isref : bool;
  param_id : int option;
  proc_id : int;
}

module Var = struct
  type t = var
  let equal v1 v2 = v1.gid = v2.gid
  let compare v1 v2 = Int.compare v1.gid v2.gid
  let hash v = v.gid
end

module VarSet = Set.Make(Var)

type unary_op =
  | Not

type binary_op =
  | Add | Sub | Mul | And | Or | LogAnd | LogOr
  | Eq | NotEq | Lt | GtEq | Gt | LtEq
  | Imp | Select

type ternary_op =
  | Store

type expr =
  | C_IntExpr of int
  | C_BoolExpr of bool
  | C_VarExpr of var
  | C_UnaryExpr of unary_op * expr * typ
  | C_BinaryExpr of binary_op * expr * expr * typ
  | C_TernaryExpr of ternary_op * expr * expr * expr * typ

let type_of_expr = function
  | C_IntExpr _ -> IntType
  | C_BoolExpr _ -> BoolType
  | C_VarExpr v -> v.typ
  | C_UnaryExpr (_, _, typ) -> typ
  | C_BinaryExpr (_, _, _, typ) -> typ
  | C_TernaryExpr (_, _, _, _, typ) -> typ

type param = {
  byref : bool;
  name : string;
  typ : typ
}

type proc_head = {
  name : string;
  qual_name : string;
  params : param array;
  id : int;
  depth : int;
  parent : proc_head option
}

type stmt =
  | C_AssignStmt of var * expr
  | C_AssertStmt of expr
  | C_AssumeStmt of expr
  | C_IfStmt of expr * stmt list * stmt list
  | C_RepeatStmt of expr * stmt list * expr
  | C_CallStmt of var array * proc_head * expr array
  | C_StoreStmt of expr * expr * expr

type proc = {
  head : proc_head;
  body : stmt list;
  vars : var array;
  var_start : int array;
  var_id_map : int Map.Int.t; (* gid -> lid *)
  is_leaf : bool
}

type program = {
  procs : proc array;
  vars : var array;
}

open Format

let string_of_unary_op = function
  | Not -> "not"

let string_of_binary_op = function
  | Add -> "+"
  | Sub -> "-"
  | Mul -> "*"
  | And -> "and"
  | Or -> "or"
  | LogAnd -> "&"
  | LogOr -> "|"
  | Eq -> "="
  | NotEq -> "<>"
  | Lt -> "<"
  | GtEq -> ">="
  | Gt -> ">"
  | LtEq -> "<="
  | Imp -> "=>"
  | _ -> failwith "string_of_binary_op"

let rec pp_expr f = function
  | C_IntExpr i -> pp_print_int f i
  | C_BoolExpr b -> pp_print_bool f b
  | C_VarExpr var -> pp_print_string f var.name
  | C_UnaryExpr (op, e, _) ->
    fprintf f "(%s %a)" (string_of_unary_op op) pp_expr e
  | C_BinaryExpr (op, e1, e2, _) ->
    begin match op with
      | Select ->
        fprintf f "%a[%a]" pp_expr e1 pp_expr e2
      | _ ->
        fprintf f "(%a %s %a)" pp_expr e1 (string_of_binary_op op) pp_expr e2
    end
  | C_TernaryExpr (op, e1, e2, e3, _) ->
    let s =
      match op with
      | Store -> "store"
    in
    fprintf f "%s(%a, %a, %a)" s pp_expr e1 pp_expr e2 pp_expr e3

let pp_list pp f = function
  | [] -> ()
  | hd :: tl -> pp f hd; tl |> List.iter (fprintf f ", %a" pp)

let pp_array pp f a =
  let n = Array.length a in
  if n > 0 then begin
    pp f a.(0);
    for i=1 to n-1 do
      fprintf f ", %a" pp a.(i)
    done
  end

let pp_indent f indent =
  String.make (indent*2) ' ' |> pp_print_string f

let pp_var f (v:var) = pp_print_string f v.name

let rec pp_stmt indent f = function
  | C_AssignStmt (lhs, rhs) ->
    fprintf f "%a%s := %a\n" pp_indent indent lhs.name pp_expr rhs
  | C_AssertStmt e ->
    fprintf f "%aassert %a\n" pp_indent indent pp_expr e
  | C_AssumeStmt e ->
    fprintf f "%aassume %a\n" pp_indent indent pp_expr e
  | C_IfStmt (cond, bodyT, bodyF) ->
    fprintf f "%aif %a then begin\n" pp_indent indent pp_expr cond;
    bodyT |> List.iter (pp_stmt (indent+1) f);
    fprintf f "%aend" pp_indent indent;
    if bodyF <> [] then begin
      fprintf f " else begin\n";
      bodyF |> List.iter (pp_stmt (indent+1) f);
    fprintf f "%aend" pp_indent indent;
    end;
    pp_print_char f '\n'
  | C_RepeatStmt (inv, body, cond) ->
    fprintf f "%arepeat invariant %a\n" pp_indent indent pp_expr inv;
    body |> List.iter (pp_stmt (indent+1) f);
    fprintf f "%auntil %a\n" pp_indent indent pp_expr cond
  | C_CallStmt (vars, proc, args) ->
    pp_indent f indent;
    if Array.length vars > 0 then
      fprintf f "%a := " (pp_array pp_var) vars;
    fprintf f "%s(%a)\n" proc.name (pp_array pp_expr) args
  | C_StoreStmt (base, index, value) ->
    fprintf f "%a%a[%a] := %a\n" pp_indent indent pp_expr base pp_expr index
      pp_expr value

let pp_proc f proc =
  let head = proc.head in
  fprintf f "procedure %s\n" head.name;
  pp_print_string f "variables:";
  proc.vars |> Array.iter begin fun (v:var) ->
    fprintf f " %s(L%d,G%d)" v.qual_name v.lid v.gid
  end;
  pp_print_char f '\n';
  pp_print_string f "scope boundaries:";
  proc.var_start |> Array.iter (fprintf f " %d");
  pp_print_char f '\n';
  pp_print_string f "begin\n";
  proc.body |> List.iter (pp_stmt 1 f);
  pp_print_string f "end\n";
