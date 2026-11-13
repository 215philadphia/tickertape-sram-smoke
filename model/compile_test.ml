let pass name = Printf.printf "%-62s PASS\n%!" name
let fail name msg = Printf.printf "%-62s FAIL: %s\n%!" name msg
let check name f = try f (); pass name with
  | Failure m -> fail name m
  | e -> fail name (Printexc.to_string e)

let run_core (c : Compiler.compiled) ~p ~msb ~n ~host =
  let core = Pfst.create ~table:c.table ~p ~msb_first:msb ~reset_sel:c.reset_sel in
  Array.init n (fun k -> host core k; Pfst.step core ~raw_in:[| 0; 0; 0; 0 |] ~cmp:0)

let test_uart_tx () =
  check "DSL UART TX: compiles, decodes correctly" (fun () ->
      let bytes = [0x00; 0xFF; 0x55; 0xAA; 0x81; 0x42; 0x13; 0x96] in
      let c = Compiler.compile (Dsl_programs.uart_tx_dsl ()) in
      if c.num_states <> 2 then failwith (Printf.sprintf "expected 2 states, got %d" c.num_states);
      (* Start with a few idle cycles before the host has anything queued —
         a real host does too, and the reference decoder needs a preceding
         high sample to anchor its very first falling edge on. Without this,
         the array starts mid-transmission and byte 0 looks "missing" even
         though it decoded correctly; not an FSM bug. *)
      let q = ref bytes in
      let wave = run_core c ~p:1 ~msb:false ~n:(List.length bytes * 11 * Dsl_programs.bp + 50)
          ~host:(fun core k -> if k >= 5 then match !q with
              | h :: tl when not core.Pfst.tx_full -> ignore (Pfst.host_write core h); q := tl
              | _ -> ()) in
      let bits = Array.map (fun x -> x land 1) wave in
      let got, worst = Refs.uart_decode bits (float_of_int Dsl_programs.bp) in
      if got <> bytes then failwith "decoded bytes wrong";
      if worst > 0.01 then failwith (Printf.sprintf "edge error %.2f cyc" worst))

let test_uart_rx () =
  check "DSL UART RX: compiles, decodes correctly (0/+-1%% baud error)" (fun () ->
      let bytes = [0x00; 0xFF; 0x55; 0xAA; 0x81; 0x42; 0x13; 0x96] in
      let c = Compiler.compile (Dsl_programs.uart_rx_dsl ()) in
      if c.num_states <> 4 then failwith (Printf.sprintf "expected 4 states, got %d" c.num_states);
      let rng = Random.State.make [| 7 |] in
      List.iter (fun err ->
          let wave = Refs.uart_encode ~rng bytes (float_of_int Dsl_programs.bp) err 3.0 in
          let core = Pfst.create ~table:c.table ~p:1 ~msb_first:false ~reset_sel:c.reset_sel in
          Array.iter (fun bit -> ignore (Pfst.step core ~raw_in:[| bit; 0; 0; 0 |] ~cmp:0)) wave;
          let got = Pfst.rx_bytes_in_order core in
          if got <> bytes then
            failwith (Printf.sprintf "err=%.2f: got %d bytes, expected %d" err (List.length got) (List.length bytes)))
        [-0.01; 0.0; 0.01])

let test_spi_tx () =
  check "DSL SPI TX: compiles, decodes correctly" (fun () ->
      let bytes = [0x00; 0xFF; 0x55; 0xAA; 0x81; 0x42] in
      let c = Compiler.compile (Dsl_programs.spi_tx_dsl ()) in
      if c.num_states <> 4 then failwith (Printf.sprintf "expected 4 states, got %d" c.num_states);
      let q = ref bytes in
      let p = 4 in
      let wave = run_core c ~p ~msb:true ~n:(List.length bytes * 30 * p)
          ~host:(fun core k -> if k >= 5 then match !q with
              | h :: tl when not core.Pfst.tx_full -> ignore (Pfst.host_write core h); q := tl
              | _ -> ()) in
      let mosi = Array.map (fun x -> x land 1) wave
      and sck = Array.map (fun x -> (x lsr 1) land 1) wave
      and cs = Array.map (fun x -> (x lsr 2) land 1) wave in
      let got = Refs.spi_decode ~mosi ~sck ~cs in
      if got <> bytes then failwith "decoded bytes wrong")

