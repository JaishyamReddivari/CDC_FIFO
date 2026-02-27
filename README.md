# CDC FIFO — Design & UVM Verification

A complete asynchronous FIFO design with a **UVM-based constrained-random verification environment** for validating safe data transfer across clock domain crossings (CDC). The project demonstrates industry-standard verification methodology applied to a Gray-code-synchronized dual-clock FIFO.

## Overview

Clock Domain Crossing is one of the most error-prone areas in digital design. This project pairs a classical async FIFO implementation (Gray code pointer synchronization over dual-port RAM) with a structured UVM testbench that exercises corner cases, randomized traffic patterns, and flag integrity — making it a practical reference for both RTL design and functional verification.

### Key Features

- **Dual-clock FIFO** — Independent write (`wclk` @ 100 MHz) and read (`rclk` @ ~71.4 MHz) domains with Gray code synchronizers
- **16×8 Dual-Port RAM** — 16 entries, 8 bits wide
- **Full UVM 1.2 environment** — Agent, driver, monitor, scoreboard, sequences, and test
- **Constrained-random stimulus** — Weighted randomization with 70/30 write/read distribution
- **Self-checking scoreboard** — Reference FIFO queue model with automatic data integrity checks
- **Status flag coverage** — `full`, `empty`, `overrun`, and `underrun` detection and validation

## Design Under Test (DUT)

### Architecture

```
 Write Domain (wclk)                Read Domain (rclk)
┌──────────────────────┐          ┌──────────────────────┐
│  Write Pointer (bin) ──► Gray ──►  2-FF Sync  ──► Full │
│         │            │          │              Logic   │
│         ▼            │          │                      │
│   Dual-Port RAM      │          │   Dual-Port RAM      │
│   (write port)       │          │   (read port)        │
│                      │          │         ▲            │
│   Empty ◄── 2-FF Sync ◄── Gray ◄── Read Pointer (bin)  │
│       Logic          │          │                      │
└──────────────────────┘          └──────────────────────┘
```

### Design Parameters

| Parameter | Value |
|---|---|
| Data Width | 8 bits |
| FIFO Depth | 16 entries |
| Address Width | 4 bits (+1 MSB for full/empty) |
| Write Clock | 10 ns period (100 MHz) |
| Read Clock | 14 ns period (~71.4 MHz) |

### CDC Strategy

Binary pointers are converted to Gray code before crossing into the opposite domain via a 2-stage flip-flop synchronizer. This guarantees only a single bit toggles per pointer increment, eliminating metastability-induced corruption during sampling.

### Status Flags

| Flag | Condition | Domain |
|---|---|---|
| `empty` | Gray read pointer == synchronized write pointer | `rclk` |
| `full` | Gray write pointer == synchronized read pointer (top 2 MSBs inverted) | `wclk` |
| `underrun` | Read attempted while FIFO is empty | `rclk` |
| `overrun` | Write attempted while FIFO is full | `wclk` |

## UVM Verification Environment

### Testbench Topology

```
tb_top (SystemVerilog module)
 ├── DUT instantiation (top)
 ├── fifo_if (virtual interface)
 └── UVM Test
      └── fifo_test
           └── fifo_env
                ├── fifo_agent (active)
                │    ├── fifo_sequencer ─── fifo_sequence
                │    ├── fifo_driver
                │    └── fifo_monitor ──── analysis port
                └── fifo_scoreboard ◄───── analysis export
```

### Component Breakdown

#### Transaction (`fifo_txn`)

The transaction class models a single FIFO operation. Fields are registered with the UVM field automation macros for built-in `print()`, `copy()`, `compare()`, and `pack()`/`unpack()` support.

| Field | Type | Description |
|---|---|---|
| `write` | `rand bit` | Write enable |
| `read` | `rand bit` | Read enable |
| `data` | `rand bit [7:0]` | Write data / observed read data |

#### Sequence (`fifo_sequence`)

Generates **500 constrained-random transactions** with weighted distribution:

```systemverilog
write dist {1:=70, 0:=30};   // 70% chance of write per txn
read  dist {1:=70, 0:=30};   // 70% chance of read per txn
```

This distribution is tuned to stress the FIFO by keeping it moderately loaded, maximizing the probability of hitting `full`, `empty`, and simultaneous read/write scenarios under asynchronous clocking.

#### Driver (`fifo_driver`)

Drives transactions onto the DUT interface with the following protocol:

1. **Write path** — Asserts `wen` and `din` on the `wclk` posedge, skips if `full` is asserted
2. **Read path** — Asserts `ren` on the `rclk` posedge, skips if `empty` is asserted
3. Both operations are guarded by DUT status flags to respect backpressure

The driver retrieves the virtual interface handle from `uvm_config_db` during the `build_phase`.

#### Monitor (`fifo_monitor`)

Passively observes the DUT interface on every rising edge of either clock. For each sampled event it captures `dout`, `wen`, and `ren` into a transaction and broadcasts it via a `uvm_analysis_port` to all subscribers (scoreboard).

