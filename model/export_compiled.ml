(* Compile every DSL program and write the result as JSON, so the tables the OCaml
   compiler produces can be loaded unchanged onto the chip RTL by the Python harness.
   One line per program: name, table (row-indexed words), state names in numbering
   order, reset selects, start state, msb_first, terminals. *)
let json_str s = "\"" ^ String.escaped s ^ "\""
let json_list f l = "[" ^ String.concat ", " (List.map f l) ^ "]"

let export (prog : Compiler.program) =
  let c = Compiler.compile prog in
  Printf.sprintf "%s: {\"table\": %s, \"names\": %s, \"reset_sel\": [%d, %d], \"start\": %s, \"start_num\": %d, \"msb_first\": %b, \"terminals\": %s}"
    (json_str prog.Compiler.pname)
    (json_list string_of_int (Array.to_list c.Compiler.table))
    (json_list json_str c.Compiler.names)
    (fst c.Compiler.reset_sel) (snd c.Compiler.reset_sel)
    (json_str prog.Compiler.start) c.Compiler.start_num prog.Compiler.msb_first
    (json_list json_str prog.Compiler.terminals)

let () =
  let progs = Dsl_programs.[ uart_tx_dsl (); uart_rx_dsl (); spi_tx_dsl (); i2c_wr_dsl (); nt_trader_dsl (); hd_uart_dsl (); ps2_rx_dsl () ] in
  print_string ("{\n" ^ String.concat ",\n" (List.map export progs) ^ "\n}\n")
