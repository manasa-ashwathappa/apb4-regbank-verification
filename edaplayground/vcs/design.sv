// design.sv (EDA Playground build, full SVA) - for VCS / Xcelium / Questa

// -----------------------------------------------------------------------------
// apb_regbank.sv
//
// A small APB4 (AMBA APB protocol v2.0) peripheral register bank. It is meant
// to look like the control/status block that sits in front of almost every
// SoC peripheral: a handful of configuration registers, a read-only status
// counter, a sticky interrupt register with write-1-to-clear semantics, and a
// small data window that is slower to read than the rest of the map.
//
// Register map (byte addresses, all registers 32-bit, word aligned)
//   0x000 CTRL      RW   [0] enable, [1] irq_en, [7:4] cfg (stored only)
//   0x004 STATUS    RO   [15:0] number of hw_evt pulses seen while enabled
//   0x008 INT_STAT  W1C  [0] evt_seen (sticky, set by hw_evt while enabled)
//   0x00C SCRATCH   RW   [31:0] general purpose
//   0x010 DATA0     RW   [31:0] }
//   0x014 DATA1     RW   [31:0] }  "slow" window: reads insert one wait
//   0x018 DATA2     RW   [31:0] }  state and return registered data
//   0x01C DATA3     RW   [31:0] }
//   0x020 ID        RO   fixed identification value
//
// Bus behaviour
//   * PSTRB selects which bytes of a writable register are updated.
//   * Writes to RO registers are silently ignored (no error). This is a
//     deliberate design choice and is captured in the verification plan.
//   * Any access to an unmapped or misaligned address completes with
//     PSLVERR=1, does not change state and returns PRDATA=0.
//   * If hw_evt and a W1C clear of INT_STAT land on the same clock edge, the
//     hardware set wins, so an event can never be silently lost.
//
// Bug injection (for demonstrating that the testbench actually catches bugs)
//   +define+BUG_STRB : DATA registers ignore PSTRB and always write all bytes
//   +define+BUG_W1C  : any write to INT_STAT clears it, even writing 0
// -----------------------------------------------------------------------------
`timescale 1ns/1ps

module apb_regbank #(
    parameter int          ADDR_W = 12,
    parameter logic [31:0] ID_VAL = 32'h5A0B_0101
) (
    input  logic              pclk,
    input  logic              presetn,

    // APB4 completer interface
    input  logic              psel,
    input  logic              penable,
    input  logic              pwrite,
    input  logic [ADDR_W-1:0] paddr,
    input  logic [31:0]       pwdata,
    input  logic [3:0]        pstrb,
    output logic [31:0]       prdata,
    output logic              pready,
    output logic              pslverr,

    // Peripheral side
    input  logic              hw_evt,
    output logic              irq_o
);

    // Word offsets. Kept as plain localparams so the map is readable at a
    // glance; the testbench keeps its own independent copy on purpose.
    localparam logic [ADDR_W-1:0] A_CTRL     = 'h000;
    localparam logic [ADDR_W-1:0] A_STATUS   = 'h004;
    localparam logic [ADDR_W-1:0] A_INT_STAT = 'h008;
    localparam logic [ADDR_W-1:0] A_SCRATCH  = 'h00C;
    localparam logic [ADDR_W-1:0] A_DATA0    = 'h010;
    localparam logic [ADDR_W-1:0] A_DATA3    = 'h01C;
    localparam logic [ADDR_W-1:0] A_ID       = 'h020;

    // Only these CTRL bits physically exist; the rest read back as zero.
    localparam logic [31:0] CTRL_MASK = 32'h0000_00F3;

    logic [31:0] ctrl_q;
    logic [15:0] evt_cnt_q;
    logic        int_stat_q;
    logic [31:0] scratch_q;
    logic [31:0] data_q [4];

    // ------------------------------------------------------------------
    // Address decode
    // ------------------------------------------------------------------
    logic in_data_win;
    logic addr_ok;
    logic [1:0] data_idx;

    assign in_data_win = (paddr >= A_DATA0) && (paddr <= A_DATA3);
    assign data_idx    = paddr[3:2];

    always_comb begin
        // Misaligned accesses are rejected outright rather than rounded down,
        // which is what most real peripherals do and is easy to reason about.
        if (paddr[1:0] != 2'b00) begin
            addr_ok = 1'b0;
        end else begin
            addr_ok = (paddr == A_CTRL)   || (paddr == A_STATUS) ||
                      (paddr == A_INT_STAT) || (paddr == A_SCRATCH) ||
                      in_data_win         || (paddr == A_ID);
        end
    end

    // ------------------------------------------------------------------
    // Wait-state generation
    //
    // Reads of the DATA window model a slower storage element: the first
    // ACCESS cycle holds PREADY low while the word is registered, and the
    // transfer completes on the next cycle. Everything else is zero-wait.
    // ------------------------------------------------------------------
    logic slow_rd;
    logic ws_done_q;
    logic [31:0] slow_rdata_q;

    assign slow_rd = psel && !pwrite && in_data_win && addr_ok;

    always_ff @(posedge pclk or negedge presetn) begin
        if (!presetn) begin
            ws_done_q    <= 1'b0;
            slow_rdata_q <= '0;
        end else if (slow_rd && penable && !ws_done_q) begin
            ws_done_q    <= 1'b1;
            slow_rdata_q <= data_q[data_idx];
        end else begin
            ws_done_q    <= 1'b0;
        end
    end

    assign pready = !(slow_rd && penable && !ws_done_q);

    // A transfer "happens" on the edge where PSEL, PENABLE and PREADY are all
    // high. Every state update below is qualified with this single signal so
    // the RTL and the reference model agree on exactly one commit point.
    logic xfer_done;
    logic wr_commit;

    assign xfer_done = psel && penable && pready;
    assign wr_commit = xfer_done && pwrite && addr_ok;
    assign pslverr   = xfer_done && !addr_ok;

    // Byte-lane write mask expanded from PSTRB.
    logic [31:0] be_mask;
    assign be_mask = {{8{pstrb[3]}}, {8{pstrb[2]}}, {8{pstrb[1]}}, {8{pstrb[0]}}};

    // ------------------------------------------------------------------
    // Register state
    // ------------------------------------------------------------------
    logic evt_hit;
    assign evt_hit = hw_evt && ctrl_q[0];

    always_ff @(posedge pclk or negedge presetn) begin
        if (!presetn) begin
            ctrl_q    <= '0;
            scratch_q <= '0;
            for (int i = 0; i < 4; i++) data_q[i] <= '0;
        end else if (wr_commit) begin
            if (paddr == A_CTRL)
                ctrl_q <= ((ctrl_q & ~be_mask) | (pwdata & be_mask)) & CTRL_MASK;
            if (paddr == A_SCRATCH)
                scratch_q <= (scratch_q & ~be_mask) | (pwdata & be_mask);
            if (in_data_win) begin
`ifdef BUG_STRB
                data_q[data_idx] <= pwdata;
