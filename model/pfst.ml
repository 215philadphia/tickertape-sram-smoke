(* PFST golden model: core execution engine.
   Independent implementation of spec v0.3 sections 2-5, executing a table
   that was compiled elsewhere (by encode.py today; by the OCaml compiler in
   step 7). This is the reference the RTL must match, not a program compiler:
   it takes an already-built table as input. *)

type op = Hold | Shift | Load | Save

let op_of_int = function
  | 0 -> Hold | 1 -> Shift | 2 -> Load | 3 -> Save
  | n -> invalid_arg (Printf.sprintf "op_of_int %d" n)

(* Slot sources, hardware-fixed (spec v0.3 section 5). *)
type src = In0 | In1 | TxFull | In2 | CntZero | Obit | Cmp | In3

let slot_a = [| In0; In1; TxFull; In2 |]
let slot_b = [| CntZero; Obit; Cmp; In3 |]

type t = {
  table : int array;
  mutable p : int;
  mutable msb_first : bool;
  mutable st : int;
  mutable timer : int;
  mutable sel_a : int;
  mutable sel_b : int;
  reset_sel : int * int;
  mutable sr : int;
  mutable obit : int;
  mutable cnt : int;
  mutable out : int;
  mutable tx_reg : int;
  mutable tx_full : bool;
  tx_queue : int Queue.t;              (* depth 2, the FIFO's tail *)
  mutable rx_bytes : int list;         (* newest first; caller reverses *)
  mutable scr : int;
  sync : int array;                    (* 4 synchronizer flip-flops, one per pin *)
  sync2 : int array;                   (* second flip-flop *)
}

let create ~table ~p ~msb_first ~reset_sel =
  { table; p; msb_first; st = 0; timer = 0;
    sel_a = fst reset_sel; sel_b = snd reset_sel; reset_sel;
    sr = 0; obit = 0; cnt = 0; out = 0;
    tx_reg = 0; tx_full = false; tx_queue = Queue.create ();
    rx_bytes = []; scr = 0;
    sync = Array.make 4 1; sync2 = Array.make 4 1 }

(* A host RESTART clears everything the table-execution state depends on,
   including the RX side: an earlier version left `rx_bytes` and `scr`
   untouched, so every caller that reused one `t` across transactions had
   to clear `rx_bytes` by hand afterward (one caller did; nothing enforced
   that the next one would). `scr` is included for the same reason, even
   though no caller currently depends on it: the function's name should
   mean what it says. Synchronizer state (`sync`/`sync2`) is deliberately
   left alone — those track actual external pin levels, which a soft
   core restart has no business resetting. *)
let restart c =
  c.st <- 0; c.timer <- 0;
  c.sel_a <- fst c.reset_sel; c.sel_b <- snd c.reset_sel;
  c.sr <- 0; c.obit <- 0; c.cnt <- 0; c.scr <- 0;
  c.tx_full <- false; Queue.clear c.tx_queue; c.rx_bytes <- []

(* Host push into the depth-3 TX FIFO (tx_reg + 2 queued). Returns false if full. *)
let host_write c b =
  if not c.tx_full then (c.tx_reg <- b; c.tx_full <- true; true)
  else if Queue.length c.tx_queue < 2 then (Queue.push b c.tx_queue; true)
  else false

let src_value c ~in_ ~cmp = function
  | In0 -> in_.(0) | In1 -> in_.(1) | In2 -> in_.(2) | In3 -> in_.(3)
  | TxFull -> if c.tx_full then 1 else 0
  | CntZero -> if c.cnt = 0 then 1 else 0
  | Obit -> c.obit
  | Cmp -> cmp

(* One clock edge. `raw_in` = 4 unsynchronized pin values (IN0..IN3), sampled
   this same edge into the synchronizer; `cmp` = the on-chip comparator bit,
   already registered upstream, so it needs no synchronizer. *)
let step c ~raw_in ~cmp =
  let synced = Array.copy c.sync2 in
  Array.blit c.sync 0 c.sync2 0 4;
  Array.blit raw_in 0 c.sync 0 4;
  if c.timer > 0 then (c.timer <- c.timer - 1; c.out)
  else begin
    let a = src_value c ~in_:synced ~cmp slot_a.(c.sel_a) in
    let b = src_value c ~in_:synced ~cmp slot_b.(c.sel_b) in
    let addr = (c.st lsl 2) lor (a lsl 1) lor b in
    let w = c.table.(addr) in
    let sel_b' = w land 3 in
    let sel_a' = (w lsr 2) land 3 in
    let op = op_of_int ((w lsr 4) land 3) in
    let osel = (w lsr 6) land 1 in
    let out = (w lsr 7) land 15 in
    let wait = (w lsr 11) land 255 in
    let nxt = w lsr 19 in
    (match op with
     | Hold -> ()
     | Shift ->
       let shin = synced.(0) in
       if c.msb_first then begin
         c.obit <- (c.sr lsr 7) land 1;
         c.sr <- ((c.sr lsl 1) lor shin) land 0xFF
       end else begin
         c.obit <- c.sr land 1;
         c.sr <- (c.sr lsr 1) lor (shin lsl 7)
       end;
       c.cnt <- max 0 (c.cnt - 1)
     | Load ->
       c.sr <- c.tx_reg; c.tx_full <- false; c.cnt <- 8;
       if not (Queue.is_empty c.tx_queue) then begin
         c.tx_reg <- Queue.pop c.tx_queue; c.tx_full <- true
       end
     | Save ->
       c.scr <- c.sr; c.rx_bytes <- c.sr :: c.rx_bytes);
    let obit_pin = if osel = 1 then c.obit else out land 1 in
    c.out <- (out land (lnot 1)) lor obit_pin;
    c.st <- nxt; c.sel_a <- sel_a'; c.sel_b <- sel_b';
    c.timer <- c.p * (1 + wait) - 1;
    c.out
  end

let rx_bytes_in_order c = List.rev c.rx_bytes
