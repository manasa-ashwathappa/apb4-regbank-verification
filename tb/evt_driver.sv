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
