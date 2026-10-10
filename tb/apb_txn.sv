// -----------------------------------------------------------------------------
// apb_txn.sv
//
// One APB transfer as seen by the testbench. The same class carries both the
// request (randomised by a test) and the response (filled in by the driver
// or the monitor), which keeps the number of classes small for a block this
// size.
//
// How randomisation is split, and why
// -----------------------------------
// The *shape* of the traffic (read/write mix, legal vs. illegal address,
// strobe pattern, idle gap) is chosen in pre_randomize() with $urandom, and
// the constraint solver is only asked to find concrete values that satisfy
// that shape (e.g. "an address that is NOT in the register map and IS
// misaligned").
//
// The more idiomatic version puts everything in `dist` constraints. That was
// the first implementation, but the open-source flow (Verilator 5.036, SMT
// back end) ignores `dist` and returns strongly low-biased solutions, which
// silently turned a 5% error rate into ~75%. Measuring the distribution
// caught it; doing the weighting procedurally makes the traffic mix the same
// on every simulator. The cost is that the weights are no longer visible to
// a commercial solver as constraints.
// -----------------------------------------------------------------------------

// Byte addresses of the register map, kept independent of the RTL so a typo
// in the design does not silently propagate into the checker.
localparam bit [11:0] REG_CTRL     = 12'h000;
localparam bit [11:0] REG_STATUS   = 12'h004;
localparam bit [11:0] REG_INT_STAT = 12'h008;
localparam bit [11:0] REG_SCRATCH  = 12'h00C;
localparam bit [11:0] REG_DATA0    = 12'h010;
localparam bit [11:0] REG_DATA1    = 12'h014;
localparam bit [11:0] REG_DATA2    = 12'h018;
localparam bit [11:0] REG_DATA3    = 12'h01C;
localparam bit [11:0] REG_ID       = 12'h020;

typedef enum { ADDR_LEGAL, ADDR_UNMAPPED, ADDR_MISALIGNED } addr_kind_e;

class apb_txn;

    // ---- request fields ----
    rand bit [11:0]   addr;
    rand bit [31:0]   wdata;
    bit               write;
    bit [3:0]         strb;
    int unsigned      idle_before;   // bus idle cycles before this transfer

    // ---- traffic-shape knobs (set by the test before randomize) ----
    int unsigned      illegal_pct = 5;    // % of transfers aimed at bad addresses
    int unsigned      write_pct   = 50;
    bit               data_only   = 0;    // restrict to the DATA window

    // ---- per-transfer decisions made in pre_randomize ----
    addr_kind_e       addr_kind;
    bit [11:0]        legal_pick;

    // ---- response fields ----
    bit [31:0]        rdata;
    bit               slverr;
    int unsigned      wait_states;   // PREADY-low cycles seen in ACCESS
    bit               done;          // set by the driver when the transfer ends

    // The solver's job: produce an address consistent with addr_kind.
    constraint c_addr {
        if (addr_kind == ADDR_LEGAL) {
            addr == legal_pick;
        } else if (addr_kind == ADDR_UNMAPPED) {
            addr[1:0] == 2'b00;
            addr > REG_ID;
        } else {
            addr[1:0] != 2'b00;
            addr <= REG_ID + 12'h3;   // near the map, where aliasing bugs live
        }
    }

    function void pre_randomize();
        int unsigned r, idx;
        bit [11:0]   map[9] = '{REG_CTRL, REG_STATUS, REG_INT_STAT, REG_SCRATCH,
                                REG_DATA0, REG_DATA1, REG_DATA2, REG_DATA3, REG_ID};

        write = ($urandom_range(99) < write_pct);

        if (data_only) begin
            addr_kind  = ADDR_LEGAL;
            idx        = 4 + $urandom_range(3);
            legal_pick = map[idx];
        end else if ($urandom_range(99) < illegal_pct) begin
            addr_kind  = $urandom_range(1) ? ADDR_UNMAPPED : ADDR_MISALIGNED;
            legal_pick = '0;
        end else begin
            addr_kind  = ADDR_LEGAL;
            idx        = $urandom_range(8);
            legal_pick = map[idx];
        end

        // APB4: reads carry no strobes. For writes, favour full-word writes
        // (60%) but keep plenty of partial and single-byte ones since that is
        // where byte-lane bugs hide; an all-zero strobe is legal and rare.
        if (!write) begin
            strb = 4'b0000;
        end else begin
            r = $urandom_range(99);
            if      (r < 60) strb = 4'hF;
            else if (r < 80) strb = 4'b0001 << $urandom_range(3);
            else if (r < 97) strb = 4'($urandom_range(14, 1));
            else             strb = 4'h0;
        end

        // Mostly back-to-back or short gaps, occasionally a long idle.
        r = $urandom_range(9);
        if      (r < 6) idle_before = 0;
        else if (r < 9) idle_before = $urandom_range(3, 1);
        else            idle_before = $urandom_range(8, 4);
    endfunction

    function string sprint();
        if (write)
            return $sformatf("WR addr=0x%03h data=0x%08h strb=%b err=%0b",
                             addr, wdata, strb, slverr);
        return $sformatf("RD addr=0x%03h data=0x%08h err=%0b ws=%0d",
                         addr, rdata, slverr, wait_states);
    endfunction

endclass
