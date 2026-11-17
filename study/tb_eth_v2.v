// STUDY ONLY: runs study/eth_v2_tx.v once and writes the line, one cycle per row, to line.txt
`timescale 1ns/1ps
module tb_eth_v2;
  reg clk = 0, rst_n = 0, wr_en = 0, go = 0; reg [10:0] wr_addr = 0, len = 0; reg [7:0] wr_data = 0;
  wire busy, mem_en, mem_we, td_p, td_n; wire [10:0] mem_addr; wire [7:0] mem_din; reg [7:0] mem_dout;
  reg [7:0] mem [0:2047];
  eth_v2_tx dut (.*);
  always #12.5 clk = ~clk;
  always @(posedge clk) if (mem_en) begin if (mem_we) mem[mem_addr] <= mem_din; else mem_dout <= mem[mem_addr]; end
  integer i, f; reg [7:0] frame [0:63];
  initial begin
    $readmemh("frame.hex", frame);
    f = $fopen("line.txt", "w");
    repeat (4) @(negedge clk); rst_n = 1;
    for (i = 0; i < 60; i = i + 1) begin
      @(negedge clk); wr_en = 1; wr_addr = i; wr_data = frame[i];
    end
    @(negedge clk); wr_en = 0; len = 60; go = 1;
    @(negedge clk); go = 0;
    repeat (4 * 8 * (8 + 60 + 4) + 60) begin @(negedge clk); $fwrite(f, "%b%b\n", td_p, td_n); end
    $fclose(f); $finish;
  end
endmodule
