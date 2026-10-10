# Verification Plan — `apb_regbank`

## 1. Scope

Block-level verification of an APB4 completer register bank: bus protocol,
register access semantics (RW / RO / W1C), byte strobes, error responses,
wait-state timing, and the interaction between the hardware event input and
software accesses. Out of scope: clock-domain crossing (single clock), power
management, and gate-level simulation.

## 2. Features and how each is verified

| ID  | Feature | Stimulus | Checker | Coverage bin(s) |
|-----|---------|----------|---------|-----------------|
| F1  | Reset values of all registers | `reset_test` | Scoreboard + `a_id_value` | `rd_<REG>` |
| F2  | RW registers store/return data | all tests | Scoreboard | `rd_/wr_<REG>` |
| F3  | RO registers ignore writes, no error | `reset_test`, random | Scoreboard + `a_id_ro` | `wr_STATUS`, `wr_ID` |
| F4  | CTRL reserved bits read as 0 | `strb_test` | Scoreboard + `a_ctrl_reserved` | `wr_CTRL` |
| F5  | PSTRB byte-lane writes | `strb_test`, random | Scoreboard | `strb_full/single_byte/partial/none` |
| F6  | Unmapped address → PSLVERR, no side effect | `err_test`, random | Scoreboard, RTL `a_no_err_on_legal` | `err_rd`, `err_wr` |
| F7  | Misaligned address → PSLVERR, no aliasing | `err_test` | Scoreboard + `a_no_alias` | `err_misaligned` |
| F8  | DATA window reads insert 1 wait state | all tests | Scoreboard (data), SVA `a_stable_in_wait` | `rd_with_wait_state` |
| F9  | Back-to-back transfers (no IDLE) | random | Scoreboard, SVA | `back_to_back` |
| F10 | Event counter counts only while enabled | `irq_w1c_test`, random | Scoreboard + `a_cnt_five` | `evt_while_disabled` |
| F11 | INT_STAT sticky set, W1C clear | `irq_w1c_test` | Scoreboard, RTL `a_evt_sets_flag` | `wr_INT_STAT` |
| F12 | Event and W1C clear on same edge → set wins | `irq_w1c_test`, random | Scoreboard | `evt_during_w1c_clear` |
| F13 | Enable change and event on same edge uses old enable | random | Scoreboard | `evt_during_ctrl_write` |
| F14 | `irq_o = INT_STAT & irq_en` every cycle | all tests | Scoreboard (per cycle) + `a_irq_high` | `irq_asserted` |
| P1  | APB4 handshake rules | all tests | `apb_protocol_checker` (5 SVA) | — |

## 3. Checking strategy

* **Reference model** (`regbank_model`) is table-driven and written from the
  spec header, not from the RTL decode, to avoid copying a misunderstanding.
* **Scoreboard** is cycle-accurate rather than transaction-only: it receives
  one observation per clock edge and replays it in RTL evaluation order
  (sample outputs → decide event with pre-edge enable → apply write → apply
  event). This is what makes F12/F13 checkable at all.
* **Assertions** at three levels: protocol SVA (bus contract), designer SVA in
  the RTL (local invariants), immediate assertions in directed tests (values
  fixed by the spec).

## 4. Coverage closure

Closure criterion: all 31 bins of the bin table hit across the regression.
Achieved with 5 tests × 10 seeds. On commercial simulators the covergroup
`cg_regbank` adds register×direction and register×event crosses.

## 5. Testbench validation (does the TB find bugs?)

| Mutation | Where | Caught by | First failing test |
|----------|-------|-----------|--------------------|
| `BUG_STRB`: DATA regs ignore PSTRB | RTL | Scoreboard read-data compare | `strb_test` (cycle 61) |
| `BUG_W1C`: any write clears INT_STAT | RTL | Scoreboard IRQ compare | `irq_w1c_test` (cycle 40) |
| Driver changes PADDR while stalled | TB | SVA `a_stable_in_wait` | `reset_test` |

## 6. Known limitations / future work

* Coverage merge is a text-level union of per-run bin tables, not a UCDB merge.
* Reset is only applied at time zero; mid-traffic reset is not exercised.
* No UVM: the environment is a hand-built layered TB. Porting to UVM
  (agent/sequencer/RAL model) is the natural next step.
* Traffic weights live in `pre_randomize()` rather than `dist` constraints
  (see the note at the top of `apb_txn.sv`).
