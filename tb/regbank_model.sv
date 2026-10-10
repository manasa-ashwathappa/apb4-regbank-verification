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