let test_i2c_wr () =
  check "DSL I2C write-only: compiles, writes correctly, DONE reached" (fun () ->
      let c = Compiler.compile (Dsl_programs.i2c_wr_dsl ()) in
      if c.num_states <> 14 then failwith (Printf.sprintf "expected 14 states, got %d" c.num_states);
      let v : Refs.vector = { s = 4; p = 1; msb = true; reset_sel = c.reset_sel;
                              table = c.table; ints = [||]; ground = [||];
                              done_state = (let r = ref 0 in
                                            List.iteri (fun i n -> if n = "DONE" then r := i) c.names; !r) } in
      let txns : I2c_env.txn list = [
        { kind = `W; addr = 0x50; payload = [0x00; 0xFF; 0x55; 0xAA; 0x81; 0x42]; nread = 0; slave_data = [] };
        { kind = `W; addr = 0x51; payload = [0x12]; nread = 0; slave_data = [] };   (* wrong addr -> NACK *)
        { kind = `W; addr = 0x50; payload = [0x7E]; nread = 0; slave_data = [] };
      ] in
      let results, terr = I2c_env.run v txns in
      if terr <> [] then failwith (Printf.sprintf "%d bus timing violations" (List.length terr));
      List.iter (fun ((tx : I2c_env.txn), r) -> match r with
          | `Ok (timeout, _flag, _obit, written, _read, starts, stops) ->
            if timeout then failwith "core never reached DONE";
            if starts <> 1 || stops <> 1 then failwith "expected exactly 1 START and 1 STOP";
            let exp_w = if tx.addr = 0x50 then tx.payload else [] in
            if written <> exp_w then
              failwith (Printf.sprintf "addr %02x: written bytes wrong" tx.addr))
        results)

let test_nanotick_dsl () =
  check "DSL Nano-Tick trader: compiles, sends BUY on every crossing" (fun () ->
      let prog = Dsl_programs.nt_trader_dsl () in
      let c = Compiler.compile prog in
      if c.num_states <> 9 then failwith (Printf.sprintf "expected 9 states, got %d" c.num_states);
      let rx = Refs.load "nt_rx.vec" in     (* reuse the already-imported RX table from step 4 *)
      for seed = 0 to 4 do
        let rng = Random.State.make [| seed |] in
        let prices = Nanotick_env.price_stream ~rng 40 in
        let bp = 50_000_000.0 /. 115200.0 in
        let wave, _ = Nanotick_env.uart_wave ~rng prices bp in
        let c_rx = Pfst.create ~table:rx.table ~p:rx.p ~msb_first:rx.msb ~reset_sel:rx.reset_sel in
        let c_tr = Pfst.create ~table:c.table ~p:2 ~msb_first:prog.msb_first ~reset_sel:c.reset_sel in
        let orders = Nanotick_env.run ~rx_core:c_rx ~trader_core:c_tr ~wave ~msg:[| 0x42; 0x55; 0x59 |] in
        let exp = Nanotick_env.expected_trades prices in
        if List.length orders <> List.length exp then
          failwith (Printf.sprintf "seed %d: %d orders, expected %d" seed (List.length orders) (List.length exp));
        if not (List.for_all (fun (o : Nanotick_env.order) -> o.bytes = [0x42; 0x55; 0x59]) orders) then
          failwith (Printf.sprintf "seed %d: an order was not BUY" seed)
      done)

(* One shared wire: the core drives it only while dir[0] = 1 (PINMODE 3), otherwise
   the remote drives it or the pull-up holds it high. The remote answers each
   request with its bitwise inverse after a 2-bit turnaround. One independent
   decoder over the whole wire must see request, reply, request, reply, ...;
   any cycle where both sides drive is a failure. *)
let test_half_duplex () =
  check "DSL half-duplex UART (dir): request/reply on one wire, no contention" (fun () ->
      let c = Compiler.compile (Dsl_programs.hd_uart_dsl ()) in
      if c.num_states <> 6 then failwith (Printf.sprintf "expected 6 states, got %d" c.num_states);
      let bp = Dsl_programs.bp in
      let reqs = [0x00; 0xFF; 0x55; 0xA5; 0x3C] in
      let core = Pfst.create ~table:c.table ~p:1 ~msb_first:false ~reset_sel:c.reset_sel in
      let rng = Random.State.make [| 3 |] in
      let n = List.length reqs * 40 * bp in
      let wire = Array.make n 1 in
      let pending = ref reqs and waiting = ref false and got = ref 0 in
      let remote = ref [||] and r_t0 = ref 0 and drove_prev = ref false and released_at = ref (-1) in
      let f0 = ref 0 and f1 = ref 0 in          (* remote frame: first start-bit sample .. end of stop bit *)
      let contention = ref 0 and drove_ever = ref false in
      for k = 0 to n - 1 do
        let chip_drives = core.Pfst.dir land 1 = 1 in
        if chip_drives then drove_ever := true;
        if !drove_prev && not chip_drives then released_at := k;
        drove_prev := chip_drives;
        (* remote: after the chip releases following a request, wait 2 bits, then reply *)
        if !released_at >= 0 && k = !released_at + 2 * bp && Array.length !remote = 0 then begin
          let req = List.nth reqs (!got) in
          remote := Refs.uart_encode ~rng [req lxor 0xFF] (float_of_int bp) 0.0 0.0; r_t0 := k;
          let s0 = ref 0 in while !remote.(!s0) = 1 do incr s0 done;
          f0 := !s0; f1 := !s0 + 10 * bp
        end;
        let j = k - !r_t0 in
        let in_frame = Array.length !remote > 0 && j >= !f0 && j < !f1 in
        (* push-pull remote: drives its own levels for its whole frame, released outside it *)
        let remote_drives = in_frame in
        let remote_level = if in_frame then !remote.(j) else 1 in
        if chip_drives && in_frame then incr contention;
        if Array.length !remote > 0 && j >= Array.length !remote then (remote := [||]; released_at := -1);
        let w = if chip_drives then core.Pfst.out land 1 else if remote_drives then remote_level else 1 in
        wire.(k) <- w;
        (* host: one request at a time, next one only after its reply is saved *)
        let rx = List.length core.Pfst.rx_bytes in
        if !waiting && rx > !got then (incr got; waiting := false);
        if (not !waiting) && k > 20 then (match !pending with
            | h :: tl when not core.Pfst.tx_full -> ignore (Pfst.host_write core h); pending := tl; waiting := true
            | _ -> ());
        ignore (Pfst.step core ~raw_in:[| w; 0; 0; 0 |] ~cmp:0)
      done;
      if not !drove_ever then failwith "core never drove the wire";
      if !contention > 0 then failwith (Printf.sprintf "%d cycles of bus contention" !contention);
      let decoded, _ = Refs.uart_decode wire (float_of_int bp) in
      let expect = List.concat_map (fun r -> [r; r lxor 0xFF]) reqs in
      if decoded <> expect then
        failwith (Printf.sprintf "wire decoded %s" (String.concat " " (List.map (Printf.sprintf "%02x") decoded)));
      if Pfst.rx_bytes_in_order core <> List.map (fun r -> r lxor 0xFF) reqs then failwith "saved replies wrong")

(* PS/2 device-to-host waveform: per bit, CLK high for half_p cycles (DATA changes in the middle of
   that half), then low for half_p cycles; the host samples DATA while CLK is low. `bad_parity` and
   `bad_stop` corrupt that frame. Returns per-cycle (data, clk). *)
let ps2_wave ?(half_p = 30) ?(gap = 200) frames =
  let out = ref [] in
  let emit d c n = for _ = 1 to n do out := (d, c) :: !out done in
  emit 1 1 gap;
  List.iter (fun (b, bad_parity, bad_stop) ->
      let data = List.init 8 (fun k -> (b lsr k) land 1) in
      let ones = List.fold_left ( + ) 0 data in
      let par = (if ones mod 2 = 0 then 1 else 0) lxor (if bad_parity then 1 else 0) in
      let stop = if bad_stop then 0 else 1 in
      let prev = ref 1 in
      List.iter (fun d ->
          emit !prev 1 (half_p / 2); emit d 1 (half_p - half_p / 2); emit d 0 half_p; prev := d)
        ((0 :: data) @ [par; stop]);
      emit 1 1 gap)
    frames;
  Array.of_list (List.rev !out)

let test_ps2_rx () =
  check "DSL PS/2 RX (new protocol): bytes saved, parity/stop errors rejected" (fun () ->
      let c = Compiler.compile (Dsl_programs.ps2_rx_dsl ()) in
      if c.num_states <> 39 then failwith (Printf.sprintf "expected 39 states, got %d" c.num_states);
      let good = [0x00; 0xFF; 0x1C; 0xF0; 0x5A; 0x81] in
      let frames = List.map (fun b -> (b, false, false)) good
                   @ [(0x33, true, false); (0x44, false, true); (0x29, false, false)] in
      let core = Pfst.create ~table:c.table ~p:1 ~msb_first:false ~reset_sel:c.reset_sel in
      Array.iter (fun (d, k) -> ignore (Pfst.step core ~raw_in:[| d; k; 0; d |] ~cmp:0)) (ps2_wave frames);
      let got = Pfst.rx_bytes_in_order core in
      if got <> good @ [0x29] then
        failwith (Printf.sprintf "saved %s" (String.concat " " (List.map (Printf.sprintf "%02x") got))))

let expect_error name prog needle =
  check (Printf.sprintf "neg: %-46s (must be rejected)" name) (fun () ->
      match Compiler.compile (prog ()) with
      | _ -> failwith "SHOULD HAVE BEEN REJECTED: compiled without error"
      | exception Compiler.Compile_error msg ->
        if not (try ignore (Str.search_forward (Str.regexp_string needle) msg 0); true
                with Not_found -> false) then
          failwith (Printf.sprintf "rejected, but for the wrong reason: %s" msg))

let () =
  print_endline "-- DSL programs: compile, then run + independently decode on the";
  print_endline "   already-validated golden-model core --";
  test_uart_tx ();
  test_uart_rx ();
  test_spi_tx ();
  test_i2c_wr ();
  test_nanotick_dsl ();
  test_half_duplex ();
  test_ps2_rx ();
  print_endline "";
  print_endline "-- static checks: each control must be rejected at compile time,";
  print_endline "   before ever running --";
  expect_error "unreachable state" Dsl_programs.bad_unreachable "unreachable";
  expect_error "single-state deadlock trap" Dsl_programs.bad_deadlock "deadlock";
  expect_error "two-state deadlock cycle" Dsl_programs.bad_deadlock_cycle "deadlock";
  expect_error "transition to undeclared state" Dsl_programs.bad_undeclared_target "undeclared";
  expect_error "wait field out of range" Dsl_programs.bad_wait_range "range";
  expect_error "three inputs, no slot fits" Dsl_programs.bad_too_many_inputs "at most 2";
  expect_error "dir field out of range" Dsl_programs.bad_dir_range "dir 16";
  expect_error "65 states (chip holds 64)" Dsl_programs.bad_too_many_states "64";
  expect_error "real trap beside a legitimate declared terminal"
    Dsl_programs.bad_trap_beside_real_terminal "TRAP";
  check "terminals mechanism trusts an explicit (bad) declaration"
    (fun () -> ignore (Compiler.compile (Dsl_programs.trusts_bad_terminal_declaration ())))