`else
                data_q[data_idx] <= (data_q[data_idx] & ~be_mask) | (pwdata & be_mask);
`endif
            end
        end
    end

    // Event counter: free-running 16-bit wrap. Counting uses the CTRL value
    // from before the current edge, so enabling and an event on the same
    // edge does not count that event.
    always_ff @(posedge pclk or negedge presetn) begin
        if (!presetn)
            evt_cnt_q <= '0;
        else if (evt_hit)
            evt_cnt_q <= evt_cnt_q + 16'd1;
    end

    // Sticky interrupt flag. The clear term is computed first and the set
    // term is OR-ed in afterwards, which is what makes "set wins" hold.
    logic w1c_clear;
`ifdef BUG_W1C
    assign w1c_clear = wr_commit && (paddr == A_INT_STAT);
`else
    assign w1c_clear = wr_commit && (paddr == A_INT_STAT) && pstrb[0] && pwdata[0];
`endif

    always_ff @(posedge pclk or negedge presetn) begin
        if (!presetn)
            int_stat_q <= 1'b0;
        else
            int_stat_q <= (int_stat_q && !w1c_clear) || evt_hit;
    end

    assign irq_o = int_stat_q && ctrl_q[1];

    // ------------------------------------------------------------------
    // Read data mux. PRDATA is only meaningful on the completing cycle of a
    // read; it is driven to zero otherwise so stale data never leaks out.
    // ------------------------------------------------------------------
    always_comb begin
        prdata = '0;
        if (xfer_done && !pwrite && addr_ok) begin
            if (in_data_win)               prdata = slow_rdata_q;
            else if (paddr == A_CTRL)      prdata = ctrl_q;
            else if (paddr == A_STATUS)    prdata = {16'h0, evt_cnt_q};
            else if (paddr == A_INT_STAT)  prdata = {31'h0, int_stat_q};
            else if (paddr == A_SCRATCH)   prdata = scratch_q;
            else if (paddr == A_ID)        prdata = ID_VAL;
        end
    end

    // ------------------------------------------------------------------
    // Designer-side assertions. These encode two intentions of the design
    // that are cheap to check locally and painful to debug from the bus.
    // ------------------------------------------------------------------
// NO_SVA: some free simulator licences (e.g. Riviera on EDA Playground)
// refuse to elaborate modules containing concurrent assertions.
`ifndef SYNTHESIS
`ifndef NO_SVA
    // An enabled event must always leave the sticky flag set on the next
    // cycle, whatever software is doing on the bus at the time.
    a_evt_sets_flag: assert property (@(posedge pclk) disable iff (!presetn)
        evt_hit |=> int_stat_q)
        else $error("RTL: hw_evt while enabled did not set INT_STAT");

    // An error response must never be produced for a mapped address.
    a_no_err_on_legal: assert property (@(posedge pclk) disable iff (!presetn)
        pslverr |-> !addr_ok)
        else $error("RTL: PSLVERR asserted for a legal address 0x%0h", paddr);
`endif
`endif

endmodule
