`include "uvm_macros.svh"
import uvm_pkg::*;

// Interface
interface fifo_if(input bit wclk, rclk);
  logic wrst, rrst;
  logic wen, ren;
  logic [7:0] din;
  logic [7:0] dout;
  logic empty, full, underrun, overrun;
endinterface

// Transaction
class fifo_txn extends uvm_sequence_item;

  rand bit       write;
  rand bit       read;
  rand bit [7:0] data;

  `uvm_object_utils_begin(fifo_txn)
    `uvm_field_int(write, UVM_DEFAULT)
    `uvm_field_int(read,  UVM_DEFAULT)
    `uvm_field_int(data,  UVM_DEFAULT)
  `uvm_object_utils_end

  function new(string name = "fifo_txn");
    super.new(name);
  endfunction

endclass

// Sequence
class fifo_sequence extends uvm_sequence #(fifo_txn);
  `uvm_object_utils(fifo_sequence)

  function new(string name = "fifo_sequence");
    super.new(name);
  endfunction

  task body();
    fifo_txn txn;

    repeat (500) begin
      txn = fifo_txn::type_id::create("txn");
      start_item(txn);
      assert(txn.randomize() with {
        write dist {1 := 70, 0 := 30};
        read  dist {1 := 70, 0 := 30};
      });
      finish_item(txn);
    end
  endtask

endclass

// Driver
class fifo_driver extends uvm_driver #(fifo_txn);
  `uvm_component_utils(fifo_driver)

  virtual fifo_if vif;

  function new(string name, uvm_component parent);
    super.new(name, parent);
  endfunction

  function void build_phase(uvm_phase phase);
    super.build_phase(phase);
    if (!uvm_config_db#(virtual fifo_if)::get(this, "", "vif", vif))
      `uvm_fatal("DRV", "Interface not found")
  endfunction

  task run_phase(uvm_phase phase);
    fifo_txn txn;

    forever begin
      seq_item_port.get_next_item(txn);

      // WRITE operation (wclk domain)
      if (txn.write) begin
        @(posedge vif.wclk);
        if (!vif.full) begin
          vif.wen <= 1;
          vif.din <= txn.data;
          @(posedge vif.wclk);
          vif.wen <= 0;
        end
      end

      // READ operation (rclk domain)
      if (txn.read) begin
        @(posedge vif.rclk);
        if (!vif.empty) begin
          vif.ren <= 1;
          @(posedge vif.rclk);
          vif.ren <= 0;
        end
      end

      // Guarantee time advance when both ops skipped
      if (!txn.write && !txn.read) begin
        @(posedge vif.wclk);
      end

      seq_item_port.item_done();
    end
  endtask

endclass

// Monitor
class fifo_monitor extends uvm_monitor;
  `uvm_component_utils(fifo_monitor)

  virtual fifo_if vif;
  uvm_analysis_port #(fifo_txn) mon_ap;

  function new(string name, uvm_component parent);
    super.new(name, parent);
    mon_ap = new("mon_ap", this);
  endfunction

  function void build_phase(uvm_phase phase);
    if (!uvm_config_db#(virtual fifo_if)::get(this, "", "vif", vif))
      `uvm_fatal("MON", "Interface not found")
  endfunction

  task run_phase(uvm_phase phase);
    fork
      monitor_write();
      monitor_read();
    join
  endtask

  task monitor_write();
    forever begin
      @(posedge vif.wclk);
      #1;
      if (vif.wen && !vif.full) begin
        fifo_txn txn = fifo_txn::type_id::create("txn");
        txn.write = 1;
        txn.read  = 0;
        txn.data  = vif.din;
        mon_ap.write(txn);
      end
    end
  endtask

  task monitor_read();
    forever begin
      @(posedge vif.rclk);
      #1;
      if (vif.ren && !vif.empty) begin
        fifo_txn txn = fifo_txn::type_id::create("txn");
        txn.write = 0;
        txn.read  = 1;
        @(posedge vif.rclk);
        #1;
        txn.data  = vif.dout;
        mon_ap.write(txn);
      end
    end
  endtask

endclass

// Scoreboard
class fifo_scoreboard extends uvm_scoreboard;
  `uvm_component_utils(fifo_scoreboard)

  uvm_analysis_imp #(fifo_txn, fifo_scoreboard) sb_ap;

  bit [7:0] model_q[$];

  int num_writes;
  int num_reads;
  int num_matches;

  function new(string name, uvm_component parent);
    super.new(name, parent);
    sb_ap       = new("sb_ap", this);
    num_writes  = 0;
    num_reads   = 0;
    num_matches = 0;
  endfunction

  function void write(fifo_txn txn);
    if (txn.write && !txn.read) begin
      model_q.push_back(txn.data);
      num_writes++;
      `uvm_info("SCO", $sformatf("WRITE: data=0x%0h  queue_depth=%0d", txn.data, model_q.size()), UVM_MEDIUM)
    end

    if (txn.read && !txn.write) begin
      num_reads++;
      if (model_q.size() > 0) begin
        bit [7:0] expected = model_q.pop_front();
        if (txn.data !== expected)
          `uvm_error("SCO", $sformatf("DATA MISMATCH: expected=0x%0h  got=0x%0h", expected, txn.data))
        else begin
          num_matches++;
          `uvm_info("SCO", $sformatf("MATCH: data=0x%0h", txn.data), UVM_MEDIUM)
        end
      end else begin
        `uvm_error("SCO", "Read from empty reference queue")
      end
    end
  endfunction

  function void check_phase(uvm_phase phase);
    `uvm_info("SCO", $sformatf(
      "\n===== SCOREBOARD SUMMARY =====\n  Writes captured : %0d\n  Reads captured  : %0d\n  Matches         : %0d\n  Queue remaining : %0d\n==============================",
      num_writes, num_reads, num_matches, model_q.size()), UVM_LOW)

    if (num_writes == 0)
      `uvm_error("SCO", "VACUOUS PASS: scoreboard saw zero writes — monitor may not be connected")
    if (num_reads == 0)
      `uvm_error("SCO", "VACUOUS PASS: scoreboard saw zero reads — monitor may not be connected")
  endfunction

endclass

// Agent
class fifo_agent extends uvm_agent;
  `uvm_component_utils(fifo_agent)

  fifo_driver              drv;
  fifo_monitor             mon;
  uvm_sequencer #(fifo_txn) seqr;

  function new(string name, uvm_component parent);
    super.new(name, parent);
  endfunction

  function void build_phase(uvm_phase phase);
    drv  = fifo_driver::type_id::create("drv", this);
    mon  = fifo_monitor::type_id::create("mon", this);
    seqr = uvm_sequencer#(fifo_txn)::type_id::create("seqr", this);
  endfunction

  function void connect_phase(uvm_phase phase);
    drv.seq_item_port.connect(seqr.seq_item_export);
  endfunction

endclass

// Environment
class fifo_env extends uvm_env;
  `uvm_component_utils(fifo_env)

  fifo_agent      agent;
  fifo_scoreboard sb;

  function new(string name, uvm_component parent);
    super.new(name, parent);
  endfunction

  function void build_phase(uvm_phase phase);
    agent = fifo_agent::type_id::create("agent", this);
    sb    = fifo_scoreboard::type_id::create("sb", this);
  endfunction

  function void connect_phase(uvm_phase phase);
    agent.mon.mon_ap.connect(sb.sb_ap);
  endfunction

endclass

// Test
class fifo_test extends uvm_test;
  `uvm_component_utils(fifo_test)

  fifo_env env;

  function new(string name, uvm_component parent);
    super.new(name, parent);
  endfunction

  function void build_phase(uvm_phase phase);
    env = fifo_env::type_id::create("env", this);
  endfunction

  task run_phase(uvm_phase phase);
    fifo_sequence seq;
    phase.raise_objection(this);

    seq = fifo_sequence::type_id::create("seq");
    seq.start(env.agent.seqr);

    #1000;
    phase.drop_objection(this);
  endtask

endclass

// Top-level testbench module
module tb_top;

  bit wclk = 0, rclk = 0;

  always #5  wclk = ~wclk;   // 100 MHz
  always #7  rclk = ~rclk;   // ~71.4 MHz

  fifo_if vif(wclk, rclk);

  top dut (
    .wclk   (wclk),
    .rclk   (rclk),
    .wrst   (vif.wrst),
    .rrst   (vif.rrst),
    .wen    (vif.wen),
    .ren    (vif.ren),
    .din    (vif.din),
    .dout   (vif.dout),
    .empty  (vif.empty),
    .underrun(vif.underrun),
    .full   (vif.full),
    .overrun(vif.overrun)
  );

  initial begin
    vif.wrst = 1;
    vif.rrst = 1;
    vif.wen  = 0;
    vif.ren  = 0;
    vif.din  = 0;
    #20;
    vif.wrst = 0;
    vif.rrst = 0;
  end

  initial begin
    uvm_config_db#(virtual fifo_if)::set(null, "*", "vif", vif);
    run_test("fifo_test");
  end

endmodule
