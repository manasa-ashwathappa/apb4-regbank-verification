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
