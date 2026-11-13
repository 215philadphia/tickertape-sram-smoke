(* Step 5: applicative, deep-embedded PFST compiler.

   Audit finding 9 (concept doc) was that a monadic DSL's bind hides its
   continuation inside an opaque OCaml closure, so the compiler can't walk
   the program without running it. This DSL never uses bind: a program is
   plain data — a list of named states, each carrying the (at most 2) input
   signals it reads and a total function from their values to a row. That's
   fully enumerable without executing anything host-language-dynamic, which
   is what lets `compile` below do reachability and deadlock analysis by
   just walking the data, the same way Python's Program.compile() did.

   Emits the same bit-table format pfst.ml and encode.py agree on, so a
   compiled program runs on the already-validated golden-model core and can
   be checked with the already-independent UART/SPI/I2C references. *)

type op = Hold | Shift | Load | Save
let op_code = function Hold -> 0 | Shift -> 1 | Load -> 2 | Save -> 3

type src = In0 | In1 | TxFull | In2 | CntZero | Obit | Cmp | In3
let slot_a = [| In0; In1; TxFull; In2 |]
let slot_b = [| CntZero; Obit; Cmp; In3 |]

(* dir (spec v1.1): per-row drive enable of out[3:0] for pins in PINMODE 3, word bits [28:25].
   0 = released; every pre-v1.1 program leaves it 0. *)
type row = { next : string; wait : int; out : int; osel : int; op : op; dir : int }

type state_def = {
  name : string;
  inputs : src list;               (* 0, 1 or 2 signals read at this state *)
  rowfn : bool array -> row;       (* values for `inputs`, in list order *)
}

type program = {
  pname : string;
  start : string;
  states : state_def list;         (* start need not be first; order fixes numbering *)
  msb_first : bool;
  terminals : string list;         (* states exempt from the deadlock check: by
                                       design they have no table edge back to
                                       `start` because the host, not the FSM,
                                       recovers them (spec v0.3 §7's DONE +
                                       RESTART convention). Declaring a state
                                       here is a claim the person compiling
                                       makes, not something this compiler can
                                       verify — get it wrong and a genuine trap
                                       passes silently. *)
}

exception Compile_error of string
let err fmt = Printf.ksprintf (fun s -> raise (Compile_error s)) fmt

let slot_index arr s = let r = ref (-1) in
  Array.iteri (fun i x -> if x = s then r := i) arr; !r

