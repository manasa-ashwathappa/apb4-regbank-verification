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
