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
