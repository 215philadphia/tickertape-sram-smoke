(* Independent I2C environment: reactive open-drain slave and a fast-mode
   timing checker, written from the I2C spec, not transliterated from
   i2c.py's Slave/check_timing. Exercises the imported master table. *)

type mode = Idle | Rx | Acking | Tx | TxNext | MAck | Ignore

type slave = {
  addr : int;
  mutable read_data : int list;
  stretch_max : int;
  delay : int;
  mutable sda : int; mutable scl : int;
  mutable psda : int; mutable pscl : int;
  mutable mode : mode;
  mutable bits : int; mutable byte : int; mutable is_addr : bool; mutable rw : int;
  mutable cur : int; mutable sent : int;
  mutable written : int list;          (* newest first *)
  mutable starts : int; mutable stops : int;
  mutable stretch_left : int;
  mutable pending : (int * int) list;  (* (fire_at, value), oldest first *)
  mutable t : int;
}

let make_slave ~addr ~read_data ~stretch_max =
  { addr; read_data; stretch_max; delay = 3; sda = 1; scl = 1; psda = 1; pscl = 1;
    mode = Idle; bits = 0; byte = 0; is_addr = true; rw = 0; cur = 0; sent = 0;
    written = []; starts = 0; stops = 0; stretch_left = 0; pending = []; t = 0 }

let drive_later s v = s.pending <- s.pending @ [(s.t + s.delay, v)]

let observe s sda scl =
  s.t <- s.t + 1;
  if s.pscl = 1 && scl = 1 && s.psda <> sda then begin
    if sda = 0 then begin
      s.starts <- s.starts + 1; s.mode <- Rx; s.bits <- 0; s.byte <- 0; s.is_addr <- true
    end else begin
      s.stops <- s.stops + 1; s.mode <- Idle
    end;
    s.pending <- []; s.sda <- 1
  end else if s.pscl = 0 && scl = 1 then begin
    (match s.mode with
     | Rx -> s.byte <- (s.byte lsl 1) lor sda; s.bits <- s.bits + 1
     | MAck -> s.mode <- if sda = 0 then TxNext else Ignore
     | _ -> ())
  end else if s.pscl = 1 && scl = 0 then begin
    if s.stretch_max > 0 then s.stretch_left <- Random.int (s.stretch_max + 1);
    (match s.mode with
     | Rx when s.bits = 8 ->
       let ok =
         if s.is_addr then begin
           let a = s.byte lsr 1 and rw = s.byte land 1 in
           s.rw <- rw; a = s.addr
         end else begin
           s.written <- s.byte :: s.written; true
         end
       in
       if ok then (drive_later s 0; s.mode <- Acking) else s.mode <- Ignore
     | Acking ->
       if s.is_addr && s.rw = 1 then begin
         (match s.read_data with
          | h :: tl -> s.cur <- h; s.read_data <- tl
          | [] -> s.cur <- 0);
         s.mode <- Tx; s.sent <- 1; drive_later s ((s.cur lsr 7) land 1)
       end else begin
         drive_later s 1; s.mode <- Rx; s.bits <- 0; s.byte <- 0; s.is_addr <- false
       end
     | Tx ->
       if s.sent < 8 then begin
         drive_later s ((s.cur lsr (7 - s.sent)) land 1); s.sent <- s.sent + 1
       end else (drive_later s 1; s.mode <- MAck)
     | TxNext ->
       (match s.read_data with h :: tl -> s.cur <- h; s.read_data <- tl | [] -> s.cur <- 0);
       s.mode <- Tx; s.sent <- 1; drive_later s ((s.cur lsr 7) land 1)
     | Ignore -> drive_later s 1
     | _ -> ())
  end;
  let due, later = List.partition (fun (at, _) -> at <= s.t) s.pending in
  (match List.rev due with (_, v) :: _ -> s.sda <- v | [] -> ());
  s.pending <- later;
  s.scl <- (if s.stretch_left > 0 then 0 else 1);
  if s.stretch_left > 0 then s.stretch_left <- s.stretch_left - 1;
  s.psda <- sda; s.pscl <- scl

(* ---- fast-mode timing checker (400 kHz, 50 MHz clock => cycles) ------- *)
let t_low, t_high = 65, 30
let t_su_dat, t_hd_dat = 5, 15
let t_su_sta, t_hd_sta, t_su_sto, t_buf = 30, 30, 30, 65

let check_timing msda bsda bscl =
  let n = Array.length bscl in
  let rises = ref [] and falls = ref [] in
  for k = 1 to n - 1 do
    if bscl.(k) = 1 && bscl.(k - 1) = 0 then rises := k :: !rises;
    if bscl.(k) = 0 && bscl.(k - 1) = 1 then falls := k :: !falls
  done;
  let rises = Array.of_list (List.rev !rises) and falls = Array.of_list (List.rev !falls) in
  let next_after arr k = Array.fold_left (fun acc x -> if x > k && (acc < 0 || x < acc) then x else acc) (-1) arr in
  let prev_before arr k = Array.fold_left (fun acc x -> if x <= k && x > acc then x else acc) (-1) arr in
  let errs = ref [] in
  let add name k = errs := (name, k) :: !errs in
  Array.iter (fun f -> let r = next_after rises f in if r >= 0 && r - f < t_low then add "t_low" f) falls;
  Array.iter (fun r -> let f = next_after falls r in if f >= 0 && f - r < t_high then add "t_high" r) rises;
  let last_stop = ref (-1) in
  for k = 1 to n - 1 do
    if msda.(k) <> msda.(k - 1) then begin
      if bscl.(k) <> bscl.(k - 1) then add "sda_scl_same_cycle" k
      else if bscl.(k) = 1 then begin
        if msda.(k) = 0 then begin                    (* START *)
          let pr = prev_before rises k in
          if pr >= 0 && k - pr < t_su_sta then add "t_su_sta" k;
          let nf = next_after falls k in
          if nf >= 0 && nf - k < t_hd_sta then add "t_hd_sta" k;
          if !last_stop >= 0 && k - !last_stop < t_buf then add "t_buf" k
        end else begin                                 (* STOP *)
          let pr = prev_before rises k in
          if pr >= 0 && k - pr < t_su_sto then add "t_su_sto" k;
          last_stop := k
        end
      end else begin
        let pf = prev_before falls k in
        if pf >= 0 && k - pf < t_hd_dat then add "t_hd_dat" k;
        let nr = next_after rises k in
        if nr >= 0 && nr - k < t_su_dat then add "t_su_dat" k
      end
    end
  done;
  List.rev !errs

(* ---- run one master table through the slave, host-driven FIFO -------- *)
type txn = { kind : [`W | `R | `P]; addr : int; payload : int list; nread : int; slave_data : int list }

let run (v : Refs.vector) txns =
  let c = Pfst.create ~table:v.table ~p:v.p ~msb_first:v.msb ~reset_sel:v.reset_sel in
  let msda = ref 1 and mscl = ref 1 in
  let wm = ref [] and wb = ref [] and wc = ref [] in
  let results = ref [] in
  List.iter (fun tx ->
      let sl = make_slave ~addr:0x50 ~read_data:tx.slave_data ~stretch_max:0 in
      let hdr = (tx.addr lsl 1) lor (if tx.kind = `R then 1 else 0) in
      let q = ref (hdr :: (match tx.kind with
          | `W | `P -> tx.payload
          | `R -> List.init tx.nread (fun _ -> 0))) in
      Pfst.restart c;                 (* clears the rx_bytes log; SCR is kept, as on the chip *)
      let cyc = ref 0 and started = ref false and timeout = ref false in
      let flag = ref false in                    (* sticky, chip-level, not core-level *)
      while not (!started && c.Pfst.st = v.done_state && c.Pfst.timer = 0) && not !timeout do
        (match !q with h :: tl when Pfst.host_write c h -> q := tl | _ -> ());
        let bsda = !msda land sl.sda and bscl = !mscl land sl.scl in
        wm := !msda :: !wm; wb := bsda :: !wb; wc := bscl :: !wc;
        observe sl bsda bscl;
        let raw = [| bsda; bscl; 0; 0 |] in
        let pins = Pfst.step c ~raw_in:raw ~cmp:0 in
        if (pins lsr 3) land 1 = 1 then flag := true;
        msda := pins land 1; mscl := (pins lsr 1) land 1;
        if c.Pfst.st <> 0 then started := true;
        incr cyc;
        if !cyc > 400_000 then timeout := true
      done;
      let ok = tx.addr = 0x50 in
      let flag = !flag in
      let read = Pfst.rx_bytes_in_order c in
      results := (tx, `Ok (!timeout, ok, flag, List.rev sl.written, read, sl.starts, sl.stops)) :: !results)
    txns;
  let terr = check_timing (Array.of_list (List.rev !wm)) (Array.of_list (List.rev !wb))
      (Array.of_list (List.rev !wc)) in
  (List.rev !results, terr)
