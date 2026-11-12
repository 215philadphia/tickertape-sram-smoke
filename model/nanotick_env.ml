(* Independent Nano-Tick environment. Own price-stream generator (OCaml's
   Random, own regime logic, not transliterated from nanotick.py), own
   comparator/VALID orchestration (matches spec v0.3 section 3's definition:
   CMP <- VALID & SCR < THRESH, VALID set by the first SAVE), own SPI decode. *)

let thresh = 100

let price_stream ~rng n =
  let below = ref false in
  Array.init n (fun _ ->
      if Random.State.float rng 1.0 < 0.3 then below := not !below;
      if Random.State.float rng 1.0 < 0.15 then (if !below then thresh - 1 else thresh)
      else if !below then thresh - 1 - Random.State.int rng 60
      else thresh + Random.State.int rng 60)

(* One order each time the price enters the region below `thresh`. *)
let expected_trades prices =
  let below = ref false and out = ref [] in
  Array.iteri (fun k p ->
      if p < thresh && not !below then out := k :: !out;
      below := p < thresh)
    prices;
  List.rev !out

let uart_wave ~rng bytes bit_period =
  let t = ref (5.0 +. Random.State.float rng 45.0) in
  let edges = ref [] and stop_starts = ref [] in
  Array.iter (fun b ->
      let bits = 0 :: (List.init 8 (fun k -> (b lsr k) land 1)) @ [1] in
      List.iteri (fun k v -> edges := (!t +. float_of_int k *. bit_period, v) :: !edges) bits;
      stop_starts := (!t +. 9.0 *. bit_period) :: !stop_starts;
      t := !t +. 10.0 *. bit_period +. Random.State.float rng 3.0 *. bit_period)
    bytes;
  let edges = Array.of_list (List.rev !edges) in
  let total = int_of_float (!t +. 3.0 *. bit_period) in
  let wave = Array.make total 1 in
  let j = ref 0 and lvl = ref 1 in
  for n = 0 to total - 1 do
    while !j < Array.length edges && fst edges.(!j) <= float_of_int n do
      lvl := snd edges.(!j); incr j
    done;
    wave.(n) <- !lvl
  done;
  (wave, Array.of_list (List.rev !stop_starts))

type order = { t_cs : int; mutable bytes : int list; mutable t_end : int }

(* Runs rx_core (UART RX) and trader_core (SPI TX) together for `n` prices,
   with the comparator/VALID logic owned by this function, exactly as
   spec v0.3 section 3 defines it (not inside the core). *)
let run ~rx_core ~trader_core ~wave ~msg =
  let cmp = ref 0 and valid = ref false in
  let cs_prev = ref 1 and sck_prev = ref 0 and cur = ref None and bits = ref [] in
  let orders = ref [] in
  let fifo_next = ref 0 in
  let push3 core room =
    for _ = 1 to room do
      ignore (Pfst.host_write core msg.(!fifo_next));
      fifo_next := (!fifo_next + 1) mod (Array.length msg)
    done
  in
  push3 trader_core 1;
  let n_saved = ref 0 in
  Array.iteri (fun k rx_bit ->
      ignore (Pfst.step rx_core ~raw_in:[| rx_bit; 0; 0; 0 |] ~cmp:0);
      let n = List.length rx_core.Pfst.rx_bytes in
      if n <> !n_saved then (valid := true; n_saved := n);   (* VALID: set by the first SAVE *)
      let level = if !valid && rx_core.Pfst.scr < thresh then 1 else 0 in
      cmp := level;
      let pins = Pfst.step trader_core ~raw_in:[| 0; 0; 0; 0 |] ~cmp:!cmp in
      let room = if (not trader_core.Pfst.tx_full) then 1 else 0 in
      if room > 0 then push3 trader_core room;
      let cs = (pins lsr 2) land 1 and mosi = pins land 1 and sck = (pins lsr 1) land 1 in
      if !cs_prev = 1 && cs = 0 then (cur := Some { t_cs = k; bytes = []; t_end = 0 }; bits := []);
      if cs = 0 && sck = 1 && !sck_prev = 0 then begin
        bits := mosi :: !bits;
        if List.length !bits = 8 then begin
          let b = List.fold_left (fun a v -> a * 2 + v) 0 (List.rev !bits) in
          (match !cur with Some o -> o.bytes <- o.bytes @ [b] | None -> ());
          bits := []
        end
      end;
      if cs = 1 && !cs_prev = 0 then
        (match !cur with
         | Some o -> o.t_end <- k; orders := o :: !orders; cur := None
         | None -> ());
      cs_prev := cs; sck_prev := sck)
    wave;
  List.rev !orders
