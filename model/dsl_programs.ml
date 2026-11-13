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
