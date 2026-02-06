`timescale 1ns / 1ps
module dp_ram_top(
input wire wclk, rclk,
input wire wen, ren,
input wire [3:0] waddr, raddr,
input wire [7:0] wdata,
output reg [7:0] rdata
    );
    
    reg [7:0] mem[0:15];
    
    always@(posedge wclk) begin
    if(wen)
    mem[waddr] <= wdata;
    end
    
    always@(posedge rclk) begin
    if(ren)
    rdata <= mem[raddr];
    end
    
endmodule
