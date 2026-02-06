`include "uvm_macros.svh"
import uvm_pkg::*;

interface fifo_if(input bit wclk, rclk);

  logic wrst, rrst;
  logic wen, ren;
  logic [7:0] din;
  logic [7:0] dout;
  logic empty, full, underrun, overrun;

endinterface

class fifo_txn extends uvm_sequence_item;

  rand bit write;
  rand bit read;
  rand bit [7:0] data;

  `uvm_object_utils_begin(fifo_txn)
    `uvm_field_int(write, UVM_DEFAULT)
    `uvm_field_int(read,  UVM_DEFAULT)
    `uvm_field_int(data,  UVM_DEFAULT)
  `uvm_object_utils_end

  function new(string name="fifo_txn");
    super.new(name);
  endfunction

endclass

class fifo_sequence extends uvm_sequence #(fifo_txn);
  `uvm_object_utils(fifo_sequence)

  function new(string name="fifo_sequence");
    super.new(name);
  endfunction

  task body();
    fifo_txn txn;

    repeat (500) begin
      txn = fifo_txn::type_id::create("txn");
      assert(txn.randomize() with {
        write dist {1:=70, 0:=30};
        read  dist {1:=70, 0:=30};
      });
      start_item(txn);
      finish_item(txn);
    end
  endtask

endclass

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

      // WRITE
      if (txn.write && !vif.full) begin
        vif.wen <= 1;
        vif.din <= txn.data;
        @(posedge vif.wclk);
        vif.wen <= 0;
      end

      // READ
      if (txn.read && !vif.empty) begin
        vif.ren <= 1;
        @(posedge vif.rclk);
        vif.ren <= 0;
      end

      seq_item_port.item_done();
    end
  endtask

endclass

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
    fifo_txn txn;

    forever begin
      @(posedge vif.wclk or posedge vif.rclk);
      txn = fifo_txn::type_id::create("txn");
      txn.data = vif.dout;
      txn.write = vif.wen;
      txn.read  = vif.ren;
      mon_ap.write(txn);
    end
  endtask

endclass

class fifo_scoreboard extends uvm_scoreboard;
  `uvm_component_utils(fifo_scoreboard)

  uvm_analysis_imp #(fifo_txn, fifo_scoreboard) sb_ap;
  queue [7:0] model_q;

  function new(string name, uvm_component parent);
    super.new(name, parent);
    sb_ap = new("sb_ap", this);
  endfunction

  function void write(fifo_txn txn);
    if (txn.write)
      model_q.push_back(txn.data);

    if (txn.read && model_q.size() > 0) begin
      if (txn.data !== model_q.pop_front())
        `uvm_error("SB", "DATA MISMATCH")
    end
  endfunction

endclass

class fifo_agent extends uvm_agent;
  `uvm_component_utils(fifo_agent)

  fifo_driver drv;
  fifo_monitor mon;
  uvm_sequencer #(fifo_txn) seqr;

  function new(string name, uvm_component parent);
    super.new(name, parent);
  endfunction

  function void build_phase(uvm_phase phase);
    drv  = fifo_driver ::type_id::create("drv", this);
    mon  = fifo_monitor::type_id::create("mon", this);
    seqr = uvm_sequencer#(fifo_txn)::type_id::create("seqr", this);
  endfunction

  function void connect_phase(uvm_phase phase);
    drv.seq_item_port.connect(seqr.seq_item_export);
  endfunction

endclass

class fifo_env extends uvm_env;
  `uvm_component_utils(fifo_env)

  fifo_agent agent;
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

module tb_top;

  bit wclk = 0, rclk = 0;

  always #5  wclk = ~wclk;
  always #7  rclk = ~rclk;

  fifo_if vif(wclk, rclk);

  top dut (
    .wclk(wclk),
    .rclk(rclk),
    .wrst(vif.wrst),
    .rrst(vif.rrst),
    .wen(vif.wen),
    .ren(vif.ren),
    .din(vif.din),
    .dout(vif.dout),
    .empty(vif.empty),
    .underrun(vif.underrun),
    .full(vif.full),
    .overrun(vif.overrun)
  );

  initial begin
    vif.wrst = 1;
    vif.rrst = 1;
    #20;
    vif.wrst = 0;
    vif.rrst = 0;
  end

  initial begin
    uvm_config_db#(virtual fifo_if)::set(null, "*", "vif", vif);
    run_test("fifo_test");
  end

endmodule
