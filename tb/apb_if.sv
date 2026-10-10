// -----------------------------------------------------------------------------
// apb_if.sv
//
// Signal bundles between the testbench and the DUT, split by who drives them:
//
//   apb_req_if : driven by the testbench (APB requester + hw_evt sideband)
//   apb_cpl_if : driven by the DUT       (APB completer outputs + irq_o)
//
// A single interface would be the textbook choice. It is split here because
// the open-source simulator used for this project (Verilator 5.036)
// re-evaluates its input-combinational region whenever a
// member of a virtually-accessed interface is written, so a DUT output that
// is combinational from TB-driven inputs *in the same interface* never
// converges. Keeping the two directions in separate interface types avoids
// that, and it also makes the ownership of each signal explicit.
//
// The protocol assertions are not in here; they live in apb_protocol_checker
// so the same checker can be bound onto any APB port in a larger design.
// -----------------------------------------------------------------------------
`timescale 1ns/1ps

interface apb_req_if #(parameter int ADDR_W = 12) (input logic pclk, input logic presetn);
    logic              psel;
    logic              penable;
    logic              pwrite;
    logic [ADDR_W-1:0] paddr;
    logic [31:0]       pwdata;
    logic [3:0]        pstrb;
    logic              hw_evt;
endinterface

interface apb_cpl_if (input logic pclk, input logic presetn);
    logic [31:0]       prdata;
    logic              pready;
    logic              pslverr;
    logic              irq_o;
endinterface