#### Scoreboard (`fifo_scoreboard`)

Implements a **reference model** using an internal SystemVerilog queue that mirrors expected FIFO behavior:

```
On write → push data to reference queue
On read  → pop front of reference queue, compare against DUT output
Mismatch → uvm_error("SB", "DATA MISMATCH")
```

This provides a self-checking, pass/fail mechanism without manual waveform inspection.

#### Agent (`fifo_agent`)

Encapsulates the driver, monitor, and sequencer into a reusable agent. Connections are made in the `connect_phase`:

```
driver.seq_item_port ──► sequencer.seq_item_export
monitor.mon_ap       ──► scoreboard.sb_ap   (via env)
```

#### Environment (`fifo_env`)

Instantiates and wires the agent and scoreboard. The `connect_phase` links the monitor's analysis port to the scoreboard's analysis export, completing the data path from DUT observation to reference model checking.

#### Test (`fifo_test`)

Top-level test class that builds the environment, raises an objection, starts the sequence on the agent's sequencer, waits for drain time (`#1000`), and drops the objection to end the simulation.

### Verification Flow

```
┌─────────────┐     ┌────────────┐     ┌──────────┐     ┌──────────────┐
│  Sequence    │────►│  Driver    │────►│   DUT    │────►│   Monitor    │
│ (randomized) │     │ (stimuli)  │     │ (FIFO)   │     │ (passive)    │
└─────────────┘     └────────────┘     └──────────┘     └──────┬───────┘
                                                               │
                                                     analysis_port.write()
                                                               │
                                                        ┌──────▼───────┐
                                                        │  Scoreboard  │
                                                        │ (ref model)  │
                                                        └──────────────┘
```

### What the Testbench Validates

| Scenario | How It's Covered |
|---|---|
| Basic write → read data integrity | Scoreboard queue comparison on every read |
| FIFO full condition | Constrained-random write-heavy traffic fills FIFO; driver respects `full` flag |
| FIFO empty condition | Read-heavy bursts drain FIFO; driver respects `empty` flag |
| Overrun detection | Write attempted when full → `overrun` flag asserted |
| Underrun detection | Read attempted when empty → `underrun` flag asserted |
| CDC metastability safety | Mismatched clock frequencies (100 MHz vs ~71.4 MHz) exercise async boundaries |
| Simultaneous read/write | 70/30 distribution ensures high probability of concurrent operations |

## File Structure

```
cdc-fifo/
├── dp_ram_top.v      # Dual-port RAM (16×8), independent R/W clocks
├── top.v             # Async FIFO top — pointers, Gray code, synchronizers, flags
├── tb_top.sv         # UVM testbench (interface, txn, seq, drv, mon, sb, agent, env, test)
└── README.md
```

## Getting Started

### Prerequisites

A Verilog/SystemVerilog simulator with **UVM 1.2** support:

- Synopsys VCS
- Cadence Xcelium
- Mentor Questa / ModelSim
- Icarus Verilog (with UVM plugin)

### Running the Simulation

**VCS:**

```bash
vcs -full64 -sverilog -ntb_opts uvm-1.2 \
    dp_ram_top.v top.v tb_top.sv \
    -o simv -timescale=1ns/1ps

./simv +UVM_TESTNAME=fifo_test +UVM_VERBOSITY=UVM_MEDIUM
```

**Questa:**

```bash
vlog -sv +incdir+$UVM_HOME/src dp_ram_top.v top.v tb_top.sv
vsim -c tb_top +UVM_TESTNAME=fifo_test -do "run -all; quit"
```

**Xcelium:**

```bash
xrun -sv -uvm -uvmhome CDNS-1.2 \
    dp_ram_top.v top.v tb_top.sv \
    -timescale 1ns/1ps +UVM_TESTNAME=fifo_test
```

### Expected Output

A passing simulation will complete with no `UVM_ERROR` or `UVM_FATAL` messages:

```
UVM_INFO  ... [RNTST] Running test fifo_test...
...
UVM_INFO  ... [UVMTOP] UVM testbench topology:
...
--- UVM Report Summary ---
** Report counts by severity
UVM_INFO    :    XX
UVM_WARNING :    0
UVM_ERROR   :    0
UVM_FATAL   :    0
** Report counts by id
...
```

Any `DATA MISMATCH` errors from the scoreboard indicate a functional failure in the DUT.

## Possible Extensions

- **Functional coverage** — Add `covergroup` for pointer states, flag transitions, and FIFO occupancy bins
- **Assertions (SVA)** — Protocol checks on Gray code properties, flag timing, and no data loss guarantees
- **Multiple sequences** — Add targeted sequences for burst writes, burst reads, back-to-back fill/drain, and reset-mid-operation
- **Parameterization** — Make data width, depth, and synchronizer stages configurable with verification across multiple configs
- **Regression suite** — Multiple test classes with different seeds and stimulus profiles for broader coverage closure
