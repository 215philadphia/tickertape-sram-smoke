// Tiny Tapeout top level: two cores, each with its own IHP 256x32 single-port SRAM macro.
`default_nettype none
module tt_um_tickertape_pfst (
  input  wire [7:0] ui_in,
  output wire [7:0] uo_out,
  input  wire [7:0] uio_in,
  output wire [7:0] uio_out,
  output wire [7:0] uio_oe,
  input  wire       ena,
  input  wire       clk,
  input  wire       rst_n
);
  wire [1:0]  men, wen, ren;
  wire [15:0] maddr;
  wire [63:0] mdin, mdout;

  pfst_chip chip (.clk(clk), .rst_n(rst_n), .ui_in(ui_in), .uio_in(uio_in),
                  .uo_out(uo_out), .uio_out(uio_out), .uio_oe(uio_oe),
                  .m_men(men), .m_wen(wen), .m_ren(ren), .m_addr(maddr), .m_din(mdin), .m_dout(mdout));

  RM_IHPSG13_1P_256x32_c2_bm_bist sram0 (
    .A_CLK(clk), .A_MEN(men[0]), .A_WEN(wen[0]), .A_REN(ren[0]), .A_ADDR(maddr[7:0]),
    .A_DIN(mdin[31:0]), .A_DLY(1'b1), .A_DOUT(mdout[31:0]), .A_BM(32'hFFFF_FFFF),
    .A_BIST_CLK(1'b0), .A_BIST_EN(1'b0), .A_BIST_MEN(1'b0), .A_BIST_WEN(1'b0),
    .A_BIST_REN(1'b0), .A_BIST_ADDR(8'd0), .A_BIST_DIN(32'd0), .A_BIST_BM(32'd0));
  RM_IHPSG13_1P_256x32_c2_bm_bist sram1 (
    .A_CLK(clk), .A_MEN(men[1]), .A_WEN(wen[1]), .A_REN(ren[1]), .A_ADDR(maddr[15:8]),
    .A_DIN(mdin[63:32]), .A_DLY(1'b1), .A_DOUT(mdout[63:32]), .A_BM(32'hFFFF_FFFF),
    .A_BIST_CLK(1'b0), .A_BIST_EN(1'b0), .A_BIST_MEN(1'b0), .A_BIST_WEN(1'b0),
    .A_BIST_REN(1'b0), .A_BIST_ADDR(8'd0), .A_BIST_DIN(32'd0), .A_BIST_BM(32'd0));
  wire _unused = &{ena, 1'b0};
endmodule
`default_nettype wire
