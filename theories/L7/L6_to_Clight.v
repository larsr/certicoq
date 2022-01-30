Require Import Coq.ZArith.ZArith
        Coq.Program.Basics
        Coq.Strings.Ascii
        Coq.Strings.String
        Coq.Lists.List List_util.

Require Import ExtLib.Structures.Monads
               ExtLib.Data.Monads.OptionMonad
               ExtLib.Data.Monads.StateMonad
               ExtLib.Data.String.

Import MonadNotation.
Open Scope monad_scope.

From MetaCoq.Template Require Import BasicAst.

From compcert Require Import
  common.AST
  common.Errors
  lib.Integers
  cfrontend.Cop
  cfrontend.Ctypes
  cfrontend.Clight
  common.Values
  Clightdefs.

Require Import L6.cps
               L6.identifiers
               L6.cps_show.

Section TRANSLATION.

(* Stand-in for arbitrary identifiers *)
Variable (args_id : ident).
Variable (alloc_id : ident).
Variable (limit_id : ident).
Variable (gc_id : ident).
Variable (main_id : ident).
Variable (body_id : ident).
Variable (thread_info_id : ident).
Variable (tinfo_id : ident).
Variable (heap_info_id : ident).
Variable (num_args_id : ident).
Variable (isptr_id : ident). (* ident for the is_ptr external function *)
Variable (case_id : ident). (* ident for the case variable, TODO: generate that automatically and only when needed *)

(* The number of parameters to be passed in registers *)
Variable (n_param : nat). 

Definition max_args : Z := 1024%Z.

(* temporary function to get something working *)
(* returns (n-1) :: (n-2) :: ... :: 0 :: nil for a list of size n *)
Fixpoint makeArgList' {A} (vs : list A) : list N :=
  match vs with
  | nil => nil
  | x :: vs' => (N.of_nat (length vs')) :: (makeArgList' vs')
  end.

