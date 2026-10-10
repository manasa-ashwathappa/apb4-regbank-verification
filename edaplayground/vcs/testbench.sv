// =============================================================================
// testbench.sv  (EDA Playground single-file build)
//
// All testbench sources concatenated in compile order:
//   apb_if.sv -> apb_protocol_checker.sv -> regbank_tb_pkg (classes) -> tb_top.sv
// The multi-file version lives in tb/ of the project repository.
//
// Run Options: +TEST=rand_test   (or reset_test, strb_test, irq_w1c_test,
//                                 err_test)
// Use edaplayground/riviera/ for Aldec Riviera-PRO, edaplayground/vcs/ otherwise.
// =============================================================================
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

// -----------------------------------------------------------------------------
// regbank_tb_pkg.sv
//
// All testbench classes in one package. Order matters: each file only refers
// to classes included above it.
// -----------------------------------------------------------------------------
`timescale 1ns/1ps

package regbank_tb_pkg;
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

// -----------------------------------------------------------------------------
// apb_driver.sv
//
// APB4 requester. Pulls transfers from a mailbox and walks each one through
// IDLE -> SETUP -> ACCESS (-> ACCESS while PREADY is low). Signals are driven
// with non-blocking assignments right after the clock edge, so the DUT and
// the monitor both see stable values at the following edge.
//
// When idle_before is zero and another transfer is already waiting, the
// driver goes straight from ACCESS to the next SETUP without returning to
// IDLE. That back-to-back path is legal APB and is a common source of bugs
// in completers that assume PSEL always drops between transfers.
// -----------------------------------------------------------------------------
class apb_driver;

    virtual apb_req_if vif;
    virtual apb_cpl_if cif;
    mailbox #(apb_txn) req_mb;
    int unsigned       num_sent;

    function new(virtual apb_req_if vif, virtual apb_cpl_if cif, mailbox #(apb_txn) req_mb);
        this.vif    = vif;
        this.cif    = cif;
        this.req_mb = req_mb;
        num_sent    = 0;
    endfunction

    task drive_idle();
        vif.psel    <= 1'b0;
        vif.penable <= 1'b0;
        vif.pwrite  <= 1'b0;
        vif.paddr   <= '0;
        vif.pwdata  <= '0;
        vif.pstrb   <= '0;
    endtask

    task run();
        apb_txn tr;
        drive_idle();
        @(posedge vif.pclk);
        while (vif.presetn !== 1'b1) @(posedge vif.pclk);

        forever begin
            // If nothing is queued, park the bus in IDLE until there is work.
            if (req_mb.num() == 0) begin
                drive_idle();
                req_mb.peek(tr);
            end
            req_mb.get(tr);

            if (tr.idle_before > 0) begin
                drive_idle();
                repeat (tr.idle_before) @(posedge vif.pclk);
            end
            do_xfer(tr);
        end
    endtask

    // Drives one transfer and returns after the completing edge. The caller
    // decides what happens on the next cycle (IDLE or another SETUP).
    task do_xfer(apb_txn tr);
        // SETUP phase
        vif.psel    <= 1'b1;
        vif.penable <= 1'b0;
        vif.pwrite  <= tr.write;
        vif.paddr   <= tr.addr;
        vif.pwdata  <= tr.write ? tr.wdata : 32'h0;
        vif.pstrb   <= tr.write ? tr.strb  : 4'h0;
        @(posedge vif.pclk);

        // ACCESS phase, held until the completer is ready
        vif.penable <= 1'b1;
        tr.wait_states = 0;
        @(posedge vif.pclk);
        while (cif.pready !== 1'b1) begin
            tr.wait_states++;
            @(posedge vif.pclk);
        end

        tr.rdata  = cif.prdata;
        tr.slverr = cif.pslverr;
        tr.done   = 1'b1;
        num_sent++;

        // Drop PENABLE now; if another transfer follows immediately the next
        // do_xfer() call re-drives PSEL high in the same delta, giving a
        // clean ACCESS -> SETUP transition.
        vif.penable <= 1'b0;
        vif.psel    <= 1'b0;
    endtask

endclass

// -----------------------------------------------------------------------------
// evt_driver.sv
//
// Drives the peripheral-side hw_evt input. In random mode it produces
// single-cycle pulses with a configurable density, which is enough for the
// counter, the sticky flag and the "set wins over clear" race to be hit by
// chance in a long random test. Directed tests can also call pulse().
// -----------------------------------------------------------------------------
class evt_driver;

    virtual apb_req_if vif;
    int unsigned   density_pct = 0;   // chance of a pulse on any given cycle
    int unsigned   num_pulses;

    function new(virtual apb_req_if vif);
        this.vif   = vif;
        num_pulses = 0;
    endfunction

    task run();
        vif.hw_evt <= 1'b0;
        forever begin
            @(posedge vif.pclk);
            if (vif.presetn !== 1'b1) begin
                vif.hw_evt <= 1'b0;
            end else if (density_pct == 0) begin
                // Random mode off: leave the pin alone so pulse() owns it.
            end else if ($urandom_range(99) < density_pct) begin
                vif.hw_evt <= 1'b1;
                num_pulses++;
            end else begin
                vif.hw_evt <= 1'b0;
            end
        end
    endtask

    // Directed helper: hold hw_evt high for n cycles. Random mode should be
    // off while this runs, otherwise the two processes fight over the pin.
    task pulse(int unsigned n = 1);
        repeat (n) begin
            @(posedge vif.pclk);
            vif.hw_evt <= 1'b1;
            num_pulses++;
        end
        @(posedge vif.pclk);
        vif.hw_evt <= 1'b0;
    endtask

endclass

// -----------------------------------------------------------------------------
// apb_monitor.sv
//
// Passive observer. Every clock edge it records what the DUT saw and did on
// that edge and hands it to the scoreboard as one cycle_obs object.
//
// Why one object per cycle instead of one per transfer: the register bank
// has state that changes without any bus activity (the event counter and
// the sticky flag), and the interesting corner cases are exactly the cycles
// where bus activity and hw_evt coincide. Sending both in one record lets
// the scoreboard replay the cycle in the same order the RTL evaluates it,
// rather than guessing which of two independent streams came first. The
// cost is a lot of mailbox traffic for idle cycles, which is acceptable for
// a block-level testbench of this size.
// -----------------------------------------------------------------------------
class cycle_obs;
    bit          in_reset;
    bit          hw_evt;
    bit          irq;
    apb_txn      xfer;      // null when no transfer completed on this edge
    longint      cycle;
endclass

class apb_monitor;

    virtual apb_req_if   vif;
    virtual apb_cpl_if   cif;
    mailbox #(cycle_obs) obs_mb;
    longint              cycle_cnt;

    // Wait-state bookkeeping so the coverage model can see stalled reads.
    int unsigned         cur_ws;

    function new(virtual apb_req_if vif, virtual apb_cpl_if cif,
                 mailbox #(cycle_obs) obs_mb);
        this.vif    = vif;
        this.cif    = cif;
        this.obs_mb = obs_mb;
        cycle_cnt   = 0;
        cur_ws      = 0;
    endfunction

    task run();
        cycle_obs ob;
        forever begin
            @(posedge vif.pclk);
            cycle_cnt++;

            ob          = new();
            ob.cycle    = cycle_cnt;
            ob.in_reset = (vif.presetn !== 1'b1);
            ob.hw_evt   = (vif.hw_evt === 1'b1);
            ob.irq      = (cif.irq_o === 1'b1);

            if (!ob.in_reset && vif.psel && vif.penable) begin
                if (cif.pready === 1'b1) begin
                    ob.xfer             = new();
                    ob.xfer.addr        = vif.paddr;
                    ob.xfer.write       = vif.pwrite;
                    ob.xfer.wdata       = vif.pwdata;
                    ob.xfer.strb        = vif.pstrb;
                    ob.xfer.rdata       = cif.prdata;
                    ob.xfer.slverr      = cif.pslverr;
                    ob.xfer.wait_states = cur_ws;
                    cur_ws = 0;
                end else begin
                    cur_ws++;
                end
            end
            obs_mb.put(ob);
        end
    endtask

endclass

// -----------------------------------------------------------------------------
// regbank_model.sv
//
// Untimed reference model of the register bank. It is written from the
// register specification in the header of apb_regbank.sv, not from the RTL,
// and intentionally uses a different structure (a table of register
// descriptors instead of a decode tree) so that a shared misunderstanding is
// less likely to be coded the same way twice.
//
// The model only knows about architectural state. Timing (wait states,
// which edge an update lands on) is handled by the scoreboard, which calls
// these functions in the order the hardware evaluates a clock edge.
// -----------------------------------------------------------------------------
typedef enum { ACC_RW, ACC_RO, ACC_W1C } access_e;

typedef struct {
    string     name;
    bit [11:0] addr;
    access_e   access;
    bit [31:0] mask;       // bits that physically exist
    bit [31:0] reset_val;
} reg_desc_t;

class regbank_model;

    reg_desc_t regs[$];
    bit [31:0] value[string];   // current architectural value per register

    localparam bit [31:0] ID_VAL = 32'h5A0B_0101;

    function new();
        add_reg("CTRL",     REG_CTRL,     ACC_RW,  32'h0000_00F3, 32'h0);
        add_reg("STATUS",   REG_STATUS,   ACC_RO,  32'h0000_FFFF, 32'h0);
        add_reg("INT_STAT", REG_INT_STAT, ACC_W1C, 32'h0000_0001, 32'h0);
        add_reg("SCRATCH",  REG_SCRATCH,  ACC_RW,  32'hFFFF_FFFF, 32'h0);
        add_reg("DATA0",    REG_DATA0,    ACC_RW,  32'hFFFF_FFFF, 32'h0);
        add_reg("DATA1",    REG_DATA1,    ACC_RW,  32'hFFFF_FFFF, 32'h0);
        add_reg("DATA2",    REG_DATA2,    ACC_RW,  32'hFFFF_FFFF, 32'h0);
        add_reg("DATA3",    REG_DATA3,    ACC_RW,  32'hFFFF_FFFF, 32'h0);
        add_reg("ID",       REG_ID,       ACC_RO,  32'hFFFF_FFFF, ID_VAL);
        reset();
    endfunction

    function void add_reg(string name, bit [11:0] addr, access_e acc,
                          bit [31:0] mask, bit [31:0] rst);
        reg_desc_t d;
        d.name      = name;
        d.addr      = addr;
        d.access    = acc;
        d.mask      = mask;
        d.reset_val = rst;
        regs.push_back(d);
    endfunction

    function void reset();
        foreach (regs[i]) value[regs[i].name] = regs[i].reset_val;
    endfunction

    // Linear search over the descriptor table. With nine registers this is
    // perfectly fine; a larger map would want an associative array keyed by
    // address instead.
    function int find(bit [11:0] addr);
        foreach (regs[i]) if (regs[i].addr == addr) return i;
        return -1;
    endfunction

    function string name_of(bit [11:0] addr);
        int idx = find(addr);
        return (idx < 0) ? "UNMAPPED" : regs[idx].name;
    endfunction

    // ---- prediction API used by the scoreboard ----

    function bit expect_err(bit [11:0] addr);
        return find(addr) < 0;
    endfunction

    function bit [31:0] expect_read(bit [11:0] addr);
        int idx = find(addr);
        if (idx < 0) return 32'h0;
        return value[regs[idx].name] & regs[idx].mask;
    endfunction

    function bit expect_irq();
        return value["INT_STAT"][0] && value["CTRL"][1];
    endfunction

    function bit enabled();
        return value["CTRL"][0];
    endfunction

    function void do_write(bit [11:0] addr, bit [31:0] wdata, bit [3:0] strb);
        int        idx = find(addr);
        bit [31:0] be;
        if (idx < 0) return;   // error response, no state change

        be = 32'h0;
        for (int b = 0; b < 4; b++) if (strb[b]) be[b*8 +: 8] = 8'hFF;

        case (regs[idx].access)
            ACC_RW:  value[regs[idx].name] =
                         ((value[regs[idx].name] & ~be) | (wdata & be)) & regs[idx].mask;
            ACC_RO:  ;  // writes to read-only registers are ignored by spec
            ACC_W1C: value[regs[idx].name] = value[regs[idx].name] & ~(wdata & be);
        endcase
    endfunction

    // Hardware-side event. Must be called after do_write() for the same
    // cycle so that an event wins over a simultaneous clear, but with the
    // enable value sampled *before* that write (see scoreboard).
    function void do_event();
        value["STATUS"]   = (value["STATUS"] + 1) & 32'h0000_FFFF;
        value["INT_STAT"] = 32'h1;
    endfunction

endclass

// -----------------------------------------------------------------------------
// coverage_model.sv
//
// Functional coverage for the register bank, in two forms:
//
//   * A SystemVerilog covergroup, used on commercial simulators (Questa,
//     VCS, Xcelium) where the tool's coverage database and merge flow are
//     available.
//   * A hand-rolled bin table that works on any simulator, including the
//     open-source flow, which does not implement covergroups. It is cruder (no
//     automatic crosses, string-keyed bins) but it means the coverage goal
//     can be checked in the open-source flow too.
//
// Both are sampled from the same function with the same inputs, so the bins
// below double as the written coverage plan.
// -----------------------------------------------------------------------------
class coverage_model;

    int unsigned hits[string];
    string       goal_bins[$];

    longint      last_xfer_cycle;

    // Values captured for the covergroup sample.
    bit [3:0]    cg_reg_idx;
    bit          cg_write;
    bit [3:0]    cg_strb;
    bit          cg_err;
    bit          cg_evt;

`ifndef VERILATOR
    covergroup cg_regbank;
        cp_reg : coverpoint cg_reg_idx {
            bins regs[] = {[0:8]};
            bins unmapped = {15};
        }
        cp_dir : coverpoint cg_write;
        cp_err : coverpoint cg_err;
        cp_strb : coverpoint cg_strb iff (cg_write) {
            bins full   = {4'hF};
            bins single = {4'h1, 4'h2, 4'h4, 4'h8};
            bins none   = {4'h0};
            bins partial = default;
        }
        cp_evt : coverpoint cg_evt;
        x_reg_dir : cross cp_reg, cp_dir;
        x_reg_evt : cross cp_reg, cp_evt;
    endgroup
`endif

    function new();
        string regs[9] = '{"CTRL","STATUS","INT_STAT","SCRATCH",
                           "DATA0","DATA1","DATA2","DATA3","ID"};
        last_xfer_cycle = -10;

        // Every register read and written at least once.
        foreach (regs[i]) begin
            goal_bins.push_back({"rd_", regs[i]});
            goal_bins.push_back({"wr_", regs[i]});
        end
        // Error responses in both directions.
        goal_bins.push_back("err_rd");
        goal_bins.push_back("err_wr");
        goal_bins.push_back("err_misaligned");
        // Byte-strobe shapes on writable registers.
        goal_bins.push_back("strb_full");
        goal_bins.push_back("strb_single_byte");
        goal_bins.push_back("strb_partial");
        goal_bins.push_back("strb_none");
        // Timing and interaction corners.
        goal_bins.push_back("rd_with_wait_state");
        goal_bins.push_back("back_to_back");
        goal_bins.push_back("evt_during_w1c_clear");
        goal_bins.push_back("evt_during_ctrl_write");
        goal_bins.push_back("irq_asserted");
        goal_bins.push_back("evt_while_disabled");

        foreach (goal_bins[i]) hits[goal_bins[i]] = 0;

`ifndef VERILATOR
        cg_regbank = new();
`endif
    endfunction

    function void hit(string bin_name);
        if (hits.exists(bin_name)) hits[bin_name]++;
        else                       hits[bin_name] = 1;
    endfunction

    function void sample(cycle_obs ob, bit evt_counts, bit irq_pre);
        string     rname;
        apb_txn    t;

        if (irq_pre)                        hit("irq_asserted");
        if (ob.hw_evt && !evt_counts)       hit("evt_while_disabled");

        if (ob.xfer == null) return;
        t = ob.xfer;

        case (t.addr)
            REG_CTRL:     begin rname = "CTRL";     cg_reg_idx = 0; end
            REG_STATUS:   begin rname = "STATUS";   cg_reg_idx = 1; end
            REG_INT_STAT: begin rname = "INT_STAT"; cg_reg_idx = 2; end
            REG_SCRATCH:  begin rname = "SCRATCH";  cg_reg_idx = 3; end
            REG_DATA0:    begin rname = "DATA0";    cg_reg_idx = 4; end
            REG_DATA1:    begin rname = "DATA1";    cg_reg_idx = 5; end
            REG_DATA2:    begin rname = "DATA2";    cg_reg_idx = 6; end
            REG_DATA3:    begin rname = "DATA3";    cg_reg_idx = 7; end
            REG_ID:       begin rname = "ID";       cg_reg_idx = 8; end
            default:      begin rname = "";         cg_reg_idx = 15; end
        endcase

        if (rname == "") begin
            hit(t.write ? "err_wr" : "err_rd");
            if (t.addr[1:0] != 2'b00) hit("err_misaligned");
        end else begin
            hit({t.write ? "wr_" : "rd_", rname});
        end

        if (t.write && rname != "") begin
            if (t.strb == 4'hF)                          hit("strb_full");
            else if (t.strb == 4'h0)                     hit("strb_none");
            else if ($countones(t.strb) == 1)            hit("strb_single_byte");
            else                                         hit("strb_partial");
        end

        if (!t.write && t.wait_states > 0)               hit("rd_with_wait_state");
        if (t.write && t.addr == REG_INT_STAT && evt_counts &&
            t.strb[0] && t.wdata[0])                     hit("evt_during_w1c_clear");
        if (t.write && t.addr == REG_CTRL && ob.hw_evt)  hit("evt_during_ctrl_write");

        // SETUP immediately after the previous completion means the bus never
        // went IDLE: completion cycles are exactly two apart with no stall.
        if (ob.cycle - last_xfer_cycle == 2 && t.wait_states == 0)
            hit("back_to_back");
        last_xfer_cycle = ob.cycle;

        cg_write = t.write;
        cg_strb  = t.strb;
        cg_err   = t.slverr;
        cg_evt   = evt_counts;
`ifndef VERILATOR
        cg_regbank.sample();
`endif
    endfunction

    function real percent();
        int covered = 0;
        foreach (goal_bins[i]) if (hits[goal_bins[i]] > 0) covered++;
        return 100.0 * covered / goal_bins.size();
    endfunction

    function void report();
        $display("[COV] ------------------------------------------------");
        foreach (goal_bins[i])
            $display("[COV] %-24s %6d %s", goal_bins[i], hits[goal_bins[i]],
                     hits[goal_bins[i]] == 0 ? "  <-- HOLE" : "");
        $display("[COV] functional coverage (bin table): %0.1f%%", percent());
`ifndef VERILATOR
        $display("[COV] covergroup cg_regbank          : %0.1f%%", cg_regbank.get_coverage());
`endif
        $display("[COV] ------------------------------------------------");
    endfunction

endclass

// -----------------------------------------------------------------------------
// scoreboard.sv
//
// Replays each observed clock edge against the reference model and flags
// any difference. The order of operations inside check_cycle() mirrors how
// the RTL evaluates a single edge:
//
//   1. Outputs sampled at the edge reflect state from *before* the edge,
//      so IRQ and read data are compared against the model first.
//   2. Whether hw_evt counts depends on CTRL.enable before the edge, so it
//      is decided before a possible CTRL write is applied.
//   3. The bus write is applied.
//   4. The event is applied last, which gives "set wins over W1C clear".
//
// Getting this order wrong produces false failures on exactly the corner
// cases the testbench most wants to exercise, which is why it is spelled
// out here rather than left implicit.
// -----------------------------------------------------------------------------
class scoreboard;

    mailbox #(cycle_obs) obs_mb;
    regbank_model        model;
    coverage_model       cov;

    int unsigned n_checks;
    int unsigned n_errors;
    int unsigned n_xfers;
    int unsigned max_errors_printed = 10;

    bit          verbose = 0;

    function new(mailbox #(cycle_obs) obs_mb, coverage_model cov);
        this.obs_mb = obs_mb;
        this.cov    = cov;
        model       = new();
        n_checks    = 0;
        n_errors    = 0;
        n_xfers     = 0;
    endfunction

    function void report_mismatch(longint cyc, string what);
        n_errors++;
        if (n_errors <= max_errors_printed)
            $error("[SB] cycle %0d: %s", cyc, what);
        else if (n_errors == max_errors_printed + 1)
            $display("[SB] further mismatches suppressed");
    endfunction

    task run();
        cycle_obs ob;
        forever begin
            obs_mb.get(ob);
            check_cycle(ob);
        end
    endtask

    function void check_cycle(cycle_obs ob);
        bit        evt_counts;
        bit [31:0] exp_rd;
        bit        exp_err;

        if (ob.in_reset) begin
            model.reset();
            return;
        end

        // (1) outputs that reflect pre-edge state
        n_checks++;
        if (ob.irq !== model.expect_irq())
            report_mismatch(ob.cycle, $sformatf("irq_o=%0b expected %0b",
                                                ob.irq, model.expect_irq()));

        if (ob.xfer != null) begin
            n_xfers++;
            exp_err = model.expect_err(ob.xfer.addr);

            n_checks++;
            if (ob.xfer.slverr !== exp_err)
                report_mismatch(ob.cycle, $sformatf("%s : PSLVERR=%0b expected %0b",
                                ob.xfer.sprint(), ob.xfer.slverr, exp_err));

            if (!ob.xfer.write) begin
                exp_rd = model.expect_read(ob.xfer.addr);
                n_checks++;
                if (ob.xfer.rdata !== exp_rd)
                    report_mismatch(ob.cycle, $sformatf("%s (%s) expected 0x%08h",
                                    ob.xfer.sprint(), model.name_of(ob.xfer.addr), exp_rd));
            end

            if (verbose) $display("[SB] %0d %s", ob.cycle, ob.xfer.sprint());
        end

        // (2) decide event effect using the pre-write enable
        evt_counts = ob.hw_evt && model.enabled();

        // Coverage is sampled here because it needs both the transfer and the
        // knowledge of whether an event collided with it.
        cov.sample(ob, evt_counts, model.expect_irq());

        // (3) apply the bus write
        if (ob.xfer != null && ob.xfer.write)
            model.do_write(ob.xfer.addr, ob.xfer.wdata, ob.xfer.strb);

        // (4) apply the event last
        if (evt_counts) model.do_event();
    endfunction

    function void report();
        $display("[SB] transfers checked : %0d", n_xfers);
        $display("[SB] individual checks : %0d", n_checks);
        $display("[SB] mismatches        : %0d", n_errors);
    endfunction

endclass

// -----------------------------------------------------------------------------
// env.sv
//
// Builds and connects the testbench components. Kept deliberately thin: it
// owns the mailboxes and starts the background processes, and offers a few
// blocking helpers (wr / rd) so directed tests read like a register
// programming sequence rather than like mailbox plumbing.
// -----------------------------------------------------------------------------
class env;

    virtual apb_req_if   vif;
    virtual apb_cpl_if   cif;

    mailbox #(apb_txn)   req_mb;
    mailbox #(cycle_obs) obs_mb;

    apb_driver           drv;
    apb_monitor          mon;
    evt_driver           evt;
    coverage_model       cov;
    scoreboard           sb;

    function new(virtual apb_req_if vif, virtual apb_cpl_if cif);
        this.vif = vif;
        this.cif = cif;
        req_mb   = new();
        obs_mb   = new();
        drv      = new(vif, cif, req_mb);
        mon      = new(vif, cif, obs_mb);
        evt      = new(vif);
        cov      = new();
        sb       = new(obs_mb, cov);
    endfunction

    task start();
        fork
            drv.run();
            mon.run();
            evt.run();
            sb.run();
        join_none
    endtask

    // Queue a transfer and wait for the driver to finish it. Directed tests
    // use these; random tests push straight into the mailbox instead so the
    // driver can run transfers back-to-back.
    task wr(bit [11:0] addr, bit [31:0] data, bit [3:0] strb = 4'hF);
        apb_txn t = new();
        t.addr = addr; t.write = 1; t.wdata = data; t.strb = strb;
        t.idle_before = 0;
        req_mb.put(t);
        while (!t.done) @(posedge vif.pclk);
    endtask

    task rd(bit [11:0] addr, output bit [31:0] data);
        apb_txn t = new();
        t.addr = addr; t.write = 0; t.wdata = 0; t.strb = 0;
        t.idle_before = 0;
        req_mb.put(t);
        while (!t.done) @(posedge vif.pclk);
        data = t.rdata;
    endtask

    // Let the pipeline drain: the scoreboard lags the bus by the mailbox, so
    // give the monitor a few idle edges and then wait for it to catch up.
    task drain(int unsigned cycles = 20);
        repeat (cycles) @(posedge vif.pclk);
        while (obs_mb.num() != 0) @(negedge vif.pclk);
    endtask

endclass

// -----------------------------------------------------------------------------
// tests.sv
//
// Test classes. Each test only decides *what* to send; checking is always
// done by the scoreboard, so a test cannot pass by forgetting to check.
// Directed tests additionally carry a few immediate assertions on values
// that are fixed by the specification, as a second, independent opinion.
//
// Test               Intent
// ---------------    --------------------------------------------------------
// reset_test         every register reads its reset value; ID is correct
// strb_test          byte-lane behaviour on all writable registers
// irq_w1c_test       sticky flag, IRQ masking, W1C clear, set-wins race
// err_test           unmapped / misaligned accesses return PSLVERR, no effect
// rand_test          long constrained-random mix with random hw_evt traffic
// -----------------------------------------------------------------------------
class base_test;

    env          e;
    int unsigned num_txn = 200;
    string       name    = "base_test";

    function new(env e);
        this.e = e;
        void'($value$plusargs("NUM_TXN=%d", num_txn));
    endfunction

    virtual task body();
    endtask

    // Shared random traffic generator. The knobs are copied into each
    // transaction before randomize() because the solver reads them as state.
    task send_random(int unsigned n, int unsigned illegal_pct,
                     int unsigned write_pct, bit data_only = 0);
        apb_txn t;
        for (int i = 0; i < n; i++) begin
            t = new();
            t.illegal_pct = illegal_pct;
            t.write_pct   = write_pct;
            t.data_only   = data_only;
            if (!t.randomize()) $fatal(1, "randomize() failed on txn %0d", i);
            e.req_mb.put(t);
        end
        // Wait for the driver to empty the queue before returning.
        while (e.req_mb.num() != 0) @(posedge e.vif.pclk);
        repeat (12) @(posedge e.vif.pclk);
    endtask

endclass

// -----------------------------------------------------------------------------
class reset_test extends base_test;
    function new(env e); super.new(e); name = "reset_test"; endfunction

    virtual task body();
        bit [31:0] rd_val;
        bit [11:0] addr_list[9] = '{REG_CTRL, REG_STATUS, REG_INT_STAT, REG_SCRATCH,
                                    REG_DATA0, REG_DATA1, REG_DATA2, REG_DATA3, REG_ID};
        foreach (addr_list[i]) e.rd(addr_list[i], rd_val);

        e.rd(REG_ID, rd_val);
        a_id_value: assert (rd_val == 32'h5A0B_0101)
            else $error("ID register reads 0x%08h", rd_val);

        // A simple write/read on SCRATCH so the test also proves the path is
        // alive, not just that everything happens to reset to zero.
        e.wr(REG_SCRATCH, 32'hCAFE_F00D);
        e.rd(REG_SCRATCH, rd_val);
        a_scratch_rw: assert (rd_val == 32'hCAFE_F00D)
            else $error("SCRATCH readback 0x%08h", rd_val);

        // Writing a read-only register must be ignored, not errored.
        e.wr(REG_ID, 32'hFFFF_FFFF);
        e.rd(REG_ID, rd_val);
        a_id_ro: assert (rd_val == 32'h5A0B_0101)
            else $error("ID changed after write: 0x%08h", rd_val);
    endtask
endclass

// -----------------------------------------------------------------------------
class strb_test extends base_test;
    function new(env e); super.new(e); name = "strb_test"; endfunction

    virtual task body();
        bit [31:0] rd_val;
        bit [11:0] targets[5] = '{REG_SCRATCH, REG_DATA0, REG_DATA1, REG_DATA2, REG_DATA3};

        // Walk each single byte lane on every writable word, starting from a
        // known background so a wrongly-written lane is visible on readback.
        foreach (targets[i]) begin
            for (int lane = 0; lane < 4; lane++) begin
                e.wr(targets[i], 32'h0000_0000);
                e.wr(targets[i], 32'hA5A5_A5A5, 4'b0001 << lane);
                e.rd(targets[i], rd_val);
            end
            // CTRL has reserved bits; writing all ones must leave them zero.
            e.wr(REG_CTRL, 32'hFFFF_FFFF);
            e.rd(REG_CTRL, rd_val);
            a_ctrl_reserved: assert ((rd_val & ~32'h0000_00F3) == 0)
                else $error("CTRL reserved bits read 0x%08h", rd_val);
            e.wr(REG_CTRL, 32'h0);
        end

        // Then a short random burst restricted to the data window.
        send_random(num_txn, 0, 60, 1);
    endtask
endclass

// -----------------------------------------------------------------------------
class irq_w1c_test extends base_test;
    function new(env e); super.new(e); name = "irq_w1c_test"; endfunction

    virtual task body();
        bit [31:0] rd_val;

        // Events while disabled must not count or set the flag.
        e.evt.pulse(3);
        e.rd(REG_STATUS, rd_val);
        e.rd(REG_INT_STAT, rd_val);

        // Enable counting, but keep the interrupt masked.
        e.wr(REG_CTRL, 32'h1);
        e.evt.pulse(5);
        e.rd(REG_STATUS, rd_val);
        a_cnt_five: assert (rd_val[15:0] == 16'd5)
            else $error("STATUS after 5 events = %0d", rd_val[15:0]);
        e.rd(REG_INT_STAT, rd_val);

        // Unmask: IRQ must follow the already-pending flag immediately.
        e.wr(REG_CTRL, 32'h3);
        repeat (2) @(posedge e.vif.pclk);
        a_irq_high: assert (e.cif.irq_o === 1'b1)
            else $error("irq_o not asserted with flag pending and irq_en=1");

        // W1C with the wrong value or no strobe must not clear.
        e.wr(REG_INT_STAT, 32'h0);
        e.wr(REG_INT_STAT, 32'h1, 4'b0000);
        e.rd(REG_INT_STAT, rd_val);

        // Proper clear.
        e.wr(REG_INT_STAT, 32'h1);
        e.rd(REG_INT_STAT, rd_val);

        // Race: keep hw_evt high across a clear so they share an edge.
        fork
            e.evt.pulse(6);
            begin
                @(posedge e.vif.pclk);
                e.wr(REG_INT_STAT, 32'h1);
            end
        join
        e.rd(REG_INT_STAT, rd_val);
        e.rd(REG_STATUS, rd_val);

        // Finally some random traffic with dense events to shake out
        // interactions the directed part did not think of.
        e.evt.density_pct = 30;
        send_random(num_txn, 2, 50);
        e.evt.density_pct = 0;
    endtask
endclass

// -----------------------------------------------------------------------------
class err_test extends base_test;
    function new(env e); super.new(e); name = "err_test"; endfunction

    virtual task body();
        bit [31:0] rd_val;

        e.wr(REG_SCRATCH, 32'h1234_5678);
        // A misaligned write that would alias SCRATCH if the decoder simply
        // dropped the low address bits.
        e.wr(REG_SCRATCH + 12'h1, 32'hDEAD_DEAD);
        e.rd(REG_SCRATCH, rd_val);
        a_no_alias: assert (rd_val == 32'h1234_5678)
            else $error("misaligned write aliased onto SCRATCH: 0x%08h", rd_val);

        e.rd(12'h024, rd_val);   // first word past the map
        e.rd(12'hFFC, rd_val);   // top of the address space

        send_random(num_txn, 60, 50);
    endtask
endclass

// -----------------------------------------------------------------------------
class rand_test extends base_test;
    function new(env e);
        super.new(e);
        name    = "rand_test";
        num_txn = 2000;
        void'($value$plusargs("NUM_TXN=%d", num_txn));   // re-apply override
    endfunction

    virtual task body();
        // Mostly legal traffic with occasional errors and a moderate event
        // rate, run in a few phases so CTRL gets toggled under traffic.
        e.evt.density_pct = 10;
        send_random(num_txn / 4, 5, 50);
        e.wr(REG_CTRL, 32'h3);
        send_random(num_txn / 4, 5, 50);
        e.evt.density_pct = 40;
        send_random(num_txn / 4, 5, 70);
        e.wr(REG_CTRL, 32'h0);
        send_random(num_txn / 4, 10, 50);
        e.evt.density_pct = 0;
    endtask
endclass

endpackage

// -----------------------------------------------------------------------------
// tb_top.sv
//
// Static top: clock, reset, interface, DUT, and test selection.
//
// Run-time controls (plusargs)
//   +TEST=<name>      reset_test | strb_test | irq_w1c_test | err_test | rand_test
//   +NUM_TXN=<n>      number of random transfers for the random phases
//   +VERBOSE          print every completed transfer from the scoreboard
//   +DUMP             write dump.vcd for waveform viewing
//
// The seed is passed with the simulator's own option (for Verilator,
// +verilator+seed+<n>) so a failing run can be reproduced exactly.
// -----------------------------------------------------------------------------
`timescale 1ns/1ps

module tb_top;

    import regbank_tb_pkg::*;

    localparam real CLK_PERIOD_NS = 10.0;   // 100 MHz, arbitrary for RTL sim

    logic pclk    = 1'b0;
    logic presetn = 1'b0;

    always #(CLK_PERIOD_NS / 2) pclk = ~pclk;

    apb_req_if #(.ADDR_W(12)) req (.pclk(pclk), .presetn(presetn));
    apb_cpl_if                cpl (.pclk(pclk), .presetn(presetn));

    apb_regbank #(.ADDR_W(12)) dut (
        .pclk    (pclk),
        .presetn (presetn),
        .psel    (req.psel),
        .penable (req.penable),
        .pwrite  (req.pwrite),
        .paddr   (req.paddr),
        .pwdata  (req.pwdata),
        .pstrb   (req.pstrb),
        .prdata  (cpl.prdata),
        .pready  (cpl.pready),
        .pslverr (cpl.pslverr),
        .hw_evt  (req.hw_evt),
        .irq_o   (cpl.irq_o)
    );

    apb_protocol_checker #(.ADDR_W(12)) u_apb_chk (
        .pclk    (pclk),
        .presetn (presetn),
        .psel    (req.psel),
        .penable (req.penable),
        .pwrite  (req.pwrite),
        .paddr   (req.paddr),
        .pwdata  (req.pwdata),
        .pstrb   (req.pstrb),
        .pready  (cpl.pready),
        .pslverr (cpl.pslverr)
    );

    env       e;
    base_test t;
    string    test_name;

    initial begin
        if (!$value$plusargs("TEST=%s", test_name)) test_name = "rand_test";

        e = new(req, cpl);
        e.sb.verbose = $test$plusargs("VERBOSE");

        // Plain if/else selection. A factory would be the scalable answer;
        // with five tests it would mostly add indirection.
        if      (test_name == "reset_test")   begin automatic reset_test x = new(e); t = x; end
        else if (test_name == "strb_test")    begin automatic strb_test x = new(e); t = x; end
        else if (test_name == "irq_w1c_test") begin automatic irq_w1c_test x = new(e); t = x; end
        else if (test_name == "err_test")     begin automatic err_test x = new(e); t = x; end
        else if (test_name == "rand_test")    begin automatic rand_test x = new(e); t = x; end
        else $fatal(1, "Unknown +TEST=%s", test_name);

        $display("[TB] running %s", t.name);
        e.start();

        // Hold reset for a few cycles so every flop sees it.
        repeat (5) @(posedge pclk);
        presetn <= 1'b1;
        repeat (2) @(posedge pclk);

        t.body();
        e.drain();

        e.cov.report();
        e.sb.report();
        if (e.sb.n_errors == 0 && e.sb.n_xfers > 0)
            $display("[TB] *** TEST PASSED : %s ***", t.name);
        else
            $display("[TB] *** TEST FAILED : %s (%0d mismatches) ***", t.name, e.sb.n_errors);
        $finish;
    end

    // Optional waveform dump. Off by default so long regressions do not
    // write large VCD files; add +DUMP to the run options to enable it
    // (EDA Playground: also tick "Open EPWave after run").
    initial begin
        if ($test$plusargs("DUMP")) begin
            $dumpfile("dump.vcd");
            $dumpvars(0, tb_top);
        end
    end

    // Watchdog: a hung handshake should end the run with a clear message
    // rather than time out silently in a regression farm.
    initial begin
        #(CLK_PERIOD_NS * 2_000_000);
        $fatal(1, "[TB] watchdog expired - simulation hung");
    end

endmodule
