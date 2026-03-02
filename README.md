# CDC FIFO — Design & UVM Verification

A complete asynchronous FIFO design with a **UVM-based constrained-random verification environment** for validating safe data transfer across clock domain crossings (CDC). The project demonstrates industry-standard verification methodology applied to a Gray-code-synchronized dual-clock FIFO.

## Overview

Clock Domain Crossing is one of the most error-prone areas in digital design. This project pairs a classical async FIFO implementation (Gray code pointer synchronization over dual-port RAM) with a structured UVM testbench that exercises corner cases, randomized traffic patterns, and flag integrity — making it a practical reference for both RTL design and functional verification.

### Key Features

* **Dual-clock FIFO** — Independent write (`wclk` @ 100 MHz) and read (`rclk` @ ~71.4 MHz) domains with Gray code synchronizers
* **16×8 Dual-Port RAM** — 16 entries, 8 bits wide
* **Full UVM 1.2 environment** — Agent, driver, monitor, scoreboard, sequences, and test
* **Constrained-random stimulus** — Weighted randomization with 70/30 write/read distribution
* **Self-checking scoreboard** — Reference FIFO queue model with automatic data integrity checks and vacuous-pass detection
* **Status flag coverage** — `full`, `empty`, `overrun`, and `underrun` detection and validation

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
| --- | --- |
| Data Width | 8 bits |
| FIFO Depth | 16 entries |
| Address Width | 4 bits (+1 MSB for full/empty) |
| Write Clock | 10 ns period (100 MHz) |
| Read Clock | 14 ns period (~71.4 MHz) |

### CDC Strategy

Binary pointers are converted to Gray code before crossing into the opposite domain via a 2-stage flip-flop synchronizer. This guarantees only a single bit toggles per pointer increment, eliminating metastability-induced corruption during sampling.

### Status Flags

| Flag | Condition | Domain |
| --- | --- | --- |
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
                │         ├── monitor_write (wclk domain)
                │         └── monitor_read  (rclk domain)
                └── fifo_scoreboard ◄───── analysis export
```

### Component Breakdown

#### Transaction (`fifo_txn`)

The transaction class models a single FIFO operation. Fields are registered with the UVM field automation macros for built-in `print()`, `copy()`, `compare()`, and `pack()`/`unpack()` support.

| Field | Type | Description |
| --- | --- | --- |
| `write` | `rand bit` | Write enable |
| `read` | `rand bit` | Read enable |
| `data` | `rand bit [7:0]` | Write data / observed read data |

#### Sequence (`fifo_sequence`)

Generates **500 constrained-random transactions** with weighted distribution:

```
write dist {1:=70, 0:=30};   // 70% chance of write per txn
read  dist {1:=70, 0:=30};   // 70% chance of read per txn
```

Transactions follow the UVM sequencer protocol: `start_item()` → `randomize()` → `finish_item()`. This ensures the sequencer has granted the item before randomization occurs, which is UVM best practice.

This distribution is tuned to stress the FIFO by keeping it moderately loaded, maximizing the probability of hitting `full`, `empty`, and simultaneous read/write scenarios under asynchronous clocking.

#### Driver (`fifo_driver`)

Drives transactions onto the DUT interface with the following protocol:

1. **Write path** — Waits for `posedge wclk`, then checks `full`. If not full, asserts `wen` and `din` via NBA, waits one more `wclk` cycle, then deasserts `wen`.
2. **Read path** — Waits for `posedge rclk`, then checks `empty`. If not empty, asserts `ren` via NBA, waits one more `rclk` cycle, then deasserts `ren`.
3. **Idle path** — If neither write nor read is requested, the driver advances by one `wclk` cycle to prevent zero-delay simulation loops.

Both operations are guarded by DUT status flags to respect backpressure. The driver retrieves the virtual interface handle from `uvm_config_db` during the `build_phase`.

#### Monitor (`fifo_monitor`)

Uses two **independent forked processes**, one per clock domain, to avoid CDC sampling races:

* **`monitor_write()`** — Triggers on `posedge wclk`, waits `#1` to let the driver's NBA assignments resolve, then checks `wen && !full`. On a valid write, it captures `din` into a transaction with `write=1, read=0` and broadcasts it via the analysis port.
* **`monitor_read()`** — Triggers on `posedge rclk`, waits `#1` for NBA resolution, then checks `ren && !empty`. On a valid read, it waits one additional `rclk` cycle for the registered RAM output (`rdata`) to become valid, then captures `dout` into a transaction with `write=0, read=1` and broadcasts it.

The `#1` delay after each clock edge is critical: since the driver uses non-blocking assignments (`<=`), these values resolve in the NBA region *after* the active region where the monitor's `@(posedge)` trigger fires. Without the delay, the monitor would sample stale values and miss all transactions.

#### Scoreboard (`fifo_scoreboard`)

Implements a **reference model** using an internal SystemVerilog queue (`bit [7:0] model_q[$]`) that mirrors expected FIFO behavior:

