# CDC_FIFO

> Download the ZIP, extract it into a Vivado project workspace and open the Vivado project file.

---

## About

This repository provides a reusable Clock-Domain_Crossing FIFO (First-In-First-Out) module capable of transferring multi-bit data safely across two asynchronous clock domains:

**Write domain** — Accepts data on `clk_wr`  
**Read domain** — Provides data on `clk_rd`

Key design features include:

- CDC-safe pointer handling using Gray coding  
- Full and empty flag generation  
- Simulation models for functional verification  
- Synthesizable RTL for use in FPGA designs  
- UVM testbench for validating behavior across clocks

The FIFO design follows proven CDC design techniques to reduce metastability issues and avoid underflow/overflow conditions.

---

## Features

- Supports asynchronous clock domains  
- Full and Empty status flags  
- Gray-coded read/write pointers for safe CDC  
- Compatible with Xilinx Vivado toolchain  
- Includes simulation & synthesis assets
