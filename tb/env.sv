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