(* Every (state, input-combo) row, plus which slot each of the state's
   `inputs` landed in — mirrors encode.py's assign(). *)
let place_inputs st =
  match st.inputs with
  | [] -> (None, None)
  | [s] ->
    if slot_index slot_a s >= 0 then (Some s, None)
    else if slot_index slot_b s >= 0 then (None, Some s)
    else err "state %s: %s fits neither slot" st.name "input"
  | [s1; s2] ->
    let a1 = slot_index slot_a s1 >= 0 and a2 = slot_index slot_a s2 >= 0 in
    let b1 = slot_index slot_b s1 >= 0 and b2 = slot_index slot_b s2 >= 0 in
    if a1 && b2 then (Some s1, Some s2)
    else if a2 && b1 then (Some s2, Some s1)
    else err "state %s: %d inputs can't fill one slot each" st.name 2
  | _ -> err "state %s: at most 2 inputs per state, got %d" st.name (List.length st.inputs)

type compiled = {
  table : int array;
  num_states : int;
  names : string list;             (* index -> name, numbering order *)
  reset_sel : int * int;
  start_num : int;
}

let all_next_states st =
  let combos = match st.inputs with
    | [] -> [[||]] | [_] -> [[|false|]; [|true|]]
    | _ -> [[|false;false|]; [|false;true|]; [|true;false|]; [|true;true|]] in
  List.map (fun c -> (st.rowfn c).next) combos

let compile (p : program) =
  let by_name = Hashtbl.create 32 in
  List.iter (fun st ->
      if Hashtbl.mem by_name st.name then err "duplicate state %s" st.name;
      Hashtbl.replace by_name st.name st) p.states;
  if not (Hashtbl.mem by_name p.start) then err "start state %s not declared" p.start;
  (* Reachability: forward BFS over the union of transitions each state's
     rows can take, across every input combination that state reads. *)
  let names_order = List.map (fun st -> st.name) p.states in
  let edges = Hashtbl.create 32 in
  List.iter (fun st -> Hashtbl.replace edges st.name (all_next_states st)) p.states;
  List.iter (fun st ->
      List.iter (fun n -> if not (Hashtbl.mem by_name n) then
                    err "state %s transitions to undeclared state %s" st.name n)
        (Hashtbl.find edges st.name))
    p.states;
  let bfs seed adj =
    let seen = Hashtbl.create 32 and q = Queue.create () in
    Hashtbl.replace seen seed (); Queue.push seed q;
    while not (Queue.is_empty q) do
      let s = Queue.pop q in
      List.iter (fun n -> if not (Hashtbl.mem seen n) then
                    (Hashtbl.replace seen n (); Queue.push n q))
        (adj s)
    done; seen
  in
  let reachable = bfs p.start (fun s -> Hashtbl.find edges s) in
  let unreachable = List.filter (fun n -> not (Hashtbl.mem reachable n)) names_order in
  if unreachable <> [] then
    err "unreachable state(s): %s" (String.concat ", " unreachable);
  (* Deadlock / trap check: from every reachable state, either the start
     state or a declared terminal must still be reachable — i.e. no input
     sequence can strand the engine somewhere it can never be recovered
     from, by the FSM's own edges or by a host RESTART. This is the general
     form of the bug the I2C abort path had (stale TX byte, no path back to
     a state that would accept a fresh transaction) before §7's DONE/RESTART
     convention — but §7's own DONE state is legitimately a table sink (the
     host recovers it externally), which a first version of this check
     didn't know how to tell apart from a real trap: it flagged every state
     in a DONE-terminated program, since every state's only edge eventually
     leads to a state with no outgoing edge back to start. `terminals`
     exists so a program can say which sinks are intentional. *)
  List.iter (fun n -> if not (Hashtbl.mem by_name n) then
                err "declared terminal %s is not a state in this program" n)
    p.terminals;
  let reverse_edges = Hashtbl.create 32 in
  Hashtbl.iter (fun s ns -> List.iter (fun n ->
      Hashtbl.replace reverse_edges n (s :: (try Hashtbl.find reverse_edges n with Not_found -> [])))
      ns) edges;
  let back s = try Hashtbl.find reverse_edges s with Not_found -> [] in
  let recoverable = bfs p.start back in
  List.iter (fun t -> Hashtbl.iter (fun s () -> Hashtbl.replace recoverable s ()) (bfs t back))
    p.terminals;
  let trapped = List.filter (fun n -> Hashtbl.mem reachable n && not (Hashtbl.mem recoverable n))
      names_order in
  if trapped <> [] then
    err "state(s) can never return to %s or a declared terminal: %s (deadlock trap)"
      p.start (String.concat ", " trapped);
  (* Numbering and encoding *)
  let names = p.start :: List.filter (fun n -> n <> p.start) names_order in
  let num = Hashtbl.create 32 in
  List.iteri (fun i n -> Hashtbl.replace num n i) names;
  let n_states = List.length names in
  if n_states > 64 then err "%d states: the chip has 64 (6-bit state field; bits [28:25] belong to dir)" n_states;
  let s_bits = if n_states <= 1 then 1 else
      let b = ref 0 in while (1 lsl !b) < n_states do incr b done; !b in
  let table = Array.make (4 * n_states) 0 in
  List.iter (fun st ->
      let sa, sb = place_inputs st in
      (* Every table address this state's slot indices can produce must hold
         a row: a slot the state doesn't read is still sampled at runtime
         (whatever the previous row's selA/selB left it pointing at), so a
         don't-care slot's two values get duplicate rows, not a gap — the
         same convention encode.py uses, and for the same reason: leaving
         an address unfilled (defaulting to word 0) is a live bug, not a
         theoretical one, since nothing stops that address from actually
         being addressed. *)
      let combos : (bool array * (int * int)) list = match st.inputs with
        | [] -> [ ([||], (0,0)); ([||], (0,1)); ([||], (1,0)); ([||], (1,1)) ]
        | [_] when sa <> None ->
          [ ([|false|], (0,0)); ([|false|], (0,1)); ([|true|], (1,0)); ([|true|], (1,1)) ]
        | [_] ->
          [ ([|false|], (0,0)); ([|true|], (0,1)); ([|false|], (1,0)); ([|true|], (1,1)) ]
        | [s1; s2] ->
          let ord_a, ord_b = if sa = Some s1 then (0, 1) else (1, 0) in
          List.map (fun c -> (c, ((if c.(ord_a) then 1 else 0), (if c.(ord_b) then 1 else 0))))
            [ [|false;false|]; [|false;true|]; [|true;false|]; [|true;true|] ]
        | _ -> assert false
      in
      List.iter (fun (c, (a, b)) ->
          let r = st.rowfn c in
          if not (Hashtbl.mem by_name r.next) then err "unreachable next %s" r.next;
          if r.wait < 0 || r.wait > 255 then err "state %s: wait %d out of range" st.name r.wait;
          if r.out < 0 || r.out > 15 then err "state %s: out %d out of range" st.name r.out;
          if r.osel <> 0 && r.osel <> 1 then err "state %s: osel must be 0/1" st.name;
          if r.dir < 0 || r.dir > 15 then err "state %s: dir %d out of range" st.name r.dir;
          let na, nb = place_inputs (Hashtbl.find by_name r.next) in
          let na_i = match na with Some s -> slot_index slot_a s | None -> 0 in
          let nb_i = match nb with Some s -> slot_index slot_b s | None -> 0 in
          let n_num = Hashtbl.find num r.next in
          let w = List.fold_left (fun w (v, bits) -> (w lsl bits) lor v) n_num
              [ (r.wait, 8); (r.out, 4); (r.osel, 1); (op_code r.op, 2); (na_i, 2); (nb_i, 2) ] in
          if w land (lnot ((1 lsl (s_bits + 19)) - 1)) <> 0 then
            err "state %s: word overflows %d bits" st.name (s_bits + 19);
          let w = w lor (r.dir lsl 25) in            (* fixed position: the chip's state field is always 6 bits *)
          table.((Hashtbl.find num st.name lsl 2) lor (a lsl 1) lor b) <- w)
        combos)
    p.states;
  let start_st = Hashtbl.find by_name p.start in
  let ra, rb = place_inputs start_st in
  let reset_sel = ((match ra with Some s -> slot_index slot_a s | None -> 0),
                    (match rb with Some s -> slot_index slot_b s | None -> 0)) in
  { table; num_states = n_states; names; reset_sel; start_num = 0 }
