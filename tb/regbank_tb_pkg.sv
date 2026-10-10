// -----------------------------------------------------------------------------
// regbank_tb_pkg.sv
//
// All testbench classes in one package. Order matters: each file only refers
// to classes included above it.
// -----------------------------------------------------------------------------
`timescale 1ns/1ps

package regbank_tb_pkg;

    `include "apb_txn.sv"
    `include "apb_driver.sv"
    `include "evt_driver.sv"
    `include "apb_monitor.sv"
    `include "regbank_model.sv"
    `include "coverage_model.sv"
    `include "scoreboard.sv"
    `include "env.sv"
    `include "tests.sv"

endpackage
