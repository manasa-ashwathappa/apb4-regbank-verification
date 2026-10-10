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
