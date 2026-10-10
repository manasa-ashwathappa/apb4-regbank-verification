// -----------------------------------------------------------------------------
// apb_protocol_checker.sv
//
// Concurrent assertions for the APB4 handshake (AMBA APB v2.0, ch. 3-4).
// These rules hold for every test and every register map: if one fires,
// either the stimulus or the DUT has broken the bus contract, independent of
// whether the data is right. Written as a plain module with input ports so
// it can be instantiated next to the DUT or attached with `bind`.
// -----------------------------------------------------------------------------
`timescale 1ns/1ps

module apb_protocol_checker #(parameter int ADDR_W = 12) (
    input logic              pclk,
    input logic              presetn,
    input logic              psel,
    input logic              penable,
    input logic              pwrite,
    input logic [ADDR_W-1:0] paddr,
    input logic [31:0]       pwdata,
    input logic [3:0]        pstrb,
    input logic              pready,
    input logic              pslverr
);

`ifndef NO_SVA   // see note in apb_regbank.sv
    // SETUP must be followed by ACCESS: one cycle of PSEL without PENABLE
    // always moves to PENABLE high on the next edge.
    a_setup_to_access: assert property (@(posedge pclk) disable iff (!presetn)
        (psel && !penable) |=> (psel && penable))
        else $error("APB: SETUP phase not followed by ACCESS phase");

    // PENABLE is only legal while the completer is selected.
    a_enable_needs_sel: assert property (@(posedge pclk) disable iff (!presetn)
        penable |-> psel)
        else $error("APB: PENABLE high without PSEL");

    // While the completer stalls a transfer, the requester must hold the
    // address, direction, write data and strobes stable.
    a_stable_in_wait: assert property (@(posedge pclk) disable iff (!presetn)
        (psel && penable && !pready) |=>
            ($stable(paddr) && $stable(pwrite) && $stable(pwdata) && $stable(pstrb)))
        else $error("APB: request changed while PREADY was low");

    // APB4 requires PSTRB to be all-zero for read transfers.
    a_rd_strb_zero: assert property (@(posedge pclk) disable iff (!presetn)
        (psel && !pwrite) |-> (pstrb == 4'b0000))
        else $error("APB: non-zero PSTRB on a read");

    // PSLVERR is only meaningful in the last cycle of a transfer.
    a_err_only_at_end: assert property (@(posedge pclk) disable iff (!presetn)
        pslverr |-> (psel && penable && pready))
        else $error("APB: PSLVERR outside the completing cycle");

`endif

endmodule
