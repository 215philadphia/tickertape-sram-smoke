(* Programs written directly in the step-5 DSL (compiler.ml), independent of
   the Python programs.py/i2c.py FSM constructions even though they target
   the same protocols — this is what the compiler is for. State counts here
   are expected to roughly match the earlier measured ones (spec v0.3 §8)
   since they're the same protocols under the same constraints (prescaler,
   counter, one row per bit), not because anything was copied. *)

open Compiler

let hold ?(out = 0) ?(osel = 0) ?(wait = 0) ?(dir = 0) next = { next; wait; out; osel; op = Hold; dir }
let shift ?(out = 0) ?(osel = 0) ?(wait = 0) ?(dir = 0) next = { next; wait; out; osel; op = Shift; dir }
let load ?(out = 0) ?(osel = 0) ?(wait = 0) ?(dir = 0) next = { next; wait; out; osel; op = Load; dir }
let save ?(out = 0) ?(osel = 0) ?(wait = 0) ?(dir = 0) next = { next; wait; out; osel; op = Save; dir }

let st name inputs rowfn = { name; inputs; rowfn }

(* Bit period in raw cycles at P=1, chosen small so tests run fast; the DSL
   and its compiler don't care what protocol speed this represents. *)
let bp = 40
let bw = bp - 1                        (* wait field for one full bit period *)

(* ---------------------------------------------------------------- UART TX *)
(* Counter version: IDLE waits for TX_FULL, LOAD, 8x SHIFT gated on
   CNT_ZERO, one STOP row, back to IDLE. *)
let uart_tx_dsl () =
  let states = [
    st "IDLE" [TxFull] (fun c -> if c.(0) then load ~wait:bw "DATA" else hold ~out:1 "IDLE");
    (* cnt_zero means the 8th shift already happened on the PREVIOUS fetch:
       this fetch IS the stop bit (drive the line high for one period, then
       straight to IDLE) — it is not a dead cycle before a separate stop
       state. A first draft gave it its own STOP state after a non-shifting
       hold here, which added an unintended 11th bit period to every frame
       (traced by dumping the waveform's run lengths: byte 0x00 showed 400
       low cycles — 10 periods — where 1 start + 8 zero data bits should
       give 9). It must not shift again either, for the same reason. *)
    st "DATA" [CntZero] (fun c -> if c.(0) then hold ~out:1 ~wait:bw "IDLE"
                           else shift ~out:1 ~osel:1 ~wait:bw "DATA");
  ] in
  { pname = "uart_tx_dsl"; start = "IDLE"; states; msb_first = false; terminals = [] }

(* ---------------------------------------------------------------- UART RX *)
(* SAVE at the stop bit (framing checked), counter version. CHK only
   verifies the start bit is still low at its centre — it must NOT shift,
   since sampling there is the start bit itself, not a data bit; the first
   real data-bit sample and shift happens on DATA's own first fetch, a full
   bit period later. (An earlier draft of this program shifted at CHK,
   which would have pulled the start bit into the shift register and put
   every data bit one position out of alignment — a genuine FSM bug, caught
   here before it ever reached the compiler, by tracing through what each
   row's own fetch actually samples.) *)
let uart_rx_dsl () =
  let half = bp / 2 - 1 in
  let states = [
    st "IDLE" [In0] (fun c -> if c.(0) then hold "IDLE" else load ~wait:half "CHK");
    st "CHK" [In0] (fun c -> if c.(0) then hold "IDLE" else hold ~wait:bw "DATA");
    (* The stop-bit sample lands mid-bit, so only about half a bit period of
       stop time is left; IDLE must be polling again well before the next
       start bit can arrive. Waiting a full bit period here (an earlier
       draft did) pushes IDLE's first poll roughly 1.5 periods after the
       stop sample instead of about 0.5, which is late enough to land
       inside a back-to-back next byte's own start bit and misalign every
       sample after it — found by tracing a byte that decoded wrong only at
       a near-zero inter-byte gap, and confirmed by checking the true frame
       boundaries (an independent scan matching the reference decoder's own
       algorithm) against where this FSM actually detected the edge: about
       22 cycles late on a 40-cycle bit. *)
    st "DATA" [In0; CntZero] (fun c ->
        if c.(1) then (if c.(0) then save ~wait:half "IDLE" else hold "FERR")
        else shift ~wait:bw "DATA");
    st "FERR" [In0] (fun c -> if c.(0) then hold "IDLE" else hold "FERR");
  ] in
  { pname = "uart_rx_dsl"; start = "IDLE"; states; msb_first = false; terminals = [] }

(* ----------------------------------------------------------------- SPI TX *)
(* Mode 0, MSB first, CS/MOSI/SCK on out[2:0]; hw=0 => half-period = P
   cycles. *)
let cs = 0b100 and sck = 0b010
(* cs = 0b100 is released (idle); asserted is 0. An earlier draft OR'd cs
   into H's output, releasing chip-select every half-clock along with SCK
   instead of holding it low for the whole byte — the decoded waveform's
   CS trace toggled in lockstep with SCK instead of framing all 8 bits,
   caught because the SPI decoder then saw 0 complete bytes. cs must stay
   out of L and H entirely: only IDLE (before) and END (after) release it. *)
let spi_tx_dsl () =
  let states = [
    st "IDLE" [TxFull] (fun c -> if c.(0) then load ~out:cs "L" else hold ~out:cs "IDLE");
    st "L" [] (fun _ -> shift ~osel:1 "H");
    st "H" [CntZero] (fun c -> if c.(0) then hold ~out:sck ~osel:1 "END"
                       else hold ~out:sck ~osel:1 "L");
    st "END" [] (fun _ -> hold ~out:cs ~wait:0 "IDLE");
  ] in
  { pname = "spi_tx_dsl"; start = "IDLE"; states; msb_first = true; terminals = [] }

(* ----------------------------------------------------------------- I2C ---- *)
(* Write-only I2C master, fast mode (400 kHz) at 50 MHz, P=1, written
   directly in the DSL — independent of i2c.py's construction even though
   it necessarily targets the same wire protocol (the timing constants below
   are the same real-world I2C minimums already used and validated
   elsewhere in this project, not copied FSM code). Pins: In0=SDA, In1=SCL,
   both open-drain (1=release, static per-pin host config); out bit0=SDA,
   bit1=SCL.
   Host protocol: TX <- addr<<1|0, then each data byte; empty TX at ACK ->
   STOP. Ends in DONE (no TX polling there), host RESTARTs to start a new
   transaction — exactly the convention that makes the deadlock-trap check
   meaningful here: an abort path that forgot to route through DONE would
   be exactly the class of bug this compiler is built to catch before it
   ever runs. *)
let rel = 0b11 and sda0 = 0b10 and scl0 = 0b01 and both0 = 0b00
let hold_t = 20 and setup_t = 50 and high_t = 55 and sta_t = 35 and buf_t = 70
let d c = c - 1                        (* wait field for c cycles at P=1 *)

let i2c_wr_dsl () =
  let states = [
    st "IDLE" [TxFull] (fun c -> if c.(0) then load ~out:rel "STA_A" else hold ~out:rel "IDLE");
    st "STA_A" [] (fun _ -> hold ~out:sda0 ~wait:(d sta_t) "STA_B");
    st "STA_B" [] (fun _ -> hold ~out:both0 ~wait:(d hold_t) "W_LO");
    (* SCL must be low here (the "clock low, data setup" phase) — an earlier
       draft used sda0 (SCL=1) by mistake, driving SCL high a full bit
       early. Only W_HW should raise SCL. *)
    st "W_LO" [] (fun _ -> shift ~out:both0 ~osel:1 ~wait:(d setup_t) "W_HW");
    (* poll_high pattern: release SCL and wait for it, in case the slave is
       clock-stretching; self-loop with wait 0 while it's still held low. *)
    st "W_HW" [In1] (fun c -> if c.(0) then hold ~out:sda0 ~osel:1 ~wait:(d high_t) "W_HC"
                       else hold ~out:sda0 ~osel:1 "W_HW");
    (* Neither branch shifts here: the bit was already shifted out on the
       W_LO row that led into this one. This row only holds SCL low for
       hold_t while deciding where to go next. An earlier draft used SHIFT
       (double-shifting every bit) and the wrong wait constant (setup_t
       instead of hold_t) on the "more bits to send" branch. *)
    st "W_HC" [CntZero] (fun c -> if c.(0) then hold ~out:both0 ~osel:1 ~wait:(d hold_t) "DA_LB"
                          else hold ~out:both0 ~osel:1 ~wait:(d hold_t) "W_LO");
    st "DA_LB" [] (fun _ -> hold ~out:scl0 ~wait:(d setup_t) "DA_HW");
    (* Both branches must drive the same output (rel: release SCL and let
       the slave pull it low if it's stretching). An earlier draft drove
       scl0 (SCL low) on the "still low" branch — the master's own output
       then held the bus low forever, so it could never observe its own
       polled signal go high, regardless of what the slave did. *)
    st "DA_HW" [In1] (fun c -> if c.(0) then hold ~out:rel ~wait:(d high_t) "DA_S"
                        else hold ~out:rel "DA_HW");
    st "DA_S" [In0] (fun c -> if c.(0) then hold ~out:scl0 ~wait:(d hold_t) "P_A"    (* NACK *)
                       else hold ~out:scl0 ~wait:(d hold_t) "WC");                   (* ACK *)
    st "WC" [TxFull] (fun c -> if c.(0) then load ~out:scl0 "W_LO" else hold ~out:scl0 "P_A");
    st "P_A" [] (fun _ -> hold ~out:both0 ~wait:(d setup_t) "P_B");
    st "P_B" [In1] (fun c -> if c.(0) then hold ~out:sda0 ~wait:(d sta_t) "P_C"
                      else hold ~out:sda0 "P_B");
    st "P_C" [] (fun _ -> hold ~out:rel ~wait:(d buf_t) "DONE");
    st "DONE" [] (fun _ -> hold ~out:rel "DONE");
  ] in
  { pname = "i2c_wr_dsl"; start = "IDLE"; states; msb_first = true; terminals = ["DONE"] }

(* ------------------------------------------------------- Nano-Tick trader *)
(* Fixed 3-byte message ("BUY"), independent of nanotick.py's construction.
   ARM waits on CMP, LOADs and starts the first byte; each byte is 8 SHIFTs
   gated on CNT_ZERO, with the LOAD for the next byte folded into the last
   SHIFT's transition (so the message length is fixed by the program, not
   by how full the host keeps the FIFO — the correctness property spec v0.3
   section 7 requires); after the 3rd byte, wait for CMP to clear (WCLR)
   before re-arming, so a sustained crossing fires once, not repeatedly. *)
let nt_trader_dsl () =
  let states = [
    st "ARM" [Cmp] (fun c -> if c.(0) then load ~out:0 "L1" else hold ~out:cs "ARM");
    st "L1" [] (fun _ -> shift ~osel:1 "H1");
    (* The H state's job is to hold SCK high while keeping the already-
       shifted bit steady on MOSI — the shift itself happens once, on the
       following L state's own fetch. An earlier draft used `shift` here
       too, doubling every bit: SR advanced and CNT decremented twice per
       intended bit, so a byte finished after 4 real clock pulses instead
       of 8, with garbled data. Caught because the SPI decoder never saw a
       complete first byte. *)
    st "H1" [CntZero] (fun c -> if c.(0) then load ~out:sck ~osel:1 "L2" else hold ~out:sck ~osel:1 "L1");
    st "L2" [] (fun _ -> shift ~osel:1 "H2");
    st "H2" [CntZero] (fun c -> if c.(0) then load ~out:sck ~osel:1 "L3" else hold ~out:sck ~osel:1 "L2");
    st "L3" [] (fun _ -> shift ~osel:1 "H3");
    st "H3" [CntZero] (fun c -> if c.(0) then hold ~out:sck ~osel:1 "END" else hold ~out:sck ~osel:1 "L3");
    st "END" [] (fun _ -> hold ~out:cs "WCLR");
    st "WCLR" [Cmp] (fun c -> if c.(0) then hold ~out:cs "WCLR" else hold ~out:cs "ARM");
  ] in
  { pname = "nt_trader_dsl"; start = "ARM"; states; msb_first = true; terminals = [] }

(* ------------------------------------------------------- PS/2 receiver *)
(* A protocol the chip was not designed around: PS/2 device-to-host frames (keyboard or mouse).
   The device drives both lines; the host samples DATA on each CLK falling edge. A frame is a
   start bit (0), 8 data bits LSB first, an ODD parity bit and a stop bit (1).

   The core has no parity hardware, so parity is carried in the state number: every data-bit
   state exists twice, once for "even number of ones so far" and once for "odd", and each sampled
   bit picks which copy comes next. The DSL is plain OCaml, so the 30 bit states are generated by
   a loop instead of written out. A good frame is SAVEd; a bad start, parity or stop bit instead
   raises out[3], which sets the sticky FLAG when CFG.flag_mode is on.

   Pin mapping (host INMAP): DATA -> IN0 (the SHIFT input) and also -> IN3, so a state can branch on
   DATA in slot B while CLK -> IN1 sits in slot A. No row waits: every row is one cycle at P=1, so
   the engine follows the device's clock edge by edge, whatever its speed. *)
let ps2_rx_dsl () =
  let clk = In1 and data = In3 in
  let flag = 0b1000 in
  let bit_h i p = Printf.sprintf "B%d_%s_H" i (if p = 0 then "E" else "O")
  and bit_l i p = Printf.sprintf "B%d_%s_L" i (if p = 0 then "E" else "O") in
  (* bit 0 is always reached with even parity: (0, odd) would be unreachable, and the compiler
     rejects unreachable states, so it is not generated *)
  let bits = List.concat_map (fun i -> List.filter_map (fun p ->
      if i = 0 && p = 1 then None else Some (i, p)) [0; 1]) (List.init 8 Fun.id) in
  let after i p d = let p' = p lxor (if d then 1 else 0) in
    if i < 7 then bit_h (i + 1) p' else Printf.sprintf "PAR_%s_H" (if p' = 0 then "E" else "O") in
  let data_states = List.concat_map (fun (i, p) -> [
      (* wait for CLK high, then for its falling edge *)
      st (bit_h i p) [clk] (fun c -> if c.(0) then hold (bit_l i p) else hold (bit_h i p));
      st (bit_l i p) [clk; data] (fun c ->
          if c.(0) then hold (bit_l i p) else shift (after i p c.(1)));
    ]) bits in
  let par p = let tag = if p = 0 then "E" else "O" in [
      st ("PAR_" ^ tag ^ "_H") [clk] (fun c -> if c.(0) then hold ("PAR_" ^ tag ^ "_L") else hold ("PAR_" ^ tag ^ "_H"));
      (* odd parity: ones in data + parity bit must be odd *)
      st ("PAR_" ^ tag ^ "_L") [clk; data] (fun c ->
          if c.(0) then hold ("PAR_" ^ tag ^ "_L")
          else if (p = 1) <> c.(1) then hold "STOP_H" else hold "ERR");
    ] in
  let states = [
    (* CLK falling with DATA low is a start bit *)
    st "IDLE" [clk; data] (fun c ->
        if c.(0) then hold "IDLE" else if c.(1) then hold "ERR" else hold (bit_h 0 0));
  ] @ data_states @ par 0 @ par 1 @ [
    st "STOP_H" [clk] (fun c -> if c.(0) then hold "STOP_L" else hold "STOP_H");
    st "STOP_L" [clk; data] (fun c ->
        if c.(0) then hold "STOP_L" else if c.(1) then save "REL" else hold "ERR");
    st "ERR" [] (fun _ -> hold ~out:flag "REL");
    (* wait for CLK to be released before looking for the next start bit *)
    st "REL" [clk] (fun c -> if c.(0) then hold "IDLE" else hold "REL");
  ] in
  { pname = "ps2_rx_dsl"; start = "IDLE"; states; msb_first = false; terminals = [] }

(* ---------------------------------------------------------- negative controls *)

(* An unreachable state: FERR2 is declared but nothing ever transitions to it. *)
let bad_unreachable () =
  let states = [
    st "IDLE" [In0] (fun c -> if c.(0) then hold "IDLE" else hold "IDLE");
    st "FERR2" [] (fun _ -> hold "IDLE");
  ] in
  { pname = "bad_unreachable"; start = "IDLE"; states; msb_first = false; terminals = [] }

(* A genuine deadlock trap: TRAP can be entered (on tx_full) but has no edge
   back to IDLE at all — exactly the class of bug the I2C abort path had
   before the spec's DONE/RESTART convention (a state the host can never
   recover the engine from). *)
let bad_deadlock () =
  let states = [
    st "IDLE" [TxFull] (fun c -> if c.(0) then load "TRAP" else hold "IDLE");
    st "TRAP" [] (fun _ -> hold "TRAP");
  ] in
  { pname = "bad_deadlock"; start = "IDLE"; states; msb_first = false; terminals = [] }

(* A subtler trap: A and B form a cycle with no edge leaving it, even though
   both are reachable from IDLE. Catches traps that aren't a single
   self-loop. *)
let bad_deadlock_cycle () =
  let states = [
    st "IDLE" [TxFull] (fun c -> if c.(0) then load "A" else hold "IDLE");
    st "A" [] (fun _ -> hold "B");
    st "B" [] (fun _ -> hold "A");
  ] in
  { pname = "bad_deadlock_cycle"; start = "IDLE"; states; msb_first = false; terminals = [] }

(* A row that references a state name never declared. *)
let bad_undeclared_target () =
  let states = [ st "IDLE" [] (fun _ -> hold "NOWHERE") ] in
  { pname = "bad_undeclared_target"; start = "IDLE"; states; msb_first = false; terminals = [] }

(* ------------------------------------------------------------- SPI target *)
(* The other side of spi_tx_dsl: a mode 0, MSB-first SPI TARGET (slave), full duplex.
   Pins: IN0 = MOSI, IN1 = SCK, IN3 = CS_n (active low); MISO = out[0] in PINMODE 3, so it is driven only in
   rows whose dir[0] = 1 and is released while CS_n is high, as a shared bus needs.
   Host side: push the reply bytes into the TX FIFO BEFORE CS_n falls; read each received byte with READ_SCR.
   How the byte is exchanged: SHIFT samples MOSI and, in the same op, moves the next outgoing bit onto OBIT.
   So the byte is pre-shifted once when CS_n falls (LOAD, then one SHIFT that shows bit 7 on MISO before the first
   clock edge). After that every rising SCK edge samples MOSI and puts the next MISO bit on the wire right after
   the edge, which a mode 0 master samples correctly at the following edge. Nine shifts per byte in total: the one
   junk bit sampled by the pre-shift is pushed out of SR by the eighth, so SR then holds exactly the received
   byte. The eight bit positions are unrolled (two states each), so no bit counter is needed and every state
   can watch CS_n: dropping CS_n in mid-byte returns to IDLE. After the last bit the byte is SAVEd and the next
   one is loaded for another byte in the same CS_n frame. An empty FIFO repeats the last byte sent. *)
let spi_tgt_dsl () =
  let sck = In1 and csn = In3 in
  let act = 0b0001 in                          (* dir[0]: drive MISO *)
  let wh i = Printf.sprintf "WH%d" i and wl i = Printf.sprintf "WL%d" i in
  let bit_states = List.concat_map (fun i -> [
      (* wait for the rising edge: sample MOSI and update MISO *)
      st (wh i) [sck; csn] (fun c ->
          if c.(0) then shift ~osel:1 ~dir:act (wl i)
          else if c.(1) then hold "IDLE"
          else hold ~osel:1 ~dir:act (wh i));
      (* wait for the falling edge; after the last bit, save the byte *)
      st (wl i) [sck; csn] (fun c ->
          if not c.(0) then
            (if i = 7 then save ~osel:1 ~dir:act "NEXT" else hold ~osel:1 ~dir:act (wh (i + 1)))
          else if c.(1) then hold "IDLE"
          else hold ~osel:1 ~dir:act (wl i));
    ]) (List.init 8 Fun.id) in
  let states = [
    st "IDLE" [csn] (fun c -> if c.(0) then hold "IDLE" else load ~dir:act "PRE");
    st "PRE" [] (fun _ -> shift ~osel:1 ~dir:act "WH0");
    st "NEXT" [csn] (fun c -> if c.(0) then hold "IDLE" else load ~osel:1 ~dir:act "PRE");
  ] @ bit_states in
  { pname = "spi_tgt_dsl"; start = "IDLE"; states; msb_first = true; terminals = [] }

(* A wait field out of range. *)
(* ------------------------------------------- half-duplex single-wire UART (v1.1) *)
(* One wire: out[0] on a PINMODE 3 pin, read back through IN0. Send one request
   byte from the FIFO while driving the wire (dir[0] = 1 on the start, data and
   stop bits), release it, receive one reply byte on the same wire and SAVE it,
   then wait one more bit period before idling so a fresh request can't start
   while the far end is still in its stop bit. Every other row releases the
   wire. The receive side uses LOAD only to set the bit counter, so the host
   must push the next request after the reply arrives (LOAD would consume it).
   No reply at all leaves the engine in RIDLE; the host recovers with RESTART. *)
let hd_uart_dsl () =
  let half = bp / 2 - 1 in
  let states = [
    st "TIDLE" [TxFull] (fun c -> if c.(0) then load ~dir:1 ~wait:bw "TDATA" else hold ~out:1 "TIDLE");
    st "TDATA" [CntZero] (fun c -> if c.(0) then hold ~out:1 ~dir:1 ~wait:bw "RIDLE"
                           else shift ~out:1 ~osel:1 ~dir:1 ~wait:bw "TDATA");
    st "RIDLE" [In0] (fun c -> if c.(0) then hold "RIDLE" else load ~wait:half "RCHK");
    st "RCHK" [In0] (fun c -> if c.(0) then hold "RIDLE" else hold ~wait:bw "RDATA");
    st "RDATA" [In0; CntZero] (fun c ->
        if c.(1) then (if c.(0) then save ~wait:bw "TIDLE" else hold "RFERR")
        else shift ~wait:bw "RDATA");
    st "RFERR" [In0] (fun c -> if c.(0) then hold "TIDLE" else hold "RFERR");
  ] in
  { pname = "hd_uart_dsl"; start = "TIDLE"; states; msb_first = false; terminals = [] }

let bad_dir_range () =
  let states = [ st "IDLE" [] (fun _ -> hold ~dir:16 "IDLE") ] in
  { pname = "bad_dir_range"; start = "IDLE"; states; msb_first = false; terminals = [] }

(* 65 states in a ring: one more than the chip's 6-bit state field holds. *)
let bad_too_many_states () =
  let name i = Printf.sprintf "S%d" i in
  let states = List.init 65 (fun i -> st (name i) [] (fun _ -> hold (name ((i + 1) mod 65)))) in
  { pname = "bad_too_many_states"; start = "S0"; states; msb_first = false; terminals = [] }

let bad_wait_range () =
  let states = [ st "IDLE" [] (fun _ -> hold ~wait:999 "IDLE") ] in
  { pname = "bad_wait_range"; start = "IDLE"; states; msb_first = false; terminals = [] }

(* A legitimate DONE-style terminal (declared, host-recoverable) sitting
   right next to a genuine, undeclared trap. The `terminals` mechanism must
   not paper over the real bug just because the program also has a correct
   terminal — the two states are unrelated, and only ONE of them is
   supposed to be unreachable-by-the-FSM-alone. *)
let bad_trap_beside_real_terminal () =
  let states = [
    st "IDLE" [TxFull] (fun c -> if c.(0) then load "WORKING" else hold "IDLE");
    st "WORKING" [CntZero] (fun c -> if c.(0) then hold "DONE" else hold "TRAP");
    st "DONE" [] (fun _ -> hold "DONE");     (* legitimate: host RESTARTs this *)
    st "TRAP" [] (fun _ -> hold "TRAP");     (* bug: nothing recovers this, and it isn't declared *)
  ] in
  { pname = "bad_trap_beside_real_terminal"; start = "IDLE"; states; msb_first = false;
    terminals = ["DONE"] }

(* The same program, but with the real trap ALSO (wrongly) declared as a
   terminal. This must still compile — declaring a terminal is a claim the
   compiler trusts, not one it can check — which is exactly why getting the
   declaration right is the person's responsibility, not the tool's. This
   isn't a `bad_*` control: it's expected to succeed, and demonstrates the
   trust boundary rather than testing a rejection. *)
let trusts_bad_terminal_declaration () =
  let states = [
    st "IDLE" [TxFull] (fun c -> if c.(0) then load "WORKING" else hold "IDLE");
    st "WORKING" [CntZero] (fun c -> if c.(0) then hold "DONE" else hold "TRAP");
    st "DONE" [] (fun _ -> hold "DONE");
    st "TRAP" [] (fun _ -> hold "TRAP");
  ] in
  { pname = "trusts_bad_terminal_declaration"; start = "IDLE"; states; msb_first = false;
    terminals = ["DONE"; "TRAP"] }

(* Three inputs at one state: neither slot can hold all of them. *)
let bad_too_many_inputs () =
  let states = [
    st "IDLE" [In0; In1; In2] (fun _ -> hold "IDLE");
  ] in
  { pname = "bad_too_many_inputs"; start = "IDLE"; states; msb_first = false; terminals = [] }

(* ================================================== 10BASE-T Ethernet (docs/ethernet.md) *)
(* All of these assume a 40 MHz chip clock: one bit time is 100 ns = 4 cycles and one Manchester half bit is
   50 ns = 2 cycles. At the 50 MHz signoff clock a half bit would be 2.5 cycles, which whole rows cannot make.
   Line pins of the transmitting core: out[0] = TD+, out[1] = TD-. "HI" is TD+ above TD- (IEEE 802.3 7.3.1.1). *)
let eth_hi = 0b01 and eth_lo = 0b10 and eth_idle = 0b00

(* Core 0 as a timer for core 1. The cores are linked by the comparator CMP = VALID0 & (SCR0 < THRESH), which only
   core 1 can branch on, so the core that needs a counter (core 1) borrows core 0 as one. Core 0 raises CMP by
   SAVEing a byte below THRESH and drops it by SHIFTing that byte left once (MSB first) and SAVEing again:
   with THRESH = 0x80 and a byte in 0x40..0x7F the shifted value is >= 0x80 whatever IN0 reads. *)

(* ---- link pulse timer (core 0, P = 256, MSB first, THRESH = 0x80, one byte 0x40..0x7F pushed at setup) ----
   CMP is high for the S and D rows and low for the rest of the period. The period is fixed by the table:
   (196 + 256 + 255 + 1) + 7 x 256 = 2500 rows-units of P = 256 cycles = 640 000 cycles = 16.000 ms at 40 MHz.
   The seven long rows are one state looping on the bit counter (LOAD sets it to 8, the D row and each W row
   shift once). The start state is W with the counter at 0, so the first row is the LOAD. After the setup byte
   is popped the FIFO is empty and LOAD reloads the same byte for ever, so nothing further is needed from the
   host. Until that byte is pushed LOAD returns 0, CMP stays high and no pulse is made. (A separate "wait for
   the byte" state would never be re-entered; the compiler rejects that as a deadlock trap.) *)
let nlp_timer_dsl () =
  let states = [
    st "S" [] (fun _ -> save ~wait:255 "D");
    st "D" [] (fun _ -> shift ~wait:254 "E");
    st "E" [] (fun _ -> save "W");
    st "W" [CntZero] (fun c -> if c.(0) then load ~wait:195 "S" else shift ~wait:255 "W");
  ] in
  { pname = "nlp_timer_dsl"; start = "W"; states; msb_first = true; terminals = [] }

(* ---- link pulse generator (core 1, P = 1): one 4-cycle (100 ns) HI pulse per rising edge of CMP ---- *)
let nlp_pulse_dsl () =
  let states = [
    st "IDLE" [Cmp] (fun c -> if c.(0) then hold ~out:eth_hi ~wait:3 "REL" else hold ~out:eth_idle "IDLE");
    st "REL" [Cmp] (fun c -> if c.(0) then hold ~out:eth_idle "REL" else hold ~out:eth_idle "IDLE");
  ] in
  { pname = "nlp_pulse_dsl"; start = "IDLE"; states; msb_first = false; terminals = [] }

(* ---- frame gate (core 0, P = 1, MSB first, THRESH = 0x80): CMP high for a fixed time per pushed byte ----
   The transmitter has no counter that could count the 62 bits of preamble, so core 0 times them: one byte
   0x40..0x7F pushed into core 0's FIFO raises CMP for eth_gate_w + 2 = 242 cycles (the ARM row and one more). The transmitter loops on its
   preamble square wave while CMP is high; it samples CMP every 8 cycles, so the gate edge has +-4 cycles of
   margin and is placed in the middle. *)
let eth_gate_w = 240
let eth_gate_dsl () =
  let states = [
    st "IDLE" [TxFull] (fun c -> if c.(0) then load "ARM" else hold "IDLE");
    st "ARM" [] (fun _ -> save ~wait:eth_gate_w "DROP");
    st "DROP" [] (fun _ -> shift "END");
    st "END" [] (fun _ -> save "IDLE");
  ] in
  { pname = "eth_gate_dsl"; start = "IDLE"; states; msb_first = true; terminals = [] }

(* ---- Manchester transmitter at 10 Mb/s (core 1, P = 1, LSB first) ----
   Frame: preamble and SFD (IEEE 802.3 3.2.1, 3.2.2: 62 bits 1010...10 then 11), the bytes in the TX FIFO LSB
   first (3.3), then the start of idle: HI for eth_etd cycles (14.3.1.2.1). A 1 is LO then HI, a 0 is HI then LO
   (7.3.1.1). Every row is 2 or 4 cycles, so every edge falls on a 50 ns grid.
   The preamble 1010...10 is a square wave of 4-cycle rows (PH, PL), repeated while CMP is high: 31 times.
   The last two bits (1, 1) are the rows T1..T3; T2 LOADs the first byte and T3 SHIFTs its first bit out.
   Data: a bit needs a row per half, and each row's level depends on the bit, so a state reads OBIT (slot B).
   CNT_ZERO is in slot B too, so the same state cannot also ask "was that the last bit?". The eight bit positions
   are therefore unrolled (F0/S0 .. F7/S7) and no counter is used; F7 reads OBIT with TX_FULL (slot A) to load the
   next byte or end the frame. F rows LOAD (bit 7 is already in OBIT), S rows SHIFT the next bit out. *)
let eth_etd = 12                           (* start of idle: 12 cycles = 300 ns HI *)
let eth_tx_dsl () =
  let first b = if b then eth_lo else eth_hi and second b = if b then eth_hi else eth_lo in
  let f i = Printf.sprintf "F%d" i and s i = Printf.sprintf "S%d" i in
  let bit_states = List.concat_map (fun i -> [
      st (f i) [Obit] (fun c -> hold ~out:(first c.(0)) ~wait:1 (s i));
      st (s i) [Obit] (fun c -> shift ~out:(second c.(0)) ~wait:1 (f (i + 1)));
    ]) (List.init 7 Fun.id) in
  let states = [
    st "IDLE" [Cmp] (fun c -> if c.(0) then hold ~out:eth_lo ~wait:1 "PH" else hold ~out:eth_idle "IDLE");
    st "PH" [] (fun _ -> hold ~out:eth_hi ~wait:3 "PL");
    st "PL" [Cmp] (fun c -> hold ~out:eth_lo ~wait:3 (if c.(0) then "PH" else "T1"));
    st "T1" [] (fun _ -> hold ~out:eth_hi ~wait:1 "T2");
    st "T2" [] (fun _ -> load ~out:eth_lo ~wait:1 "T3");
    st "T3" [] (fun _ -> shift ~out:eth_hi ~wait:1 "F0");
  ] @ bit_states @ [
    st "F7" [TxFull; Obit] (fun c ->
        if c.(0) then load ~out:(first c.(1)) ~wait:1 "S7" else hold ~out:(first c.(1)) ~wait:1 "S7E");
    st "S7" [Obit] (fun c -> shift ~out:(second c.(0)) ~wait:1 "F0");
    st "S7E" [Obit] (fun c -> hold ~out:(second c.(0)) ~wait:1 "ETD");
    st "ETD" [] (fun _ -> hold ~out:eth_hi ~wait:(eth_etd - 1) "IDLE");
  ] in
  { pname = "eth_tx_dsl"; start = "IDLE"; states; msb_first = false; terminals = [] }

(* ---- frame-start (SFD) detector (one core, P = 1): IN0 = the receive line as a logic level, out[0] = pulse ----
   Every row is one cycle, so the core samples the line every 25 ns: 4 samples per bit. It measures runs of equal
   samples. In the preamble every run is one bit time (nominally 4 samples); the SFD ends ...L(100 ns) H(50) L(50)
   H(50), so the first short LOW run marks the frame start. With edges anywhere against the sample clock a 100 ns
   run reads 3..5 samples and a 50 ns run 1..3, so a run of 3 is ambiguous on its own. The pair is not: two shorts
   span 100 ns (3..5 samples in total), two longs 200 ns (7..9). The rule, applied when a LOW run ends:
       frame start  <=>  low <= 2,  or  low = 3 and the HIGH run before it was <= 2.
   It only applies when "locked": 8 valid long runs in a row since the last violation, counted with the bit
   counter (LOAD = 8, one SHIFT per long run, CNT_ZERO = locked). The state number holds the run length; the HIGH
   run's class is kept by entering one of three LOW chains (L: after a long, LA: after a 3, LS: after a short).
   After the pulse the core skips the rest of the frame (FH/FL) until the line has been low for 8 samples. *)
let eth_sfd_delay = 2                      (* DET row: cycles between the decision and the pulse row *)
let eth_sfd_dsl () =
  let h n = Printf.sprintf "H%d" n and l n = Printf.sprintf "L%d" n in
  let ls n = Printf.sprintf "LS%d" n and la n = Printf.sprintf "LA%d" n and fl n = Printf.sprintf "FL%d" n in
  let hi_states = List.map (fun n ->
      st (h n) [In0; CntZero] (fun c ->
          if c.(0) then (if n < 5 then hold (h (n + 1)) else load "HO")      (* still high; 6 highs: not preamble *)
          else if n <= 2 then (if c.(1) then hold (ls 1) else load (l 1))     (* short high: SFD candidate if locked *)
          else if n = 3 then shift (if c.(1) then la 1 else l 1)              (* 3: long, or short if a short low follows *)
          else shift (l 1))) [1; 2; 3; 4; 5] in
  let lo_states = List.map (fun n ->
      st (l n) [In0] (fun c ->
          if not c.(0) then (if n < 5 then hold (l (n + 1)) else load "LI")   (* 6 lows: idle *)
          else if n >= 3 then shift (h 1) else load (h 1))) [1; 2; 3; 4; 5] in  (* a short low after a long high: violation *)
  let ls_states = List.map (fun n ->
      st (ls n) [In0] (fun c ->
          if c.(0) then hold "DET" else if n < 3 then hold (ls (n + 1)) else load (l 4))) [1; 2; 3] in
  let la_states = List.map (fun n ->
      st (la n) [In0] (fun c ->
          if c.(0) then hold "DET" else if n < 2 then hold (la (n + 1)) else hold (l 3))) [1; 2] in
  let fl_states = List.map (fun n ->
      st (fl n) [In0] (fun c ->
          if c.(0) then hold "FH" else if n < 7 then hold (fl (n + 1)) else load "LI")) [1; 2; 3; 4; 5; 6; 7] in
  let states = [
    (* idle, and the start state: LOAD on every row keeps CNT at 8 (not locked); the counter is 0 after RUN *)
    st "LI" [In0] (fun c -> if c.(0) then load (h 1) else load "LI");
    st "HO" [In0] (fun c -> if c.(0) then hold "HO" else hold (l 1));
  ] @ hi_states @ lo_states @ ls_states @ la_states @ [
    st "DET" [] (fun _ -> hold ~wait:(eth_sfd_delay - 1) "PUL");
    st "PUL" [] (fun _ -> hold ~out:1 ~wait:3 "FH");
    st "FH" [In0] (fun c -> if c.(0) then hold "FH" else hold (fl 1));
  ] @ fl_states in
  { pname = "eth_sfd_dsl"; start = "LI"; states; msb_first = false; terminals = [] }
