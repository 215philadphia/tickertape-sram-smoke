// Black-box stub for synthesis and linting. Port list matches
// IHP-Open-PDK ihp-sg13g2/libs.ref/sg13g2_sram/verilog/RM_IHPSG13_1P_256x32_c2_bm_bist.v
// (symlinked as ihp-sg13cmos5l/libs.ref/sg13cmos5l_sram). Simulation uses the
// PDK behavioral model in test/models instead. SPDX-License-Identifier: Apache-2.0
(* blackbox *)
module RM_IHPSG13_1P_256x32_c2_bm_bist (
    input         A_CLK,
    input         A_MEN,
    input         A_WEN,
    input         A_REN,
    input  [7:0]  A_ADDR,
    input  [31:0] A_DIN,
    input         A_DLY,
    output [31:0] A_DOUT,
    input  [31:0] A_BM,
    input         A_BIST_CLK,
    input         A_BIST_EN,
    input         A_BIST_MEN,
    input         A_BIST_WEN,
    input         A_BIST_REN,
    input  [7:0]  A_BIST_ADDR,
    input  [31:0] A_BIST_DIN,
    input  [31:0] A_BIST_BM
);
endmodule
