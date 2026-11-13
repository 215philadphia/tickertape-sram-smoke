let pass name = Printf.printf "%-58s PASS\n%!" name
let fail name msg = Printf.printf "%-58s FAIL: %s\n%!" name msg
let check name f = try f (); pass name with
  | Failure m -> fail name m
  | e -> fail name (Printexc.to_string e)

(* ---------------------------------------------------------- UART TX / SPI *)
let run_tx_like ?n v =
  let c = Pfst.create ~table:v.Refs.table ~p:v.p ~msb_first:v.msb ~reset_sel:v.reset_sel in
  let q = ref (Array.to_list v.ints) in
  let n = match n with Some n -> n | None ->
    if Array.length v.ground > 0 then Array.length v.ground else 20000 in
  Array.init n (fun _ ->
      (match !q with h :: tl when not c.Pfst.tx_full -> Pfst.host_write c h |> ignore; q := tl | _ -> ());
      Pfst.step c ~raw_in:[| 0; 0; 0; 0 |] ~cmp:0)

let test_uart_tx path =
  check (Printf.sprintf "UART TX cross-check bit-exact  (%s)" path) (fun () ->
      let v = Refs.load path in
      let wave = run_tx_like v in
      if wave <> v.ground then failwith "waveform differs from Python's own trace";
      (* The wave is sampled once per real clock cycle regardless of P: P only
         groups wait counts inside the core, it doesn't change what a cycle
         of simulated output represents. *)
      let bp = 50_000_000.0 /. 115200.0 in
      let bits = Array.map (fun x -> x land 1) wave in
      let bytes, worst = Refs.uart_decode bits bp in
      if bytes <> Array.to_list v.ints then failwith "independent decode gave wrong bytes";
      if worst > 0.01 *. bp then failwith (Printf.sprintf "edge error %.2f cyc" worst))

let test_spi_tx path =
  check (Printf.sprintf "SPI TX cross-check bit-exact   (%s)" path) (fun () ->
      let v = Refs.load path in
      let sep = Array.to_list v.ground in
      let split l = let rec go acc = function
          | x :: tl when x = 1_000_000 -> (List.rev acc, tl)
          | x :: tl -> go (x :: acc) tl | [] -> (List.rev acc, []) in go [] l in
      let mosi_l, rest = split sep in
      let sck_l, cs_l = split rest in
      let mosi = Array.of_list mosi_l and sck = Array.of_list sck_l and cs = Array.of_list cs_l in
      let n = Array.length mosi in
      let wave = run_tx_like ~n v in
      let got_mosi = Array.map (fun x -> x land 1) wave in
      let got_sck = Array.map (fun x -> (x lsr 1) land 1) wave in
      let got_cs = Array.map (fun x -> (x lsr 2) land 1) wave in
      if got_mosi <> mosi then failwith "MOSI differs from Python's own trace";
      if got_sck <> sck || got_cs <> cs then failwith "SCK/CS differ from Python's own trace";
      let bytes = Refs.spi_decode ~mosi:got_mosi ~sck:got_sck ~cs:got_cs in
      if bytes <> Array.to_list v.ints then failwith "independent decode gave wrong bytes")

(* ---------------------------------------------------------- UART RX *)
let test_uart_rx path =
  check (Printf.sprintf "UART RX cross-check bit-exact  (%s)" path) (fun () ->
      let v = Refs.load path in
      let c = Pfst.create ~table:v.table ~p:v.p ~msb_first:v.msb ~reset_sel:v.reset_sel in
      let saves = ref [] in
      Array.iteri (fun k bit ->
          let before = List.length c.Pfst.rx_bytes in
          ignore (Pfst.step c ~raw_in:[| bit; 0; 0; 0 |] ~cmp:0);
          if List.length c.Pfst.rx_bytes <> before then saves := k :: !saves)
        v.ints;
      let got = Pfst.rx_bytes_in_order c in
      let neg1 = Array.to_list v.ground in
      let rec split acc = function -1 :: tl -> (List.rev acc, tl) | x :: tl -> split (x :: acc) tl | [] -> (List.rev acc, []) in
      let exp_bytes, exp_saves = split [] neg1 in
      if got <> exp_bytes then failwith "decoded bytes differ from Python's own trace";
      if List.rev !saves <> exp_saves then failwith "SAVE cycle indices differ from Python's own trace")

