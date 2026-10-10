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
