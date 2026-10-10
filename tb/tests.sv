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
