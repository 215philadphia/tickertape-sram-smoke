(* Independent references, written from the protocol specs, not transliterated
   from the Python model. Used to check the OCaml core's own output, and (for
   UART/SPI) to check it byte-for-byte against a trace exported by the Python
   model of the same table. *)

(* ---- UART ---------------------------------------------------------- *)

(* Ideal decoder: exact fractional bit period, samples at bit centres.
   Returns (bytes, worst edge-timing error in cycles). *)
let uart_decode wave bit_period =
  let n = Array.length wave in
  let bytes = ref [] and worst = ref 0.0 in
  let i = ref 1 in
  while !i < n do
    if wave.(!i - 1) = 1 && wave.(!i) = 0 then begin
      let centre kf = float_of_int !i +. (kf +. 0.5) *. bit_period in
      let last = int_of_float (centre 9.0) in
      if last < n then begin
        if wave.(int_of_float (centre 0.0)) <> 0 then failwith "bad start bit";
        let byte = ref 0 in
        for k = 0 to 7 do
          byte := !byte lor (wave.(int_of_float (centre (float_of_int k +. 1.0))) lsl k)
        done;
        if wave.(last) <> 1 then failwith "bad stop bit";
        (* every transition in the frame should land within a fraction of a
           bit period of its ideal position *)
        let stop = int_of_float (centre 9.5) in
        for m = !i + 1 to (min stop (n - 1)) do
          if wave.(m) <> wave.(m - 1) then begin
            let k = Float.round (float_of_int (m - !i) /. bit_period) in
            let err = Float.abs (float_of_int (m - !i) -. k *. bit_period) in
            if err > !worst then worst := err
          end
        done;
        bytes := !byte :: !bytes;
        i := last
      end
    end;
    incr i
  done;
  (List.rev !bytes, !worst)

(* Ideal transmitter: emits `bytes` at `bit_period * (1+err)`, random phase and
   inter-byte gaps, returns the wire waveform. *)
let uart_encode ~rng bytes bit_period err gap_max =
  let bt = bit_period *. (1.0 +. err) in
  let t = ref (5.0 +. Random.State.float rng 45.0) in
  let edges = ref [] in
  List.iter (fun byte ->
      let bits = 0 :: (List.init 8 (fun k -> (byte lsr k) land 1)) @ [1] in
      List.iteri (fun k v -> edges := (!t +. float_of_int k *. bt, v) :: !edges) bits;
      t := !t +. 10.0 *. bt +. Random.State.float rng gap_max *. bt)
    bytes;
  let edges = Array.of_list (List.rev !edges) in
  let total = int_of_float (!t +. 2.0 *. bt) in
  let wave = Array.make total 1 in
  let j = ref 0 and lvl = ref 1 in
  for n = 0 to total - 1 do
    while !j < Array.length edges && fst edges.(!j) <= float_of_int n do
      lvl := snd edges.(!j); incr j
    done;
    wave.(n) <- !lvl
  done;
  wave

(* ---- SPI ------------------------------------------------------------ *)

(* Decode on SCK rising edges while CS is low, MSB first. *)
let spi_decode ~mosi ~sck ~cs =
  let n = Array.length sck in
  let bytes = ref [] and bits = ref [] and prev_sck = ref 0 in
  for k = 0 to n - 1 do
    if cs.(k) = 0 && sck.(k) = 1 && !prev_sck = 0 then begin
      bits := mosi.(k) :: !bits;
      if List.length !bits = 8 then begin
        let b = List.fold_left (fun acc v -> acc * 2 + v) 0 (List.rev !bits) in
        bytes := b :: !bytes; bits := []
      end
    end;
    if cs.(k) = 1 && !bits <> [] then failwith "CS rose mid-byte";
    prev_sck := sck.(k)
  done;
  List.rev !bytes

(* ---- vector file loader ---------------------------------------------- *)

type vector = {
  s : int; p : int; msb : bool; reset_sel : int * int;
  table : int array; ints : int array;   (* meaning depends on the file: byte
                                             list (TX) or stimulus wave (RX) *)
  ground : int array;                    (* Python's own output trace, for the
                                             bit-exact cross-check *)
  done_state : int;                      (* only set for the table-only files *)
}

let load path =
  let ic = open_in path in
  let kv = Hashtbl.create 8 in
  let blocks = Hashtbl.create 4 in
  (try
     while true do
       let line = String.trim (input_line ic) in
       if line = "" then ()
       else match String.index_opt line '=' with
         | None -> ()
         | Some i ->
           let key = String.sub line 0 i in
           let v = String.sub line (i + 1) (String.length line - i - 1) in
           (match String.length key with
            | _ when String.length key > 2 && String.sub key (String.length key - 2) 2 = "_N" ->
              let base = String.sub key 0 (String.length key - 2) in
              let n = int_of_string v in
              let arr = Array.init n (fun _ -> int_of_string (String.trim (input_line ic))) in
              Hashtbl.replace blocks base arr
            | _ -> Hashtbl.replace kv key v)
     done
   with End_of_file -> ());
  close_in ic;
  let geti k = int_of_string (Hashtbl.find kv k) in
  let geti_opt k d = try int_of_string (Hashtbl.find kv k) with Not_found -> d in
  let getb k = try Hashtbl.find blocks k with Not_found -> [||] in
  let sel = geti "RSEL" in
  { s = geti "S"; p = geti "P"; msb = geti "MSB" = 1;
    reset_sel = (sel land 3, (sel lsr 2) land 3);
    table = getb "TABLE"; ints = getb "INTS"; ground = getb "GROUND";
    done_state = geti_opt "DONE" 255 }