```
On write txn → push din to reference queue
On read txn  → pop front of reference queue, compare against captured dout
Mismatch     → uvm_error("SB", "DATA MISMATCH")
```

The scoreboard also tracks `num_writes`, `num_reads`, and `num_matches` counters. In the UVM `check_phase`, it prints a summary and raises `UVM_ERROR` if either counter is zero, catching **vacuous passes** where the test completes without any actual data integrity checks.

```
===== SCOREBOARD SUMMARY =====
  Writes captured : 245
  Reads captured  : 245
  Matches         : 245
  Queue remaining : 0
==============================
```

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
┌─────────────┐     ┌────────────┐     ┌──────────┐
│  Sequence   │────►│  Driver    │────►│   DUT    │
│ (randomized)│     │ (stimuli)  │     │ (FIFO)   │
└─────────────┘     └────────────┘     └──────────┘
                                            │
                         ┌──────────────────┤
                         ▼                  ▼
                  ┌─────────────┐    ┌─────────────┐
                  │  Monitor    │    │  Monitor    │
                  │  (wclk)     │    │  (rclk)     │
                  │ captures din│    │captures dout│
                  └──────┬──────┘    └──────┬──────┘
                         │                  │
                         ▼                  ▼
                  ┌────────────────────────────────┐
                  │         Scoreboard             │
                  │   (ref model + vacuous-pass    │
                  │    detection in check_phase)   │
                  └────────────────────────────────┘
```

### What the Testbench Validates

| Scenario | How It's Covered |
| --- | --- |
| Basic write → read data integrity | Scoreboard queue comparison on every read |
| FIFO full condition | Constrained-random write-heavy traffic fills FIFO; driver respects `full` flag |
| FIFO empty condition | Read-heavy bursts drain FIFO; driver respects `empty` flag |
| Overrun detection | Write attempted when full → `overrun` flag asserted |
| Underrun detection | Read attempted when empty → `underrun` flag asserted |
| CDC metastability safety | Mismatched clock frequencies (100 MHz vs ~71.4 MHz) exercise async boundaries |
| Simultaneous read/write | 70/30 distribution ensures high probability of concurrent operations |
| Vacuous pass prevention | `check_phase` asserts that writes and reads were actually observed |

## File Structure

```
cdc-fifo/
├── ram_top.sv       # Dual-port RAM (16×8), independent R/W clocks
├── top.sv           # Async FIFO top — pointers, Gray code, synchronizers, flags
├── tb.sv            # UVM testbench (interface, txn, seq, drv, mon, sb, agent, env, test)
└── README.md
```

## Getting Started

### Prerequisites

A Verilog/SystemVerilog simulator with **UVM 1.2** support:

* Synopsys VCS
* Cadence Xcelium
* Mentor Questa / ModelSim
* Icarus Verilog (with UVM plugin)

### Running the Simulation

**VCS:**

```
vcs -full64 -sverilog -ntb_opts uvm-1.2 \
    ram_top.sv top.sv tb.sv \
    -o simv -timescale=1ns/1ps

./simv +UVM_TESTNAME=fifo_test +UVM_VERBOSITY=UVM_MEDIUM
```

**Questa:**

```
vlog -sv +incdir+$UVM_HOME/src ram_top.sv top.sv tb.sv
vsim -c tb_top +UVM_TESTNAME=fifo_test -do "run -all; quit"
```

**Xcelium:**

```
xrun -sv -uvm -uvmhome CDNS-1.2 \
    ram_top.sv top.sv tb.sv \
    -timescale 1ns/1ps +UVM_TESTNAME=fifo_test
```

### Expected Output

A passing simulation will complete with no `UVM_ERROR` or `UVM_FATAL` messages and a non-zero scoreboard summary:

```
UVM_INFO  ... [RNTST] Running test fifo_test...
...
UVM_INFO  ... [SB]
===== SCOREBOARD SUMMARY =====
  Writes captured : 245
  Reads captured  : 245
  Matches         : 245
  Queue remaining : 0
==============================
...
--- UVM Report Summary ---
** Report counts by severity
UVM_INFO    :    XX
UVM_WARNING :    0
UVM_ERROR   :    0
UVM_FATAL   :    0
```

Any `DATA MISMATCH` errors from the scoreboard indicate a functional failure in the DUT. A `VACUOUS PASS` error indicates the monitor failed to capture transactions — check interface connectivity and clock generation.

## Possible Extensions

* **Functional coverage** — Add `covergroup` for pointer states, flag transitions, and FIFO occupancy bins
* **Assertions (SVA)** — Protocol checks on Gray code properties, flag timing, and no data loss guarantees
* **Multiple sequences** — Add targeted sequences for burst writes, burst reads, back-to-back fill/drain, and reset-mid-operation
* **Parameterization** — Make data width, depth, and synchronizer stages configurable with verification across multiple configs
* **Regression suite** — Multiple test classes with different seeds and stimulus profiles for broader coverage closure
