`timescale 1ns / 1ps
module top(
input wclk, rclk,
input wrst, rrst,
input wen, ren,
input [7:0] din,
output wire [7:0] dout,
output empty, underrun,
output full, overrun
    );
    
    dp_ram_top dp_ram(
    .wclk(wclk), 
    .rclk(rclk), 
    .wen(wen && !full), 
    .ren(ren && !empty),
    .waddr(wptr[3:0]),
    .raddr(rptr[3:0]), 
    .wdata(din),
    .rdata(dout));
    
    
    reg [4:0] wptr, rptr;
    wire [4:0] wptr_next, rptr_next;
    reg [4:0] g_wptr, g_rptr;
    wire [4:0] g_wptr_next, g_rptr_next;
    reg empty_t, full_t;
    reg underrun_t, overrun_t;
    reg [4:0] sync_wptr1, sync_wptr2;
    reg [4:0] sync_rptr1, sync_rptr2;
    
    //Empty
    always@(posedge rclk) begin
    if(rrst) begin
    empty_t <= 1'b1;
    end else begin
    empty_t <= (g_rptr_next == sync_wptr2) ? 1'b1 : 1'b0;
    end
    end
    
    //Full
    always@(posedge wclk) begin
    if(wrst) begin
    full_t <= 1'b0;
    end else begin
    full_t <= (g_wptr_next == {~sync_rptr2[4:3], sync_rptr2[2:0]}) ? 1'b1 : 1'b0;
    end
    end
    
    //Underrun
    always@(posedge rclk) begin
    if(rrst)
    underrun_t <= 1'b0;
    else if(ren && empty_t)
    underrun_t <= 1'b1;
    else
    underrun_t <= 1'b0;
    end
    
    //Overrun
    always@(posedge wclk) begin
    if(wrst)
    overrun_t <= 1'b0;
    else if(wen && full_t)
    overrun_t <= 1'b1;
    else
    overrun_t <= 1'b0;
    end
    
    //Write
    always@(posedge wclk) begin
    if(wrst) begin
    wptr <= 0;
    g_wptr <= 0;
    end else if(wen && !full_t) begin
    wptr <= wptr_next;
    g_wptr <= g_wptr_next;
    end
    end
    
    //Read
    always@(posedge rclk) begin
    if(rrst) begin
    rptr <= 0;
    g_rptr <= 0;
    end else if(ren && !empty_t) begin
    rptr <= rptr_next;
    g_rptr <= g_rptr_next;
    end
    end
    
    //Synchronizing
    always@(posedge rclk) begin
    if(rrst) begin
    sync_wptr1 <= 0;
    sync_wptr2 <= 0;
    end else begin
    sync_wptr1 <= g_wptr;
    sync_wptr2 <= sync_wptr1;
    end
    end
    
    always@(posedge wclk) begin
    if(wrst) begin
    sync_rptr1 <= 0;
    sync_rptr2 <= 0;
    end else begin
    sync_rptr1 <= g_rptr;
    sync_rptr2 <= sync_rptr1;
    end
    end
   
    assign empty = empty_t;
    assign full = full_t;
    assign underrun = underrun_t;
    assign overrun = overrun_t;
    assign wptr_next = wptr + (wen && !full_t);
    assign g_wptr_next = (wptr_next ^ (wptr_next >> 1));
    assign rptr_next = rptr + (ren && !empty_t);
    assign g_rptr_next = (rptr_next ^ (rptr_next >> 1));
    
endmodule