(* [0; ..; length vs - 1] *)
Definition makeArgList {A} (vs : list A) : list N := rev (makeArgList' vs).

(* fun_info_env holds mappings f ↦ (fi, t) where
     f is function name
     fi is the name of f's fun_info array
     t is fun_tag associated with f
*)
Definition fun_info_env : Type := M.t (var * fun_tag).

(* fun_env holds mappings
     t ↦ (|vs|, [0; ..; |vs| - 1]) 
   for each (Eapp x t vs) and (Fcons _ t vs _ _) in the expression being compiled.
*)
Fixpoint compute_fun_env' (fenv : fun_env) (e : exp) {struct e} : fun_env :=
  match e with
  | Econstr x t vs e' => compute_fun_env' fenv e'
  | Ecase x cs => fold_left (fun fenv '(_, e) => compute_fun_env' fenv e) cs fenv
  | Eproj x t n v e' => compute_fun_env' fenv e'
  | Eletapp x f t vs e' => compute_fun_env' (M.set t (N.of_nat (length vs), makeArgList vs) fenv) e'
  | Efun fnd e' => compute_fun_env' (compute_fun_env_fundefs fnd fenv) e'
  | Eapp x t vs => M.set t (N.of_nat (length vs), makeArgList vs) fenv
  | Eprim x p vs e' => compute_fun_env' fenv e'
  | Ehalt x => fenv
  end
with compute_fun_env_fundefs fnd fenv {struct fnd} :=
  match fnd with
  | Fnil => fenv
  | Fcons f t vs e fnd' =>
    let fenv' := M.set t (N.of_nat (length vs), makeArgList vs) fenv in
    compute_fun_env_fundefs fnd' (compute_fun_env' fenv' e)
  end.

(*
(* OS: this only computes fenv for known functions. *)
Fixpoint compute_fun_env_fds fnd fenv :=
  match fnd with
  | Fnil => fenv
  | Fcons f t vs e fnd' =>
    let fenv' := M.set t (N.of_nat (length vs), makeArgList vs) fenv in
    compute_fun_env_fds fnd' fenv'
  end.
*)

(* fun_env maps tags to function info *)
Definition compute_fun_env : exp -> fun_env := compute_fun_env' (M.empty _).

(* A list of variable names bound in e. *)
Fixpoint get_allocs (e : exp) : list var :=
  match e with
  | Econstr x t vs e' => x :: get_allocs e'
  | Ecase x cs => fold_right (fun '(_, e) allocs => get_allocs e ++ allocs) nil cs
  | Eproj x t n v e' => x :: get_allocs e'
  | Eletapp x f t xs e' => x :: get_allocs e'
  | Efun fnd e' => get_allocs_fundefs fnd ++ get_allocs e'
  | Eapp x t vs => nil (* stores into args, not alloc new vars *)
  | Eprim x p vs e' => x :: get_allocs e'
  | Ehalt x => nil
  end
with get_allocs_fundefs (fnd : fundefs) :=
  match fnd with
  | Fnil => nil
  | Fcons f t vs e fnd' => vs ++ get_allocs e ++ get_allocs_fundefs fnd'
  end.

(* Max number of value-sized words allocated by the translation of expression e, ignoring
   allocations performed by function calls.  *)
Fixpoint max_allocs (e : exp) : nat :=
  match e with
  | Econstr x t vs e' =>
    match vs with
    (* Unboxed constructor requires no heap allocation *)
    | nil => max_allocs e'
    (* Boxed constructor requires 1 word for the header + 1 word per argument *)
    | _ => S (length vs + max_allocs e')
    end
  | Ecase x cs => fold_left (fun allocs '(_, e) => max (max_allocs e) allocs) cs 0
  | Eproj x t n v e' => max_allocs e'
  | Eletapp x f t ys e' => max_allocs e' (* Zoe: This doesn't include the allocation happening by the function *)
  | Efun fds e => 0 (* unreachable: we assume terms are hoisted *)
  | Eapp x t vs => 0
  | Eprim x p vs e' => max_allocs e'
  | Ehalt x => 0
  end.

(*
(* Compute the max number of parameters a function has in the term exp  *)
Fixpoint max_pars (e : exp) : nat :=
  match e with
  | Econstr x t vs e' => max_pars e'
  | Ecase x cs => fold_left (fun allocs '(_, e) => max (max_pars e) allocs) cs 0
  | Eproj x t n v e' => max_pars e'
  | Eletapp x f n xs e' => max_pars e'
  | Efun fnd e' => max (max_pars_fundefs fnd) (max_pars e')
  | Eapp x t vs => 0
  | Eprim x p vs e' => max_pars e'
  | Ehalt x => 2
  end
with max_pars_fundefs (fnd : fundefs) :=
  match fnd with
  | Fnil => 0
  | Fcons f t vs e fnd' => 
    max (max (length vs) (max_pars e)) (max_allocs_fundefs fnd')
  end.
*)

(* Maybe move this to cps and replace the current definition of ind_ty_info? *)
(* 1) name of inductive type
   2) list containing info for each of its constructors
   John: this representation is a little redundant. ctor_ty_info contains the name
   of the inductive type inside of it. The only time we would need (1) is if (2) is
   the empty list. But it's impossible to construct or case-split on types with zero
   constructors, so the list should be non-empty in all cases we care about. *)
Definition n_ind_ty_info : Type := BasicAst.name * list ctor_ty_info.

(* An n_ind_env maps each ind_tag to its name and list of constructors *)
Definition n_ind_env := M.t n_ind_ty_info.

(* John: Note that c, the ctor_tag associated with cinfo, is unused. *)
Definition update_ind_env (ienv : n_ind_env) (c : ctor_tag) (cinfo : ctor_ty_info) : n_ind_env :=
  let '{| ctor_name := name
        ; ctor_ind_name := name_ty
        ; ctor_ind_tag := t
        ; ctor_arity := arity
        ; ctor_ordinal := ord
        |} := cinfo in
  match (M.get t ienv) with
  | None => M.set t (name_ty, (cinfo :: nil)) ienv
  | Some (name_ty, iInf) => M.set t (name_ty, cinfo :: iInf) ienv
  end.

(* Compute an n_ind_env from a ctor_env. *)
Definition compute_ind_env (cenv : ctor_env) : n_ind_env :=
  M.fold update_ind_env cenv (M.empty _).

Inductive ctor_rep : Type :=
(* [enum t] represents a constructor with no parameters with ordinal [t] *)
| enum : N -> ctor_rep
(* [boxed t a] represents a construct with arity [a] and ordinal [t].
   Assume t<256. *)
| boxed : N -> N -> ctor_rep.

(* The type of the thread info struct and a pointer to it *)
Definition threadStructInf : type := Tstruct thread_info_id noattr.
Definition threadInf : type := Tpointer threadStructInf noattr.

(* NOTE: in Clight, SIZEOF_PTR == SIZEOF_INT *)
Definition int_ty : type :=
  Tint I32 Signed {| attr_volatile := false; attr_alignas := None |}.
Definition uint_ty : type :=
  Tint I32 Unsigned {| attr_volatile := false; attr_alignas := None |}.
Definition long_ty : type :=
  Tlong Signed {| attr_volatile := false; attr_alignas := None |}.
Definition ulong_ty : type :=
  Tlong Unsigned {| attr_volatile := false; attr_alignas := None |}.

Definition int_chunk : memory_chunk := if Archi.ptr64 then Mint64 else Mint32.
(* NOTE for val: in Clight, SIZEOF_PTR == SIZEOF_INT *)
Definition val : type := if Archi.ptr64 then ulong_ty else uint_ty.
Definition uval : type := if Archi.ptr64 then ulong_ty else uint_ty.
Definition sval : type := if Archi.ptr64 then long_ty else int_ty.
Definition val_typ : typ := if Archi.ptr64 then AST.Tlong else Tany32.
(* [Init_int x] = a C int literal in an initializer, with value x *)
Definition Init_int (x : Z) : init_data :=
  if Archi.ptr64 then (Init_int64 (Int64.repr x)) else (Init_int32 (Int.repr x)).
(* [make_vint z] = a C int value with value z *)
Definition make_vint (z : Z) : Values.val :=
  if Archi.ptr64 then Vlong (Int64.repr z) else Values.Vint (Int.repr z).
(* [make_cint z t] = C integer constant with value z of type t *)
Definition make_cint (z : Z) (t : type) : expr :=
  if Archi.ptr64 then Econst_long (Int64.repr z) t else (Econst_int (Int.repr z) t).
Transparent val.
Transparent uval.
Transparent val_typ.
Transparent Init_int.
Transparent make_vint.
Transparent make_cint.

(* typedef void (*pfunTy)(struct thread_info *); 
   The type of a function that doesn't take arguments in registers. *)
Definition funTy : type :=
  Tfunction (Tcons threadInf Tnil) Tvoid cc_default.
Definition pfunTy : type := Tpointer funTy noattr.

(* typedef const uintnat *fun_info;
   void garbage_collect(fun_info fi, struct thread_info *tinfo); *)
Definition gc_ty : type :=
  Tfunction (Tcons (Tpointer val noattr) (Tcons threadInf Tnil)) Tvoid cc_default.

(* bool isptr(val); *)
Definition isptr_ty : type :=
  Tfunction (Tcons val Tnil) (Tint IBool Unsigned noattr) cc_default.

Definition valPtr : type :=
  Tpointer val {| attr_volatile := false; attr_alignas := None |}.

(* The type of the args array *)
Definition argvTy : type :=
  Tpointer val {| attr_volatile := false; attr_alignas := None |}.

Definition bool_ty : type :=
  Tint IBool Unsigned noattr.

(* mk_arg_tys n = val, ..
                  ------- n times *)
Fixpoint mk_arg_tys (n : nat) : typelist :=
  match n with
  | 0 => Tnil
  | S n' => Tcons val (mk_arg_tys n')
  end.

(* mk_fun_ty n = void(struct thread_info *ti, val, ..)
                                              ------- n times
   The type of a function that takes n arguments in registers. *)
Definition mk_fun_ty (n : nat) : type :=
  Tfunction (Tcons threadInf (mk_arg_tys n)) Tvoid cc_default.

(* mk_prim_ty n = val(val, ..)
                      ------- n times
   The type of a primop with arity n. *)
Definition mk_prim_ty (n : nat) :=
  Tfunction (mk_arg_tys n) val cc_default.

(* struct thread_info *make_tinfo(void); *)
Definition make_tinfo_ty : type :=
  (Tfunction Tnil threadInf cc_default).

(* val *export();
   TODO: The type of an exported program? *)
Definition export_ty : type :=
  Tfunction (Tcons threadInf Tnil) valPtr cc_default.

Notation "'var' x" := (Etempvar x val) (at level 20).
Notation "'ptr_var' x" := (Etempvar x valPtr) (at level 20).
Notation "'bvar' x" := (Etempvar x bool_ty) (at level 20).
Notation "'fun_var' x" := (Evar x funTy) (at level 20).

Definition alloc_ptr : expr := Etempvar alloc_id valPtr.
Definition limit_ptr : expr := Etempvar limit_id valPtr.
Definition args : expr := Etempvar args_id valPtr.
Definition gc : expr := Evar gc_id gc_ty.
Definition isptr : expr := Evar isptr_id isptr_ty.

(* changed tinf to be tempvar and have type Tstruct rather than Tptr Tstruct *)
Definition tinf  : expr := (Etempvar tinfo_id threadInf).
Definition tinfd : expr := (Ederef tinf threadStructInf).

(* TODO: What is a heap_info? *)
Notation heap_info := (Tstruct heap_info_id noattr).

Definition add (a b : expr) := Ebinop Oadd a b valPtr.
Infix "+'" := add (at level 30).
Definition sub (a b : expr) := Ebinop Osub a b valPtr.
Infix "-'" := sub (at level 30).
Definition int_eq (a b : expr) := Ebinop Oeq a b type_bool.
Infix "='" := int_eq (at level 35).
Definition c_not (a : expr) := Eunop Onotbool a type_bool.
Notation "'!' a" := (c_not a) (at level 40).

Notation seq := Ssequence.
Notation "p ';;;' q" := (seq p q) (at level 100, format " p ';;;' '//' q ").

Infix "::=" := Sset (at level 50).
Infix ":::=" := Sassign (at level 50).

Notation "'*' p" := (Ederef p val) (at level 40).
Notation "'&' p" := (Eaddrof p valPtr) (at level 40).

Definition c_int (n : Z) (t : type) : expr :=
  if Archi.ptr64
  then Econst_long (Int64.repr n) t
  else Econst_int (Int.repr n%Z) t.

Notation "'while(' a ')' '{' b '}'" := (Swhile a b) (at level 60).

(* Notation "'call' f " := (Scall None f (tinf :: nil)) (at level 35). *)

Notation "'[' t ']' e " := (Ecast e t) (at level 34).

Notation "'Field(' t ',' n ')'" :=
  ( *(add ([valPtr] t) (c_int n%Z val))) (at level 36). (* what is the type of int being added? *)

Notation "'args[' n ']'" :=
  ( *(add args (c_int n%Z val))) (at level 36).

Section CODEGEN.

(* constructor tag c ↦ 
     Build_ctor_ty_info 
       ctor_name 
       ctor_ind_name 
       ctor_ind_tag 
       ctor_arity 
       ctor_ordinal *)
Variable (cenv : ctor_env). 
(* fun_tag t ↦ (n, [0; ..; n-1]) where n = arity of the function with tag t *)
Variable (fenv : fun_env).
(* function name f ↦ (the name of f's fun_info, f's fun_tag) *)
Variable (fienv : fun_info_env). 

Definition make_ctor_rep (ct : ctor_tag) : option ctor_rep :=
  cinfo <- M.get ct cenv ;;
  if (cinfo.(ctor_arity) =? 0)%N
  then Some (enum cinfo.(ctor_ordinal))
  else Some (boxed cinfo.(ctor_ordinal) cinfo.(ctor_arity)).

(* fun_info is an identifier that holds the fun_info,
   l is the length of the fun_info array,
   Returns code to call garbage_collect if limit-alloc <= fun_info[0],
   specifically for the entry point body(). 
   
   Since body() doesn't take any arguments, we don't need to worry about
   storing arguments passed as registers into the args array. *)
Definition reserve_body (fun_info : ident) (l : Z) : statement :=
  let arr := (Evar fun_info (Tarray uval l noattr)) in
  Sifthenelse
    (!(Ebinop Ole (Ederef arr uval) (limit_ptr -' alloc_ptr) type_bool))
    (Scall None gc (arr :: tinf :: nil) ;;;
     alloc_id ::= Efield tinfd alloc_id valPtr)
    Sskip.

(* Don't shift the tag for boxed, make sure it is under 255 
   (John: is this a TODO item? The function doesn't make sure t<255 in the boxed case) *)
Definition make_tagZ (ct : ctor_tag) : option Z :=
  match make_ctor_rep ct with
  | Some (enum t) => Some (Z.shiftl (Z.of_N t) 1 + 1)
  | Some (boxed t a) => Some (Z.shiftl (Z.of_N a) 10 + Z.of_N t)
  | None => None
  end%Z.

Definition make_tag (ct : ctor_tag) : option expr :=
  t <- make_tagZ ct ;;
  ret (c_int t val).

(* To use variables in Clight expressions, need variable name and its type.
   Variables that refer to functions must have type
     void(struct thread_info *ti, val, ..)
                                  ------- n times
   where n = min(n_param, arity of the function).
   All other variables just have type val. 
*)

(* x is the name of the function,
   locs is the list [0; ..; arity(x) - 1],
   Returns a well-formed Evar node for referring to x. *)
Definition mk_fun_var (x : ident) (locs : list N) : expr :=
  Evar x (mk_fun_ty (length (firstn n_param locs))).

(* make_var x = Evar x t where t is x's C type *)
Definition make_var (x : ident) : expr :=
  match M.get x fienv with
  (* if x is a function name with tag t... *)
  | Some (_, t) =>
    match M.get t fenv with
    (* ...and tag t corresponds to a function with arity n, then x has function type *)
    | Some (n, locs) => mk_fun_var x locs (* locs = [0; ..; n-1]. TODO: could just use n instead of locs *)
    | None => (* should be unreachable *) var x
    end
  (* otherwise, x is just a regular variable *)
  | None => var x
  end.

(* asgn_constr' x cur vs =
            x[cur] = vs[0];
        x[cur + 1] = vs[1];
                   .
                   .
     x[cur + |vs|] = vs[|vs| - 1] 
   Assumes |vs|>0. *)
Fixpoint asgn_constr' (x : ident) (cur : nat) (vs : list ident) : statement :=
  match vs with
  | nil => (* should be unreachable *) Sskip
  | v :: nil => Field(var x, Z.of_nat cur) :::= (*[val]*) make_var v
  | v :: vs =>
    Field(var x, Z.of_nat cur) :::= (*[val]*) make_var v ;;;
    asgn_constr' x (S cur) vs
  end.

(* asgn_constr x c vs = 
     code to set x to (Constr c vs)
     if boxed (i.e., |vs|>0), x is a heap pointer. *)
Definition asgn_constr (x : ident) (c : ctor_tag) (vs : list ident) :=
  tag <- make_tag c ;;
  rep <- make_ctor_rep c ;;
  match rep with
  | enum _ => ret (x ::= tag)
  | boxed _ a =>
    ret (
      x ::= [val] (alloc_ptr +' c_int Z.one val) ;;;
      alloc_id ::= alloc_ptr +' c_int (Z.of_N (a + 1)) val ;;;
      Field(var x, -1) :::= tag ;;;
      asgn_constr' x 0 vs)
  end.

(* This is not valid in Clight if x is a Vptr, implementing instead as an external function
Definition is_ptr (x : positive) :=
  int_eq
    (Ebinop Oand
            ([val] (var x))
            (c_int 1 val)
            val)
    (c_int 0 val).
 *)

(* is_ptr ret_id v = 
     code to check if v is a pointer and store the result in ret_id *)
Definition is_ptr (ret_id : ident) (v : ident) : statement :=
  Scall (Some ret_id) isptr ([val](var v) :: nil).

Definition is_boxed (ct : ctor_tag) : bool :=
  match make_ctor_rep ct with
  | Some (boxed _ _) => true
  | Some (enum _) | None => false
  end.

(* mk_call_vars n vs = Some (map make_var vs) if n = |vs| else None *)
Fixpoint mk_call_vars (n : nat) (vs : list ident) : option (list expr) :=
  match n, vs with
  | 0, nil => Some nil
  | S n, v :: vs' =>
    rest <- mk_call_vars n vs' ;;
    ret (make_var v :: rest)
  | _, _ => None
  end.

(* mk_call f n vs = Some (f(tinfo, vs..)) if n = min(n_param, |vs|) else None *)
Definition mk_call (f : expr) (n : nat) (vs : list ident) : option statement :=
  vs <- mk_call_vars n (firstn n_param vs) ;;
  ret (Scall None f (tinf :: vs)).

(* mk_prim_call res pr ar vs = Some (res = pr(vs..)) if ar = min(n_param, |vs|) else None *)
Definition mk_prim_call (res pr : ident) (ar : nat) (vs : list ident) : option statement :=
  args <- mk_call_vars ar vs ;;  
  ret (Scall (Some res) ([mk_prim_ty ar] (Evar pr (mk_prim_ty ar))) args).

(* Load arguments from the args array.
   asgn_fun_vars' vs ind =
     vs[|ind| - 1] = args[ind[|ind| - 1]];
                   .
                   .
             vs[1] = args[ind[1]];
             vs[0] = args[ind[0]];
   Reads arguments from the args array at indices ind.
   Stores them in local variables vs.
*)
Fixpoint asgn_fun_vars' (vs : list ident) (ind : list N) : option statement :=
  match vs, ind with
  | nil, nil => ret Sskip
  | v :: vs, i :: ind => 
    rest <- asgn_fun_vars' vs ind ;;
    ret (v ::= args[ Z.of_N i ] ;;; rest)
  | _, _ => None
  end.

(* Like asgn_fun_vars' but skip the first n_param arguments. *)
Definition asgn_fun_vars (vs : list positive) (ind : list N) : option statement :=
  asgn_fun_vars' (skipn n_param vs) (skipn n_param ind).

(* asgn_app_vars'' vs ind =
            args[ind[0]] = vs[0];
            args[ind[1]] = vs[1];
                         .
                         .
     args[ind[|ind| - 1] = vs[|ind| - 1];
   Reads arguments from local variables vs.
   Stores them in the args array at indices ind.
*)
Fixpoint asgn_app_vars'' (vs : list ident) (ind : list N) : option statement :=
  match vs, ind with
  | nil, nil => ret Sskip
  | v :: vs, i :: ind =>
    rest <- asgn_app_vars'' vs ind ;;
    ret (rest ;;; args[ Z.of_N i ] :::= make_var v)
  | _, _ => None
  end.

(* Like asgn_app_vars'', but skip the first n_param arguments. *)
Definition asgn_app_vars' (vs : list ident) (ind : list N) : option statement :=
  asgn_app_vars'' (skipn n_param vs) (skipn n_param ind).

Fixpoint index_of {A} (eq : A -> A -> bool) (l : list A) (x : A) : option nat :=
  match l with
  | nil => None
  | x' :: l' =>
    if eq x x' then Some 0 else
    n <- index_of eq l' x ;;
    ret (S n)
  end.

(* remove_app_vars myvs vs myind ind =
      if
        |vs| = |ind|
      then
        Some (unzip (zip vs ind \ zip myvs myind))
      else
        None *)
Fixpoint remove_app_vars (myvs vs : list ident) (myind ind : list N)
  : option (list ident * list N) :=
  match vs, ind with
  | nil, nil => Some (nil, nil)
  | v :: vs, i :: ind =>
    '(vs, ind) <- remove_app_vars myvs vs myind ind ;;
    match
      n <- index_of Pos.eqb myvs v ;;
      i' <- nth_error myind n ;;
      if N.eqb i i' then ret (vs, ind) else None
    with
    | Some _ as res => res
    | None => ret (v :: vs, i :: ind)
    end
  | _, _ => None
  end.

(* Like asgn_app_vars'' but ignore variables in myvs/indices in myind *)
Definition asgn_app_vars_fast' (myvs vs : list ident) (myind ind : list N) : option statement :=
  '(vs, ind) <- remove_app_vars myvs (skipn n_param vs) myind (skipn n_param ind) ;;
  asgn_app_vars'' vs ind.

(* To reduce register pressure while loading arguments from the args array,
   instead of emitting
     tinfo->args[..] = ..;
     tinfo->args[..] = ..;
     tinfo->args[..] = ..;
     tinfo->args[..] = ..;
   we'll first cache tinfo->args:
     args = tinfo->args;
     args[..] = ..;
     args[..] = ..;
     args[..] = ..;
     args[..] = ..; 
*)
Definition asgn_app_vars (vs : list ident) (ind : list N) : option statement :=
  s <- asgn_app_vars' vs ind ;;
  ret (args_id ::= Efield tinfd args_id (Tarray uval max_args noattr) ;;; s).

(* Like asgn_app_vars, but ignore variables in myvs/indices in myind *)
Definition asgn_app_vars_fast (myvs vs : list ident) (myind ind : list N) : option statement :=
  match asgn_app_vars_fast' myvs vs myind ind with
  | Some s => ret (args_id ::= Efield tinfd args_id (Tarray uval max_args noattr) ;;; s)
  | None => None
  end.

(* Returns code to invoke the garbage collector if necessary, at the beginning of a function body.
   - fi holds the fun_info; fi[0] is the maximum number of words needed by
     the function body being compiled.
   - l is the length of fi
   - vs are the function's arguments
   - ind are the indices of each argument in the args array
*)
Definition reserve (fi : ident) (l : Z) (vs : list ident) (ind : list N) : option statement :=
  let arr := Evar fi (Tarray uval l noattr) in
  bef <- asgn_app_vars'' (firstn n_param vs) (firstn n_param ind) ;;
  aft <- asgn_fun_vars' (firstn n_param vs) (firstn n_param ind) ;;
  ret (
    Sifthenelse
      (* If fi[0] > limit-alloc (i.e., there might not be enough space left on the heap), *)
      (!(Ebinop Ole (Ederef arr uval) (limit_ptr -' alloc_ptr) type_bool))
      ((* Store the arguments that were passed in registers into the args array 
          TODO: Technically, isn't this unnecessary? 
          When executing function calls, we store every argument in the args array.
          (See Eapp case of translate_body, below.) *)
       bef ;;;
       (* Invoke the gc *)
       Scall None gc (arr :: tinf :: nil) ;;;
       (* Update our local copy of alloc *)
       alloc_id ::= Efield tinfd alloc_id valPtr ;;;
       (* Retrieve the arguments that were passed in registers from the args array.
          (Need to retrieve because garbage collection can move pointers around.) *)
       aft)
      Sskip).

(* Like reserve, but instead of reading from a local copy of alloc and limit,
   read from tinfo->alloc and tinfo->limit. *)
Definition reserve' (fi : ident) (l : Z) (vs : list ident) (ind : list N) : option statement :=
  let arr := Evar fi (Tarray uval l noattr) in
  let allocF := Efield tinfd alloc_id valPtr in
  let limitF := Efield tinfd limit_id valPtr in
  bef <- asgn_app_vars'' (firstn n_param vs) (firstn n_param ind) ;;
  aft <- asgn_fun_vars' (firstn n_param vs) (firstn n_param ind) ;;
  ret (
    Sifthenelse
      (!(Ebinop Ole (Ederef arr uval) (limitF -' allocF) type_bool))
      (bef ;;; Scall None gc (arr :: tinf :: nil) ;;; aft)
      Sskip).

(* x = scrutinee; ls = boxed cases; ls' = unboxed cases *)
Definition make_case_switch (x : ident) (ls ls' : labeled_statements) : statement :=
  is_ptr case_id x;;;
  Sifthenelse
    (bvar case_id)
    (Sswitch (Ebinop Oand (Field(var x, -1)) (make_cint 255 val) val) ls)
    (Sswitch (Ebinop Oshr (var x) (make_cint 1 val) val) ls').

Fixpoint translate_body (e : exp) : option statement :=
  match e with
  | Econstr x t vs e =>
    s_constr <- asgn_constr x t vs ;;
    rest <- translate_body e ;;
    ret (s_constr ;;; rest)
  | Ecase x cs =>
    (* ls <- boxed cases (Vptr), ls' <- unboxed (Vint) *)
    '(ls, ls') <-
       (fix make_cases (l : list (ctor_tag * exp)) :=
         match l with
         | nil => ret (LSnil, LSnil)
         | (c, e) :: l' =>
           rest <- translate_body e ;;
           '(ls, ls') <- make_cases l' ;;
           match make_ctor_rep c with
           | Some (boxed t a) =>
             match ls with
             | LSnil => ret (LScons None (rest ;;; Sbreak) ls, ls')
             | LScons _ _ _ => ret (LScons (Some (Z.of_N t)) (rest ;;; Sbreak) ls, ls')
             end
           | Some (enum t) =>
             match ls' with
             | LSnil => ret (ls, LScons None (rest ;;; Sbreak) ls')
             | LScons _ _ _ => ret (ls, LScons (Some (Z.of_N t)) (rest ;;; Sbreak) ls')
             end
           | None => None
           end
         end) cs ;;
    ret (make_case_switch x ls ls')
  | Eletapp x f t vs e => None
  | Eproj x t n v e =>
    prog <- translate_body e ;;
    ret (x ::= Field(var v, Z.of_N n) ;;; prog)
  | Efun fnd e => None
  | Eapp f t vs =>
    '(arity, indices) <- M.get t fenv ;;
    asgn <- asgn_app_vars vs indices ;;
    let f := make_var f in
    let pnum := min (N.to_nat arity) n_param in
    call <- mk_call ([Tpointer (mk_fun_ty pnum) noattr] f) pnum vs ;;
    ret (
      asgn ;;;
      Efield tinfd alloc_id valPtr :::= alloc_ptr ;;;
      Efield tinfd limit_id valPtr :::= limit_ptr ;;;
      call)
  | Eprim x p vs e =>
    pr_call <- mk_prim_call x p (length vs) vs ;;
    prog <- translate_body e ;;
    ret (pr_call ;;; prog)
  | Ehalt x =>
    (* set args[1] to x and return *)
    ret (
      Efield tinfd alloc_id valPtr :::= alloc_ptr ;;;
      Efield tinfd limit_id valPtr :::= limit_ptr ;;;
      args[ Z.of_nat 1 ] :::= make_var x)
  end.

(* Like translate_body, but with calls to asgn_app_vars replaced by
   calls to asgn_app_vars_fast (myvs:=myvs) (myind:=myind). *)
Fixpoint translate_body_fast (e : exp) (myvs : list ident) (myind : list N) : option statement :=
  match e with
  | Econstr x t vs e =>
    s_constr <- asgn_constr x t vs ;;
    rest <- translate_body_fast e myvs myind ;;
    ret (s_constr ;;; rest)
  | Ecase x cs =>
    (* ls <- boxed cases (Vptr), ls <- unboxed (Vint) *)
    '(ls, ls') <-
      (fix make_cases (l : list (ctor_tag * exp)) :=
         match l with
         | nil => ret (LSnil, LSnil)
         | (c, e) :: l' =>
           rest <- translate_body_fast e myvs myind ;;
           '(ls, ls') <- make_cases l' ;;
           match make_ctor_rep c with
           | Some (boxed t a) =>
             match ls with
             | LSnil => ret (LScons None (rest ;;; Sbreak) ls, ls')
             | LScons _ _ _ => ret (LScons (Some (Z.of_N t)) (rest ;;; Sbreak) ls, ls')
             end
           | Some (enum t) =>
             match ls' with
             | LSnil => ret (ls, LScons None (rest ;;; Sbreak) ls')
             | LScons _ _ _ => ret (ls, LScons (Some (Z.of_N t)) (rest ;;; Sbreak) ls')
             end
           | None => None
           end
         end) cs ;;
      ret (make_case_switch x ls ls')
  | Eletapp x f t vs e =>
    let vv := make_var f in
    '(arity, indices) <- M.get t fenv ;;
    asgn <- asgn_app_vars_fast myvs vs myind indices ;;
    let pnum := min (N.to_nat arity) n_param in
    call <- (mk_call ([Tpointer (mk_fun_ty pnum) noattr] vv) pnum vs) ;;
    rest <- translate_body_fast e myvs myind;;
    ret (
      asgn ;;;
      Efield tinfd alloc_id valPtr :::= alloc_ptr ;;; 
      Efield tinfd limit_id valPtr :::= limit_ptr ;;; 
      call ;;; 
      alloc_id ::= Efield tinfd alloc_id valPtr ;;; 
      x ::= Field(args, Z.of_nat 1) ;;; 
      rest)
  | Eproj x t n v e =>
    rest <- translate_body_fast e myvs myind ;;
    ret (x ::= Field(var v, Z.of_N n) ;;; rest)
  | Efun fnd e => None
  | Eapp f t vs =>
    let vv := make_var f in
    '(arity, indices) <- M.get t fenv ;;
    asgn <- asgn_app_vars_fast myvs vs myind indices ;;
    let pnum := min (N.to_nat arity) n_param in
    call <- mk_call ([mk_fun_ty pnum] vv) pnum vs ;;
    ret (
      asgn ;;;
      Efield tinfd alloc_id valPtr :::= alloc_ptr ;;;
      Efield tinfd limit_id valPtr :::= limit_ptr ;;;
      call)
  | Eprim x p vs e =>
    pr_call <- mk_prim_call x p (length vs) vs ;;
    rest <- translate_body_fast e myvs myind ;;
    ret (pr_call ;;; rest)
  | Ehalt x =>
    (* set args[1] to x and return *)
    ret (
      Efield tinfd alloc_id valPtr :::= alloc_ptr ;;;
      Efield tinfd limit_id valPtr :::= limit_ptr ;;;
      args[ Z.of_nat 1 ] :::= make_var x)
  end.

(* Make a Clight function for an L6 function with 
   - parameters vs,
   - local variables loc,
   - translated body body *)
Definition mk_fun (vs : list ident) (loc : list ident) (body : statement) : function :=
  mkfunction
    Tvoid
    cc_default
    (* Parameters *)
    ((tinfo_id, threadInf) :: map (fun x => (x, val)) (firstn n_param vs))
    (* Local variables *)
    (map (fun x => (x, val)) (skipn n_param vs ++ loc) ++ (alloc_id, valPtr)
      :: (limit_id, valPtr)
      :: (args_id, valPtr)
      :: (case_id, bool_ty)
      :: nil)
    (* Temporaries *)
    nil
    body.

(* Translate f(xs) = e into Clight function implementing e *)
Definition translate_fundef f t vs e : option function :=
  '(arity, indices) <- M.get t fenv ;;
  '(fun_info, _) <- M.get f fienv ;;
  reserve_space <- reserve fun_info (Z.of_N (arity + 2)) vs indices ;;
  asgn <- asgn_fun_vars vs indices ;;
  body <- translate_body e ;;
  let body :=
    (* Make local copies of tinfo->alloc, tinfo->limit, tinfo->args *)
    alloc_id ::= Efield tinfd alloc_id valPtr ;;;
    limit_id ::= Efield tinfd limit_id valPtr ;;;
    args_id ::= Efield tinfd args_id (Tarray uval max_args noattr);;;
    (* Make sure there's enough space; invoke gc if necessary *)
    reserve_space ;;;
    (* Load arguments from the args array *)
    asgn ;;;
    body
  in
  ret (mk_fun vs (get_allocs e) body).

(* Translate each f(xs) = e ∈ fnd into (f, Clight function implementing e) *)
Fixpoint translate_fundefs (fnd : fundefs) : option (list (ident * globdef Clight.fundef type)) :=
  match fnd with
  | Fnil => ret nil
  | Fcons f t vs e fnd' =>
    fn <- translate_fundef f t vs e ;;
    rest <- translate_fundefs fnd' ;;
    ret ((f, Gfun (Internal fn)) :: rest)
  end.

(* Like translate_fundefs, but use translate_body_fast (myvs:=vs) (myind:=indices) *)
Fixpoint translate_fundefs_fast (fnd : fundefs) : option (list (ident * globdef Clight.fundef type)) :=
  match fnd with
  | Fnil => ret nil
  | Fcons f t vs e fnd' =>
    '(arity, indices) <- M.get t fenv ;;
    '(fi, _) <- M.get f fienv ;;
    reserve_space <- reserve fi (Z.of_N (arity + 2)) vs indices ;;
    asgn <- asgn_fun_vars vs indices ;;
    body <- translate_body_fast e vs indices ;;
    let body :=
      alloc_id ::= Efield tinfd alloc_id valPtr ;;;
      limit_id ::= Efield tinfd limit_id valPtr ;;;
      args_id ::= Efield tinfd args_id (Tarray uval max_args noattr);;;
      reserve_space ;;;
      asgn ;;;
      body
    in
    rest <- translate_fundefs_fast fnd' ;;
    ret ((f, Gfun (Internal (mk_fun vs (get_allocs e) body))) :: rest)
  end.

Definition make_extern_decl
           (nenv : name_env)
           (def : ident * globdef Clight.fundef type)
           (gv : bool) : option (ident * globdef Clight.fundef type) :=
  match def with
  | (f_id, Gfun (Internal f)) =>
    match M.get f_id nenv with
    | Some (nNamed f_string) =>
      Some (
        f_id,
        Gfun
          (External
            (EF_external f_string
              (signature_of_type (type_of_params (fn_params f))
                (fn_return f)
                (fn_callconv f)))
            (type_of_params (fn_params f))
            (fn_return f)
            (fn_callconv f)))
    | _ => None
    end
  | (v_id, Gvar (mkglobvar v_info v_init v_r v_v)) =>
    if gv
    then Some (v_id, Gvar (mkglobvar v_info nil v_r v_v))
    else None
  | _ => None
  end.

Fixpoint make_extern_decls (nenv : name_env)
         (defs : list (ident * globdef Clight.fundef type))
         (gv : bool) : list (ident * globdef Clight.fundef type) :=
  match defs with
  | fdefs :: defs' =>
    let decls := make_extern_decls nenv defs' gv in
    match make_extern_decl nenv fdefs gv with
    | Some decl => decl :: decls
    | None => decls
    end
  | nil => nil
  end.

Definition body_external_decl : positive * globdef Clight.fundef type :=
  let params := type_of_params ((tinfo_id, threadInf) :: nil) in
  (body_id,
   Gfun
     (External
       (EF_external
         ("body"%string)
         (signature_of_type params Tvoid cc_default))
      params Tvoid cc_default)).

Definition translate_funs (e : exp)
  : option (list (positive * globdef Clight.fundef type)) :=
  match e with
  | Efun fnd e => (* currently assuming e is body *)
    funs <- translate_fundefs fnd ;;
    let localVars := get_allocs e in (* ADD ALLOC ETC>>> HERE *)
    body <- translate_body e ;;
    '(gc_arr_id, _) <- M.get main_id fienv ;;
    let args_expr := Efield tinfd args_id (Tarray uval max_args noattr) in
    let fn :=
      mkfunction val cc_default ((tinfo_id, threadInf) :: nil)
        (map (fun x => (x, val)) localVars ++ (alloc_id, valPtr)
          :: (limit_id, valPtr) 
          :: (args_id, valPtr)
          :: nil)
        nil
        (alloc_id ::= Efield tinfd alloc_id valPtr ;;;
         limit_id ::= Efield tinfd limit_id valPtr ;;;
         args_id ::= args_expr ;;;
         reserve_body gc_arr_id 2%Z ;;;
         body ;;;
         Sreturn (Some (Field(args_expr, Z.of_nat 1))))
    in
    ret ((body_id, Gfun (Internal fn)) :: funs)
  | _ => None
  end.

Definition translate_funs_fast (e : exp)
  : option (list (positive * globdef Clight.fundef type)) :=
  match e with
  | Efun fnd e => (* currently assuming e is body *)
    funs <- translate_fundefs_fast fnd ;;
    let localVars := get_allocs e in (* ADD ALLOC ETC>>> HERE *)
    body <- translate_body e ;;
    '(gcArr_id, _) <- M.get main_id fienv ;;
    let fn :=
      mkfunction Tvoid cc_default ((tinfo_id, threadInf) :: nil)
        (map (fun x => (x, val)) localVars ++ (alloc_id, valPtr) 
          :: (limit_id, valPtr) 
          :: (args_id, valPtr)
          :: nil)
        nil
        (alloc_id ::= Efield tinfd alloc_id valPtr ;;;
         limit_id ::= Efield tinfd limit_id valPtr ;;;
         args_id ::= Efield tinfd args_id (Tarray uval max_args noattr);;;
         reserve_body gcArr_id 2%Z ;;;
         body)
    in
    ret ((body_id, Gfun (Internal fn)) :: funs)
  | _ => None
  end.

Definition nState := ExtLib.Data.Monads.StateMonad.state positive.

Definition get_name : nState positive :=
  n <- get ;;
  put (n+1)%positive ;;
  ret n.

Fixpoint make_ind_array (l : list N) : list init_data :=
  match l with
  | nil => nil
  | n :: l' => (Init_int (Z.of_N n)) :: (make_ind_array l')
  end.

(* representation of pos as string *)
Fixpoint pos2string' p s :=
  match p with
  | xI p' => pos2string' p' (String "1" s)
  | xO p' => pos2string' p' (String "0" s)
  | xH => String "1" s
  end.

(* Definition show_pos x :=  pos2string x. (*nat2string10 (Pos.to_nat x). *) *)

Definition update_name_env_fun_info (f f_inf : positive) (nenv : name_env) : name_env :=
  match M.get f nenv with
  | None => M.set f_inf (nNamed (append (show_pos f) "_info")) nenv
  | Some n =>
    match n with
    | nAnon => M.set f_inf (nNamed (append (append "x" (show_pos f)) "_info")) nenv
    | nNamed s => M.set f_inf (nNamed (append s "_info")) nenv
    end
  end.

End CODEGEN.

(* see runtime for description and uses of fundef_info.
  In summary,
  fi[0] = number of words that can be allocated by function
  fi[1] = number of live roots at startof function
  rest = indices of live roots in args array
*)

Fixpoint make_fundef_info (fnd : fundefs) (fenv : fun_env) (nenv : name_env)
  : nState (option (list (positive * globdef Clight.fundef type) * fun_info_env * name_env)) :=
  match fnd with
  | Fnil => ret (Some (nil, M.empty (positive * fun_tag), nenv))
  | Fcons x t vs e fnd' =>
    match M.get t fenv with
    | None => ret None
    | Some (n, l) =>
      rest <- make_fundef_info fnd' fenv nenv ;;
      match rest with
      | None => ret None
      | Some rest' =>
        let '(defs, map, nenv') := rest' in
        info_name <- get_name ;;
        let len := Z.of_nat (length l) in
        (* it should be the case that n (computed arity from tag) = len (actual arity) *)
        let ind :=
          mkglobvar
            (Tarray uval (len + 2%Z) noattr)
            (Init_int (Z.of_nat (max_allocs e)) :: Init_int len :: make_ind_array l)
            true false
        in
        ret (Some (
          (info_name, Gvar ind) :: defs,
          M.set x (info_name, t) map,
          update_name_env_fun_info x info_name nenv'))
      end
    end
  end.

Definition add_bodyinfo (e : exp) (fenv : fun_env) (nenv : name_env) (map : fun_info_env)
           (defs : list (positive * globdef Clight.fundef type)) :=
  info_name <- get_name ;;
  let ind :=
    mkglobvar
      (Tarray uval 2%Z noattr)
      (Init_int (Z.of_nat (max_allocs e)) :: Init_int 0%Z :: nil)
      true false
  in
  ret (Some (
    (info_name, Gvar ind) :: defs,
    M.set main_id (info_name, 1%positive) map,
    M.set info_name (nNamed "body_info"%string) nenv)).

(* Make fundef_info for functions in fnd (if any), and for the body of the program *)
Definition make_funinfo (e : exp) (fenv : fun_env) (nenv : name_env)
  : nState (option (list (positive * globdef Clight.fundef type) * fun_info_env * name_env)) :=
  match e with
  | Efun fnd e' =>
    p <- make_fundef_info fnd fenv nenv;;
    match p with
    | None => ret None
    | Some (defs, map, nenv') => add_bodyinfo e' fenv nenv' map defs
    end
  | _ => ret None
  end.

Definition global_defs (e : exp) : list (positive * globdef Clight.fundef type) :=
(*  let max_args := (Z.of_nat (max_pars e)) in
  (alloc_id, Gvar (mkglobvar valPtr ((Init_int(Int.zero)) :: nil) false false))
    :: (limit_id, Gvar (mkglobvar valPtr  ((Init_int(Int.zero)) :: nil) false false))
    :: (args_id, Gvar (mkglobvar (Tarray val max_args noattr)
                                    ((Init_int(Int.zero)) :: nil)
                                    false false))
    :: *)
  (gc_id,
   Gfun (External
     (EF_external "gc" (mksignature (val_typ :: nil) None cc_default))
     (Tcons (Tpointer val noattr) (Tcons threadInf Tnil))
     Tvoid
     cc_default)) ::
  (isptr_id,
   Gfun (External
     (EF_external "is_ptr" (mksignature (val_typ :: nil) None cc_default))
     (Tcons val Tnil)
     (Tint IBool Unsigned noattr)
     cc_default)) ::
  nil.

Definition make_defs (e : exp) (fenv : fun_env) (cenv: ctor_env)
           (ienv : n_ind_env) (nenv : M.t BasicAst.name)
  : nState (exceptionMonad.exception (M.t BasicAst.name * (list (positive * globdef Clight.fundef type)))) :=
  fun_info' <- make_funinfo e fenv nenv ;;
  match fun_info' with
  | Some (fun_info, map, nenv') =>
    match translate_funs cenv fenv map e with
    | None => ret (exceptionMonad.Exc "translate_funs")
    | Some fun_defs => ret (ret (nenv', global_defs e ++ fun_info ++ rev fun_defs))
    end
  | None => ret (exceptionMonad.Exc "make_funinfo")
  end.

Definition make_defs_fast (e : exp) (fenv : fun_env) (cenv: ctor_env)
           (ienv : n_ind_env) (nenv : M.t BasicAst.name)
  : nState (option (M.t BasicAst.name * (list (positive * globdef Clight.fundef type)))) :=
  fun_inf' <- make_funinfo e fenv nenv ;;
  match fun_inf' with
  | Some (fun_inf, map, nenv') =>
    match translate_funs_fast cenv fenv map e with
    | None => ret None
    | Some fun_defs => ret (Some (nenv', global_defs e ++ fun_inf ++ rev fun_defs))
    end
  | None => ret None
  end.

Definition composites : list composite_definition :=
  Composite thread_info_id Struct
    ((alloc_id, valPtr) ::
     (limit_id, valPtr) ::
     (heap_info_id, (tptr (Tstruct heap_info_id noattr))) ::
     (args_id, (Tarray uval max_args noattr)) ::
     nil) noattr ::
  nil.

Definition mk_prog_opt (defs : list (ident * globdef Clight.fundef type))
           (main : ident) (add_comp : bool) : option Clight.program :=
  let composites := if add_comp then composites else nil in
  let res := Ctypes.make_program composites defs (body_id :: nil) main in
  match res with
  | Error e => None
  | OK p => Some p
  end.

(* Wrap program in empty Efun if e.g. fully inlined *)
Definition wrap_in_fun (e:exp) : exp :=
  match e with
  | Efun fds e' => e
  | _ => Efun Fnil e
  end.

Definition add_inf_vars (nenv : name_env) : name_env :=
  M.set isptr_id (nNamed "is_ptr"%string) (
  M.set args_id (nNamed "args"%string) (
  M.set alloc_id (nNamed "alloc"%string) (
  M.set limit_id (nNamed "limit"%string) (
  M.set gc_id (nNamed "garbage_collect"%string) (
  M.set main_id (nNamed "main"%string) (
  M.set body_id (nNamed "body"%string) (
  M.set thread_info_id (nNamed "thread_info"%string) (
  M.set tinfo_id (nNamed "tinfo"%string) (
  M.set heap_info_id (nNamed "heap"%string) (
  M.set case_id (nNamed "arg"%string) (
  M.set num_args_id (nNamed "num_args"%string) nenv))))))))))).

Definition ensure_unique (l : M.t name) : M.t name :=
  M.map
    (fun x n =>
      match n with
      | nAnon => nAnon
      | nNamed s => nNamed (append s (append "_"%string (show_pos x)))
      end)
    l.

Fixpoint make_proj (recExpr : expr) (start : nat) (left : nat) : list expr :=
  match left with
  | 0 => nil
  | S n => Field(recExpr, Z.of_nat start) :: make_proj recExpr (S start) n
  end.

Fixpoint make_asgn (les : list expr) (res : list expr) :=
  match les, res with
  | hl :: les, hr :: res => hl :::= hr ;;; make_asgn les res
  | _, _ => Sskip
  end.

Fixpoint make_arg_list' (n : nat) (nenv : name_env) : nState (name_env * list (ident * type)) :=
  match n with
  | 0 => ret (nenv, nil)
  | S n' =>
    new_id <- get_name;;
    let new_name := append "arg" (nat2string10 n') in
    let nenv := M.set new_id (nNamed new_name) nenv in
    '(nenv, rest_id) <- make_arg_list' n' nenv;;
    ret (nenv, (new_id, val) :: rest_id)
  end.

Definition make_arg_list (n:nat) (nenv:name_env) : nState (name_env * list (ident * type)) :=
  '(nenv, rest_l) <- make_arg_list' n nenv;;
  ret (nenv, rev rest_l).

Fixpoint make_constrAsgn' (argv:ident) (argList:list (ident * type)) (n:nat) :=
  match argList with
  | nil => Sskip
  | (id, ty) :: argList' =>
    Field(var argv, Z.of_nat n) :::= Etempvar id ty ;;;
    make_constrAsgn' argv argList' (S n)
  end.

Definition make_constrAsgn (argv:ident) (argList:list (ident * type)) :=
 make_constrAsgn' argv argList 1.

(* Compute the header file comprising of:
   1) Constructors and eliminators for every inductive types in the n_ind_env
   2) Direct style calling functions for the original (named) functions *)

Fixpoint make_constructors (cenv : ctor_env) (n_ty : BasicAst.ident)
         (ctors : list ctor_ty_info) (nenv : name_env)
         : nState (name_env * (list (positive * globdef Clight.fundef type))) :=
  let make_name (n_ty nCtor : BasicAst.ident) : BasicAst.name :=
    nNamed (append "make_" (append n_ty (append "_" nCtor))) in
  match ctors with
  | nil => ret (nenv, nil)
  | {| ctor_name := nAnon |} :: ctors =>
    make_constructors cenv n_ty ctors nenv
  | {| ctor_name := nNamed nCtor ; ctor_arity := 0%N ; ctor_ordinal := ord |} :: ctors => (* unboxed *)
    constr_fun_id <- get_name;;
    let constr_body :=
      Sreturn (Some (Econst_int (Int.repr (Z.add (Z.shiftl (Z.of_N ord) 1) 1)) val)) in
    let constr_fun := Internal (mkfunction val cc_default nil nil nil constr_body) in
    let nenv :=
      M.set constr_fun_id (make_name n_ty nCtor) nenv in
    (* elet cFun :=  (Internal (mk_fun )) *)
    '(nenv, funs) <- make_constructors cenv n_ty ctors nenv ;;
    ret (nenv, (constr_fun_id,(Gfun constr_fun))::funs)
  | {| ctor_name := nNamed nCtor ; ctor_arity := Npos arr ; ctor_ordinal := ord |} :: ctors => (* boxed *)
    constr_fun_id <- get_name;;
    argv_id <- get_name;;
    '(nenv, arg_list) <- make_arg_list (Pos.to_nat arr) nenv;;
    let asgn_s := make_constrAsgn argv_id arg_list in
    let header := c_int (Z.of_N ((N.shiftl (Npos arr) 10) + ord)) val in
    let constr_body :=
        Sassign (Field(var argv_id, 0%Z)) header ;;;
        asgn_s ;;;
        Sreturn (Some (add (Evar argv_id argvTy) (c_int 1%Z val))) in
    let constr_fun := Internal (mkfunction val cc_default
                                  (arg_list ++ ((argv_id, argvTy) :: nil))
                                  nil nil constr_body) in
    let nenv :=
        M.set argv_id (nNamed "argv"%string) (
          M.set constr_fun_id (make_name n_ty nCtor) nenv) in
    (* elet cFun :=  (Internal (mk_fun )) *)
    '(nenv, funs) <- make_constructors cenv n_ty ctors nenv;;
    ret (nenv, (constr_fun_id, Gfun constr_fun) :: funs)
  end.

(* make a function discriminating over the different constructors of an inductive type *)

Notation char_ptr_ty := (Tpointer tschar noattr).
Notation name_ty := (Tpointer char_ptr_ty noattr).
Notation arity_ty := (Tpointer val noattr).

Definition make_elim_asgn (argv:ident) (val_id:ident) (arr:nat): statement :=
  let argv_proj := make_proj (var argv) 0%nat arr in
  let val_proj := make_proj (var val_id) 0%nat arr in
  make_asgn argv_proj val_proj.

Fixpoint asgn_string_init (s : string) : list init_data :=
  match s with
  | EmptyString => Init_int8 Int.zero :: nil
  | String c s' =>
    let i := Int.repr (Z.of_N (N_of_ascii c)) in
    Init_int8 i :: asgn_string_init s'
  end.

(* create a global variable with a string constant, return its id *)
Definition asgn_string_gv (s : string)
           : nState (ident * type * globdef Clight.fundef type) :=
  str_id <- get_name;;
  let len := String.length s in
  let init := asgn_string_init s in
  let ty := tarray tschar (Z.of_nat len) in
  let gv := Gvar (mkglobvar ty init true false) in
  ret (str_id, ty, gv).

Definition asgn_string
           (char_ptr:ident) (n:name)
           : nState (statement *  list (ident * globdef Clight.fundef type)) :=
  match n with
  | nAnon =>
    ret (Sassign (Field(Etempvar char_ptr char_ptr_ty, 0%Z)) (Econst_int (Int.repr 0%Z) tschar), nil)
  | nNamed s =>
    '(i, _, gv) <- asgn_string_gv  s;;
    ret (Sassign (Etempvar char_ptr char_ptr_ty) (Evar i char_ptr_ty), (i, gv) :: nil)
  end.

Definition make_arities_gv
           (arity_list : list N)
           : globdef Clight.fundef type :=
  Gvar (mkglobvar
    (tarray tint (Z.of_nat (length arity_list)))
    (List.map (fun n => Init_int (Z.of_N n)) arity_list)
    true false).

Definition pad_char_init (l : list init_data) (n :nat) : list init_data :=
  let m := n - (length l) in
  l ++ List.repeat (Init_int8 Int.zero) m.

Fixpoint make_names_init (nameList : list name) (n : nat) : nat * list init_data :=
  match nameList with
  | nil => (n, nil)
  | nNamed s :: nameList' =>
    let (max_len, init_l) := make_names_init nameList' (max n (String.length s + 1)) in
    let i := pad_char_init (asgn_string_init s) max_len in
    (max_len, i ++ init_l)
  | nAnon :: nameList' =>
    let (max_len, init_l) := make_names_init nameList' n in
    let i := pad_char_init (asgn_string_init "") max_len in
    (max_len, i ++ init_l)
  end.

Definition make_names_gv (nameList : list name) : globdef Clight.fundef type * type :=
  let (max_len, init_l) := make_names_init nameList 1 in
  let ty :=
    tarray
      (tarray tschar (Z.of_nat max_len))
      (Z.of_nat (length nameList))
  in
  (Gvar (mkglobvar ty init_l true false), ty).

Definition make_eliminator (itag : ind_tag) (cenv : ctor_env) (n_ty : BasicAst.ident)
           (ctors : list ctor_ty_info) (nenv : name_env)
           : nState (name_env * list (ident * globdef Clight.fundef type)) :=
  val_id <- get_name ;;
  ord_id <- get_name ;;
  argv_id <- get_name ;;
  elim_fun_id <- get_name ;;
  name_id <- get_name ;;
  gv_arities_id <- get_name ;;
  gv_names_id <- get_name ;;
  '(ls, ls', name_list, arr_list) <-
    (fix make_elim_cases
         (ctors : list ctor_ty_info)
         (currOrd : nat)
         : nState (labeled_statements * labeled_statements * list name * list N) :=
       match ctors with
       | nil => ret (LSnil, LSnil, nil, nil)
       | ctor :: ctors =>
         '(ls, ls', name_list, arr_list) <- make_elim_cases ctors (S currOrd) ;;
      (* name_p <- asgn_string name_id nName;;
         let '(name_s, name_gv) := name_p in *)
         let curr_s :=
           (* Ssequence (* name_s *) Sskip *)
           Field(var ord_id, 0%Z) :::= c_int (Z.of_nat currOrd) val ;;;
           make_elim_asgn argv_id val_id (N.to_nat (ctor_arity ctor)) ;;;
           Sbreak
         in
         let arity := ctor_arity ctor in
         match arity with
         | 0%N =>
           ret (
             ls,
             LScons (Some (Z.of_N (ctor_ordinal ctor))) curr_s ls',
             ctor_name ctor :: name_list,
             arity :: arr_list)
         | Npos p =>
           ret (
             LScons (Some (Z.of_N (ctor_ordinal ctor))) curr_s ls,
             ls',
             ctor_name ctor :: name_list,
             arity :: arr_list)
         end
       end) ctors 0 ;;
  let (gv_names, ty_gv_names) := make_names_gv name_list in
  let gv_arities := make_arities_gv arr_list in
  let elim_body := make_case_switch val_id ls ls' in
  let elim_fun :=
      Internal ({|
        fn_return := Tvoid;
        fn_callconv := cc_default;
        fn_params := ((valIdent, val) :: (ordIdent, valPtr) :: (argvIdent, argvTy) :: nil);
        fn_vars := nil;
        fn_temps := ((caseIdent, boolTy) :: nil);
        fn_body := elim_body;
      |}) in
  let nenv :=
    set_list
      ((gv_names_id, nNamed (append "names_of_" n_ty)) ::
       (gv_arities_id, nNamed (append "arities_of_" n_ty)) ::
       (ord_id, nNamed "ordinal"%string) ::
       (val_id, nNamed "val"%string) ::
       (argv_id, nNamed "argv"%string) ::
       (elim_fun_id, nNamed (append "elim_" n_ty)) ::
       nil)
      nenv
  in
  ret (
   nenv,
   (gv_names_id, gv_names) ::
   (gv_arities_id, gv_arities) ::
   (elim_fun_id, Gfun elim_fun) :: nil).

(* End Clight. (* hide the notations in the Clight section *) *)

Fixpoint make_interface (cenv : ctor_env) (ienv_list : list (ind_tag * n_ind_ty_info))
         (nenv : name_env) : nState (name_env * list (ident * globdef Clight.fundef type)) :=
  match ienv_list with
  | nil => ret (nenv, nil)
  (* skip anon-types *)
  | (_, (nAnon, _)) :: ienv_list' => make_interface cenv ienv_list' nenv
  | (itag, (nNamed n_ty, lCtr)) :: ienv_list' =>
    '(nenv, def1) <- make_constructors cenv n_ty lCtr nenv ;;
    '(nenv, def2) <- make_eliminator itag cenv n_ty lCtr nenv ;;
    '(nenv, def3) <- make_interface cenv ienv_list' nenv ;;
    ret (nenv, (def1 ++ def2 ++ def3))
  end.

Definition make_tinfo_id := 20%positive.
Definition export_id := 21%positive.

Definition make_tinfo_rec : positive * globdef Clight.fundef type :=
  (make_tinfo_id,
   Gfun (External
     (EF_external "make_tinfo" (mksignature (nil) (Some val_typ) cc_default))
     Tnil
     threadInf
     cc_default)).

Definition export_rec : positive * globdef Clight.fundef type :=
  (export_id,
   Gfun (External
     (EF_external "export" (mksignature (cons val_typ nil) (Some val_typ) cc_default))
     (Tcons threadInf Tnil)
     valPtr
     cc_default)).

(* generate a function equivalent to halt, received a tinfo, desired results is already in tinfo.args[1], and
 a halting continuation closure *)
Definition make_halt (nenv : name_env)
           : nState (name_env * (ident * globdef Clight.fundef type)
                              * (ident * globdef Clight.fundef type)) :=
  halt_id <- get_name;;
  halt_clo_id <- get_name;;
  let nenv :=
    M.set halt_clo_id (nNamed "halt_clo"%string) (
    M.set halt_id (nNamed "halt"%string) nenv)
  in
  ret (nenv,
       (haltIdent, Gfun (Internal ({|
          fn_return := Tvoid;
          fn_callconv := cc_default;
          fn_params := (tinfIdent, threadInf) :: nil;
          fn_vars := nil;
          fn_temps := nil;
          fn_body := Sreturn None
        |}))),
       (halt_cloIdent,
        Gvar (mkglobvar (tarray uval 2)
                        ((Init_addrof halt_id Ptrofs.zero) :: Init_int 1 :: nil)
                        true false))).

(* make b? call^n_export; call^n
call_export has n+1 arguments (all values), returns a value:
 a value containing the function closure
 followed by n arguments to the closure
the arguments are placed in args[2]...args[2+n-1]
halt is placed in args[1]
env is placed in args[0]
if b, then export the resulting value
TODO: fix the access to threadInf with Ederef
TODO: make a global threadinfo variable, make_tinfo if NULL, use it otherwise
 *)

Definition make_call
           (closExpr : expr)
           (f_id : ident)
           (env_id : ident)
           (argsExpr : expr)
           (arg_id : ident)
           (halt_id : ident) : statement :=
  f_id ::=  (Field(closExpr, Z.of_nat 0)) ;;;
  env_id ::= (Field(closExpr, Z.of_nat 1)) ;;;
  Field(argsExpr, Z.of_nat 0) :::= Etempvar env_id val ;;;
  Field(argsExpr, Z.of_nat 1) :::= Evar halt_id val ;;;
  Field(argsExpr, Z.of_nat 2) :::= Etempvar arg_id val ;;;
  Scall None ([pfunTy] (fun_var f_id)) (tinf :: nil).

Fixpoint make_n_calls
         (n : nat)
         (clos_id : ident)
         (f_id : ident)
         (env_id : ident)
         (argsExpr : expr)
         (argPairs : list (ident * type))
         (ret_id : ident)
         (halt_id : ident) : statement :=
  match n, argPairs with
  | 1, (arg_id, arg_ty) :: tl =>
    make_call (Etempvar clos_id valPtr) f_id env_id argsExpr arg_id halt_id
  | S (S n), (arg_id, _) :: tl =>
    let s := make_n_calls (S n) clos_id  f_id env_id argsExpr tl ret_id halt_id in
    s ;;;
    ret_id ::= Field(argsExpr, Z.of_nat 1) ;;;
    make_call (Etempvar ret_id valPtr) f_id env_id argsExpr arg_id halt_id
  | _, _ => Sskip
  end.

Definition make_call_n_export_b
           (nenv : name_env)
           (n : nat)
           (export : bool)
           (halt_id : ident)
           : nState (name_env * (ident * globdef Clight.fundef type)) :=
  call_id <- get_name ;;
  ret_id <- get_name ;;
  clo_id <- get_name ;;
  f_id <- get_name ;;
  env_id <- get_name ;;
  t <- make_arg_list n nenv ;;
  (*    let tinfo_s := if export then (Scall (Some tinf_id) (Evar make_tinfo_id make_tinfo_ty) nil) else Sskip in *)
  let tinfo_s := Sifthenelse (Ebinop Oeq (Evar tinfo_id threadInf)
                 (Ecast (Econst_int (Int.repr 0) tint) (tptr tvoid)) tint) (Scall (Some tinfo_id) (Evar make_tinfo_id make_tinfo_ty) nil) Sskip in
  let (nenv, argsL) := t in
  let argsS :=  (Efield tinfd args_id valPtr) in
  let left_args := make_proj argsS 2 n in
  let asgn_s := make_n_calls n clo_id f_id env_id argsS (rev argsL) ret_id halt_id in
  let export_s := if export then
                    Scall (Some ret_id) (Evar export_id export_ty) (cons tinf nil)
                  else
                     (ret_id ::= (Field(argsS, Z.of_nat 1))) in
  let body_s := Ssequence
                  (tinfo_s ;;; asgn_s)
                  (export_s ;;; Sreturn  (Some (Etempvar ret_id valPtr))) in
  let callStr := append "call_" (nat2string10 n) in
  let callStr := if export then append callStr "_export" else callStr in
  let nenv :=
    set_list ((env_id, nNamed "envi"%string) ::
              (clo_id, nNamed "clos"%string) ::
              (call_id, nNamed callStr) ::
              (f_id, nNamed "f"%string) ::
              (ret_id, nNamed "ret"%string) ::
              nil) nenv in
  (* if export, tinf is local, otherwise is a param *)
  let params := (clo_id, val) :: argsL in
  let vars := (f_id, valPtr) :: (env_id, valPtr) :: (ret_id, valPtr) :: nil in
  ret (nenv, (call_id, Gfun (Internal (mkfunction (Tpointer Tvoid noattr)
                                            cc_default params nil vars body_s)))).

Definition tinf_def : globdef Clight.fundef type :=
  Gvar (mkglobvar threadInf ((Init_space 4%Z)::nil) false false).

Definition make_empty_header
           (cenv : ctor_env)
           (ienv : n_ind_env)
           (e : exp)
           (nenv : name_env)
           : nState (option (name_env * list (ident * globdef Clight.fundef type))) :=
  ret (Some (nenv, nil)).

Definition make_header
           (cenv : ctor_env)
           (ienv : n_ind_env)
           (e : exp)
           (nenv : M.t BasicAst.name)
           : nState (option (M.t BasicAst.name  * (list (ident * globdef Clight.fundef type)))) :=
  (* l <- make_interface cenv (M.elements ienv) nenv;; *)
  (* let (nenv, inter_l) := l in *)
  l <- make_halt nenv ;;
  let  '(nenv, halt_f, (halt_clo_id, halt_clo_def)) := l in
  l <- make_call_n_export_b nenv 1 false halt_clo_id ;;
  let  '(nenv, call_0) := l in
  l <- make_call_n_export_b nenv 2 false halt_clo_id ;;
  let  '(nenv, call_2) := l in
  l <- make_call_n_export_b nenv 1 true halt_clo_id ;;
  let  '(nenv, call_1) := l in
  l <- make_call_n_export_b nenv 3 true halt_clo_id ;;
  let  '(nenv, call_3) := l in
  ret (Some (nenv, (halt_f :: (halt_clo_id, halt_clo_def) ::
                   (tinfo_id, tinf_def) ::
                   call_0 :: call_1 :: call_2 :: call_3 :: nil))).
(* end of header file *)

Definition compile (e : exp) (cenv : ctor_env) (nenv : M.t BasicAst.name) :
  exceptionMonad.exception (M.t BasicAst.name * option Clight.program * option Clight.program) :=
  let e := wrap_in_fun e in
  let fenv := compute_fun_env e in
  let ienv := compute_ind_env cenv in
  let p'' := make_defs e fenv cenv ienv nenv in
  let n := ((max_var e 100) + 1)%positive in
  let p' :=  (p''.(runState) n) in
  let m := snd p' in
  match fst p' with
  | exceptionMonad.Exc s => exceptionMonad.Exc (append "L6_to_Clight: Failure in make_defs:" s)
  | exceptionMonad.Ret p =>
    let '(nenv, defs) := p in
    let nenv := (add_inf_vars (ensure_unique nenv)) in
    let forward_defs := make_extern_decls nenv defs false in
    let header_pre := make_empty_header cenv ienv e nenv in
    (*     let header_p := (header_pre.(runState) m%positive) in *)
    let header_p := (header_pre.(runState) 1000000%positive) in (* should be m, but m causes collision in nenv for some reason *)
    (match fst header_p with
     | None => exceptionMonad.Exc "L6_to_Clight: Failure in make_header"
     | Some (nenv, hdefs) =>
       exceptionMonad.Ret
         ((M.set make_tinfo_id (nNamed "make_tinfo"%string)
                (M.set export_id (nNamed "export"%string) nenv),
          mk_prog_opt (body_external_decl ::
                      (make_extern_decls nenv hdefs true)) main_id false,
          mk_prog_opt (make_tinfo_rec :: export_rec ::
                      forward_defs ++ defs ++ hdefs) main_id true))
     end)
  end.


Definition compile_fast (e : exp) (cenv : ctor_env) (nenv : M.t BasicAst.name) :
  (M.t BasicAst.name * option Clight.program * option Clight.program) :=
  let e := wrap_in_fun e in
  let fenv := compute_fun_env e in
  let ienv := compute_ind_env cenv in
  let p'' := make_defs_fast e fenv cenv ienv nenv in
  let n := ((max_var e 100) + 1)%positive in
  let p' :=  (p''.(runState) n) in
  let m := snd p' in
  match fst p' with
  | None => (nenv, None, None)
  | Some (nenv, defs) =>
    let nenv := (add_inf_vars (ensure_unique nenv)) in
    let forward_defs := make_extern_decls nenv defs false in
    let header_pre := make_empty_header cenv ienv e nenv in
    (*     let header_p := (header_pre.(runState) m%positive) in *)
    let header_p := (header_pre.(runState) 1000000%positive) in (* should be m, but m causes collision in nenv for some reason *)
    (match fst header_p with
     | None => (nenv, None, None)
     | Some (nenv, hdefs) =>
       (M.set make_tinfo_id (nNamed "make_tinfo"%string)
              (M.set export_id (nNamed "export"%string) nenv),
        mk_prog_opt (body_external_decl ::
                     (make_extern_decls nenv hdefs true)) main_id false,
        mk_prog_opt (make_tinfo_rec :: export_rec ::
                     forward_defs ++ defs ++ hdefs) main_id true)
     end)
  end.

Definition err {A : Type} (s : String.string) : res A :=
  Error (MSG s :: nil).

Definition empty_program : Clight.program :=
  Build_program nil nil main_id nil eq_refl.

Definition stripOption (p : (option Clight.program)) : Clight.program :=
  match p with
  | None => empty_program
  | Some p' => p'
  end.

End TRANSLATION.