(* ---------------------------------------------------------- I2C *)
let i2c_standard_suite path ~full =
  let v = Refs.load path in
  let w = [0x00; 0xFF; 0x55; 0xAA; 0x81; 0x42] and rd = [0xC3; 0x00; 0xFF; 0x5A] in
  let base : I2c_env.txn list = [
    { kind = `W; addr = 0x50; payload = w; nread = 0; slave_data = [] };
    { kind = `W; addr = 0x51; payload = [0x12]; nread = 0; slave_data = [] };
    { kind = `W; addr = 0x50; payload = [0x7E]; nread = 0; slave_data = [] };
  ] in
  let txns = if full then base @ [
      { kind = `R; addr = 0x50; payload = []; nread = 4; slave_data = rd };
      { kind = `R; addr = 0x50; payload = []; nread = 1; slave_data = [0x99] };
      { kind = `R; addr = 0x51; payload = []; nread = 2; slave_data = [0x11; 0x22] };
    ] else base in
  let results, terr = I2c_env.run v txns in
  List.iter (fun ((tx : I2c_env.txn), r) -> match r with
      | `Ok (timeout, ok, flag, written, read, starts, stops) ->
        if timeout then failwith "core never reached DONE";
        if flag <> not ok then failwith (Printf.sprintf "flag=%b expected %b" flag (not ok));
        if starts <> 1 || stops <> 1 then failwith "expected exactly 1 START and 1 STOP";
        let exp_w = if ok && tx.kind = `W then tx.payload else [] in
        if written <> exp_w then failwith "written bytes wrong";
        let exp_r = if ok && tx.kind = `R then
            (let rec take n = function [] -> [] | h :: tl -> if n = 0 then [] else h :: take (n-1) tl in
             take tx.nread tx.slave_data)
          else [] in
        if read <> exp_r then failwith "read bytes wrong")
    results;
  if terr <> [] then failwith (Printf.sprintf "%d timing violations" (List.length terr));
  List.length txns

let test_i2c path ~full =
  check (Printf.sprintf "I2C standard suite              (%s)" path) (fun () ->
      let n = i2c_standard_suite path ~full in
      if n < (if full then 6 else 3) then failwith "too few transactions run")

(* ---------------------------------------------------------- Nano-Tick *)
let nanotick_trial seed =
  let rx = Refs.load "nt_rx.vec" and tr = Refs.load "nt_trader.vec" in
  let rng = Random.State.make [| seed |] in
  let prices = Nanotick_env.price_stream ~rng 40 in
  let bp = 50_000_000.0 /. 115200.0 in
  let wave, _ = Nanotick_env.uart_wave ~rng prices bp in
  let c_rx = Pfst.create ~table:rx.table ~p:rx.p ~msb_first:rx.msb ~reset_sel:rx.reset_sel in
  let c_tr = Pfst.create ~table:tr.table ~p:tr.p ~msb_first:tr.msb ~reset_sel:tr.reset_sel in
  let msg = [| 0x42; 0x55; 0x59 |] in
  let orders = Nanotick_env.run ~rx_core:c_rx ~trader_core:c_tr ~wave ~msg in
  let exp = Nanotick_env.expected_trades prices in
  (List.length orders, List.length exp,
   List.for_all (fun (o : Nanotick_env.order) -> o.bytes = [0x42; 0x55; 0x59]) orders)

let test_nanotick () =
  check "Nano-Tick: orders match reference, all BUY " (fun () ->
      for seed = 0 to 14 do
        let n_got, n_exp, all_buy = nanotick_trial seed in
        if n_got <> n_exp then failwith (Printf.sprintf "seed %d: %d orders, expected %d" seed n_got n_exp);
        if not all_buy then failwith (Printf.sprintf "seed %d: an order was not BUY" seed)
      done)

(* ---------------------------------------------------------- negative controls *)
let corrupt_bit_in_table t idx bit = t.(idx) <- t.(idx) lxor (1 lsl bit)

let neg_corrupted_wait () =
  check "neg: one corrupted wait bit in UART RX table (must fail)" (fun () ->
      let v = Refs.load "uart_rx.vec" in
      let table = Array.copy v.table in
      corrupt_bit_in_table table 4 12;                (* flip a wait bit in a data-shift row *)
      let c = Pfst.create ~table ~p:v.p ~msb_first:v.msb ~reset_sel:v.reset_sel in
      Array.iter (fun bit -> ignore (Pfst.step c ~raw_in:[| bit; 0; 0; 0 |] ~cmp:0)) v.ints;
      if Pfst.rx_bytes_in_order c = Array.to_list v.ints then
        failwith "SHOULD HAVE FAILED: corrupted table still decoded correctly")

let neg_no_valid_gate () =
  check "neg: comparator ungated by VALID (must trade at reset)" (fun () ->
      let rx = Refs.load "nt_rx.vec" and tr = Refs.load "nt_trader.vec" in
      let c_rx = Pfst.create ~table:rx.table ~p:rx.p ~msb_first:rx.msb ~reset_sel:rx.reset_sel in
      let c_tr = Pfst.create ~table:tr.table ~p:tr.p ~msb_first:tr.msb ~reset_sel:tr.reset_sel in
      ignore (Pfst.host_write c_tr 0x42);
      let fired_at_reset = ref false in
      for k = 0 to 50 do
        ignore (Pfst.step c_rx ~raw_in:[| 1; 0; 0; 0 |] ~cmp:0);
        (* ungated: cmp follows SCR < THRESH directly, no VALID *)
        let cmp = if c_rx.Pfst.scr < Nanotick_env.thresh then 1 else 0 in
        let pins = Pfst.step c_tr ~raw_in:[| 0; 0; 0; 0 |] ~cmp in
        if (pins lsr 2) land 1 = 0 && k > 0 then fired_at_reset := true
      done;
      if not !fired_at_reset then
        failwith "SHOULD HAVE FAILED: ungated comparator did not trade at reset (test is too weak)")

let neg_bad_reset_sel () =
  check "neg: wrong reset select on a late-writing host (must desync)" (fun () ->
      let v = Refs.load "uart_tx.vec" in
      let bad_reset_sel = (0, 0) in
      let c = Pfst.create ~table:v.table ~p:v.p ~msb_first:v.msb ~reset_sel:bad_reset_sel in
      for _ = 1 to 50 do ignore (Pfst.step c ~raw_in:[| 0; 0; 0; 0 |] ~cmp:0) done;
      ignore (Pfst.host_write c 0x42);
      let wave = Array.init 5000 (fun _ -> Pfst.step c ~raw_in:[| 0; 0; 0; 0 |] ~cmp:0) in
      let bits = Array.map (fun x -> x land 1) wave in
      let bp = 50_000_000.0 /. 115200.0 /. float_of_int v.p in
      match Refs.uart_decode bits bp with
      | [0x42], _ -> failwith "SHOULD HAVE FAILED: wrong reset select still decoded correctly"
      | _ -> ()
      | exception _ -> ())

let neg_corrupted_op () =
  check "neg: LOAD turned into HOLD in UART TX table (must fail)" (fun () ->
      let v = Refs.load "uart_tx.vec" in
      let table = Array.copy v.table in
      (* Find a row whose op field (bits 4-5) is LOAD (2), then clear op to HOLD
         at every table index holding that exact word: don't-care input slots
         are filled with identical duplicate rows, and a row at just one
         duplicate index (as this program's LOAD state happens to be) can go
         untouched by execution, which understated the first version of this
         control. *)
      let idx = ref (-1) in
      Array.iteri (fun i w -> if !idx < 0 && (w lsr 4) land 3 = 2 then idx := i) table;
      if !idx < 0 then failwith "test setup: no LOAD row found in table";
      let target = v.table.(!idx) in
      Array.iteri (fun i w -> if w = target then table.(i) <- w land (lnot (3 lsl 4))) table;
      let c = Pfst.create ~table ~p:v.p ~msb_first:v.msb ~reset_sel:v.reset_sel in
      let q = ref (Array.to_list v.ints) in
      let wave = Array.init (Array.length v.ground) (fun _ ->
          (match !q with h :: tl when not c.Pfst.tx_full -> ignore (Pfst.host_write c h); q := tl | _ -> ());
          Pfst.step c ~raw_in:[| 0; 0; 0; 0 |] ~cmp:0) in
      let bits = Array.map (fun x -> x land 1) wave in
      let bp = 50_000_000.0 /. 115200.0 in
      match Refs.uart_decode bits bp with
      | bytes, _ when bytes = Array.to_list v.ints ->
        failwith "SHOULD HAVE FAILED: corrupted op still decoded correctly"
      | _ -> ()
      | exception _ -> ())

(* Every visited address's row content, first-cut: run once against the real
   slave to see which (addr, word) pairs actually fire, so a corruption lands
   on a row execution depends on rather than an unreached duplicate. *)
let visited_rows (v : Refs.vector) txn =
  let c = Pfst.create ~table:v.table ~p:v.p ~msb_first:v.msb ~reset_sel:v.reset_sel in
  let sl = I2c_env.make_slave ~addr:0x50 ~read_data:[] ~stretch_max:0 in
  let q = ref ((txn : I2c_env.txn).addr * 2 :: txn.payload) in
  let msda = ref 1 and mscl = ref 1 and seen = Hashtbl.create 64 in
  for _ = 1 to 20_000 do
    (match !q with h :: tl when Pfst.host_write c h -> q := tl | _ -> ());
    let bsda = !msda land sl.sda and bscl = !mscl land sl.scl in
    I2c_env.observe sl bsda bscl;
    if c.Pfst.timer = 0 then begin
      let addr = (c.Pfst.st lsl 2) lor
                 ((Pfst.src_value c ~in_:[| bsda; bscl; 0; 0 |] ~cmp:0 Pfst.(slot_a.(c.sel_a))) lsl 1) lor
                 (Pfst.src_value c ~in_:[| bsda; bscl; 0; 0 |] ~cmp:0 Pfst.(slot_b.(c.sel_b))) in
      Hashtbl.replace seen addr v.table.(addr)
    end;
    let pins = Pfst.step c ~raw_in:[| bsda; bscl; 0; 0 |] ~cmp:0 in
    msda := pins land 1; mscl := (pins lsr 1) land 1
  done;
  Hashtbl.fold (fun k v acc -> (k, v) :: acc) seen []

let neg_restart_leaves_stale_rx () =
  check "neg: restart must clear rx_bytes/scr (stale read must not leak)" (fun () ->
      let v = Refs.load "i2c_wr.vec" in
      let txn : I2c_env.txn = { kind = `W; addr = 0x50; payload = [0x00]; nread = 0; slave_data = [] } in
      let c = Pfst.create ~table:v.table ~p:v.p ~msb_first:v.msb ~reset_sel:v.reset_sel in
      (* Dirty the core directly, bypassing I2c_env.run's own setup, then
         restart and confirm nothing from before the restart survives. *)
      ignore (Pfst.step c ~raw_in:[| 1; 1; 0; 0 |] ~cmp:0);
      c.Pfst.rx_bytes <- [0xAA; 0xBB]; c.Pfst.scr <- 0x42;
      Pfst.restart c;
      if c.Pfst.rx_bytes <> [] then failwith "rx_bytes survived a restart";
      if c.Pfst.scr <> 0 then failwith "scr survived a restart";
      let results, terr = I2c_env.run v [txn] in
      if terr <> [] then failwith "unrelated: timing violations after restart";
      match results with
      | [(_, `Ok (timeout, _, _, written, _, _, _))] ->
        if timeout then failwith "core never reached DONE after restart";
        if written <> [0x00] then failwith "wrong bytes written after restart"
      | _ -> failwith "unexpected result shape")

let neg_stop_too_short () =
  check "neg: bus-free time after STOP zeroed in I2C table (must trip timing checker)"
    (fun () ->
       let v = Refs.load "i2c_wr.vec" in
       let txn : I2c_env.txn = { kind = `W; addr = 0x50; payload = [0x00; 0xFF; 0x55]; nread = 0; slave_data = [] } in
       let rows = visited_rows v txn in
       (* The bus-free row after STOP is the one with the largest wait among
          visited rows: it holds both pins released the longest. Corrupting
          it only shows up against a SECOND transaction's START, since the
          check compares a STOP to the next START — one transaction alone
          never exercises it, which the first version of this control missed. *)
       let _, w = List.fold_left (fun (ba, bw) (a, w) ->
           let cur = (w lsr 11) land 255 and best = (bw lsr 11) land 255 in
           if cur > best then (a, w) else (ba, bw)) (List.hd rows) rows in
       let table = Array.copy v.table in
       Array.iteri (fun i x -> if x = w then table.(i) <- x land (lnot (255 lsl 11))) table;
       let _, terr = I2c_env.run { v with Refs.table } [txn; txn] in
       if terr = [] then
         failwith "SHOULD HAVE FAILED: zeroed bus-free time produced clean bus timing")

let () =
  print_endline "-- UART / SPI: bit-exact cross-check against the Python model, plus";
  print_endline "   independent decode (edge-timing checked for UART) --";
  test_uart_tx "uart_tx.vec";
  test_uart_rx "uart_rx.vec";
  test_uart_rx "uart_rx_early.vec";
  test_spi_tx "spi_tx.vec";
  print_endline "";
  print_endline "-- I2C: table imported from Python; slave, timing checker and host";
  print_endline "   driver freshly written in OCaml from the spec --";
  test_i2c "i2c_wr.vec" ~full:false;
  test_i2c "i2c_full.vec" ~full:true;
  print_endline "";
  print_endline "-- Nano-Tick: tables imported; price stream, VALID/CMP orchestration";
  print_endline "   and SPI decode freshly written in OCaml --";
  test_nanotick ();
  print_endline "";
  print_endline "-- negative controls --";
  neg_corrupted_wait ();
  neg_no_valid_gate ();
  neg_bad_reset_sel ();
  neg_corrupted_op ();
  neg_stop_too_short ();
  neg_restart_leaves_stale_rx ()
