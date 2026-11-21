// ============================================================
// resnet_top_int4.v — INT4-quantized ResNet CNN core (3~4 MACs/cycle)
// ============================================================
// Architecture: Input(3×16×16, INT16) → Conv3×3(3→8, INT4 weights)+ReLU
//               → MaxPool2×2 → Flatten(512) → FC(512→4, INT4 weights)
//
// Speed techniques vs the INT16 version (1 MAC/cycle):
//   1. Packed weights: one 16-bit BRAM word = one conv KERNEL ROW
//      [kx0,kx1,kx2,pad] → 3 parallel MACs per cycle in conv.
//      For FC: one word = 4 consecutive inputs → 4 parallel MACs/cycle.
//   2. Line buffer: 3 input rows × 3 channels held in registers (144×16b),
//      sliding window taps read registers, not BRAM.
//   3. Banked memories:
//      conv_out split by (y parity, x parity) → pool reads all 4 taps
//      of a 2×2 window in ONE cycle (each tap lives in its own bank,
//      all at the same address).
//      pool_out split by flat index mod 4 → FC reads 4 activations/cycle.
//
// Cycle budget (measured in sim, total 21762):
//   load: 16 oy × 144 (3ch × 3rows × 16x)      = 2304
//   conv: 2048 pixels × 9 (ci,ky) × 3 MACs     = 18432
//   pool: 512 (4 taps in parallel via banking)
//   fc:   4 outputs × 128 steps × 4 MACs       = 512
//   vs INT16 version ≈59.4k cycles → 2.7× faster at same FCLK
// ============================================================
module resnet_top_int4 (
    input  wire        aclk,
    input  wire        aresetn,
    input  wire        start,       // 1-cycle pulse
    output reg         done,
    output reg         busy,
    output reg  [3:0]  run_cnt,    // +1 on each accepted start (wraps)
    output wire signed [15:0] out0,
    output wire signed [15:0] out1,
    output wire signed [15:0] out2,
    output wire signed [15:0] out3
);

    localparam IN_CH=3, IN_H=16, IN_W=16, OUT_CH=8;
    localparam FC_IN=512, FC_OUT=4;

    localparam [2:0] S_IDLE=0, S_LOAD=1, S_CONV=2, S_POOL=3, S_FC=4, S_DONE=5;
    reg [2:0] state;

    // Main loop counters
    reg [3:0] oy, ox;        // conv output coords 0..15
    reg [2:0] co;            // output channel 0..7
    reg [1:0] ci, ky;        // input channel / kernel row 0..2
    // Row-buffer load counters
    reg [1:0] lci, lr;       // load: channel / row 0..2
    reg [3:0] lx;            // load: x 0..15
    // Pool counters
    reg [2:0] pc, py, px;    // pool channel / y / x 0..7
    // FC counters
    reg [1:0] fo;            // fc output 0..3
    reg [6:0] fiq;           // fc input quarter-index 0..127 (4 inputs per step)
    reg signed [31:0] acc;

    // ========================================================
    // Memories
    // ========================================================
    // Hex paths default to repo-root-relative (iverilog: run from repo
    // root). Vivado project-mode synth runs in its own directory, so
    // build_int4.tcl injects absolute paths via verilog_define — do NOT
    // revert to hardcoded relative-only paths (synth silently zero-fills,
    // CRITICAL WARNING Synth 8-4445, outputs all zero on hardware).
`ifndef INPUT_HEX
    `define INPUT_HEX "sim/hex_int4/input.hex"
`endif
`ifndef CONV_W_HEX
    `define CONV_W_HEX "sim/hex_int4/conv_weight_packed.hex"
`endif
`ifndef CONV_B_HEX
    `define CONV_B_HEX "sim/hex_int4/conv_bias.hex"
`endif
`ifndef FC_W_HEX
    `define FC_W_HEX "sim/hex_int4/fc_weight_packed.hex"
`endif
`ifndef FC_B_HEX
    `define FC_B_HEX "sim/hex_int4/fc_bias.hex"
`endif

    (* ram_style = "block" *) reg signed [15:0] input_mem [0:767];
    initial $readmemh(`INPUT_HEX, input_mem);

    // INT4 packed: word[co*9 + ci*3 + ky] = {pad, kx2, kx1, kx0}
    (* rom_style = "block" *) reg [15:0] conv_w_pk [0:71];
    initial $readmemh(`CONV_W_HEX, conv_w_pk);

    (* rom_style = "distributed" *) reg signed [15:0] conv_b [0:7];
    initial $readmemh(`CONV_B_HEX, conv_b);

    // INT4 packed: word[fo*128 + fiq] = {w[fi3], w[fi2], w[fi1], w[fi0]}
    (* rom_style = "block" *) reg [15:0] fc_w_pk [0:511];
    initial $readmemh(`FC_W_HEX, fc_w_pk);

    (* rom_style = "distributed" *) reg signed [15:0] fc_b [0:3];
    initial $readmemh(`FC_B_HEX, fc_b);

    // Line buffer: 3 ch × 3 rows × 16 x, flattened to [0:143]
    // entry (ci*3+row)*16 + x ; row0 = y-1, row1 = y, row2 = y+1 (clamped)
    reg signed [15:0] lb [0:143];

    // conv_out banked by {y[0], x[0]}: bank r*c holds pixels of that parity
    // at address co*64 + (y>>1)*8 + (x>>1)  → pool reads 1 addr in 4 banks
    (* ram_style = "block" *) reg signed [15:0] cb00 [0:511];
    (* ram_style = "block" *) reg signed [15:0] cb01 [0:511];
    (* ram_style = "block" *) reg signed [15:0] cb10 [0:511];
    (* ram_style = "block" *) reg signed [15:0] cb11 [0:511];

    // pool_out banked by flat index mod 4 → FC reads 4 activations/cycle
    (* ram_style = "block" *) reg signed [15:0] pb0 [0:127];
    (* ram_style = "block" *) reg signed [15:0] pb1 [0:127];
    (* ram_style = "block" *) reg signed [15:0] pb2 [0:127];
    (* ram_style = "block" *) reg signed [15:0] pb3 [0:127];

    // out_hold: FC stages write here; out_mem is published ATOMICALLY in
    // S_DONE (all 4 words same cycle) — a reset mid-FC can never expose a
    // half-updated result alongside status=0 (codex finding #9)
    (* ram_style = "distributed" *) reg signed [15:0] out_hold [0:3];
    (* ram_style = "distributed" *) reg signed [15:0] out_mem [0:3];
    assign out0 = out_mem[0];
    assign out1 = out_mem[1];
    assign out2 = out_mem[2];
    assign out3 = out_mem[3];

    // ========================================================
    // S_LOAD: fill line buffer rows y-1, y, y+1 (clamped to [0,15])
    // ========================================================
    wire [3:0] rowy = (lr == 0) ? ((oy == 0) ? 4'd0 : oy - 4'd1)
                   : (lr == 1) ? oy
                               : ((oy == 15) ? 4'd15 : oy + 4'd1);
    wire [9:0] ld_addr = {lci, rowy, lx};

    // ========================================================
    // S_CONV: 3 MACs per cycle (one packed kernel row × 3 activations)
    // ========================================================
    wire [6:0] cw_addr = co*9 + ci*3 + ky;  // arithmetic! (×9 not power-of-2, can't use concat)
    wire [15:0] cw = conv_w_pk[cw_addr];
    wire signed [7:0] wv0 = {{4{cw[3]}},  cw[3:0]};
    wire signed [7:0] wv1 = {{4{cw[7]}},  cw[7:4]};
    wire signed [7:0] wv2 = {{4{cw[11]}}, cw[11:8]};

    // Tap validity (same border rule as INT16 version: pad=1, pad=0)
    wire row_ok    = (ky == 0) ? (oy != 0)  : (ky == 2) ? (oy != 15) : 1'b1;
    wire signed [15:0] a0 = (row_ok && ox != 0)  ? lb[(ci*3+ky)*16 + (ox-4'd1)] : 16'sd0;
    wire signed [15:0] a1 = (row_ok)             ? lb[(ci*3+ky)*16 +  ox]       : 16'sd0;
    wire signed [15:0] a2 = (row_ok && ox != 15) ? lb[(ci*3+ky)*16 + (ox+4'd1)] : 16'sd0;

    wire signed [31:0] mac3 = a0*wv0 + a1*wv1 + a2*wv2;

    wire signed [31:0] conv_final = conv_b[co] + acc + mac3;
    wire signed [15:0] conv_relu  = conv_final[31] ? 16'sd0 : conv_final[15:0];

    // conv_out write address/bank
    wire [1:0] cv_bank = {oy[0], ox[0]};  // explicit width! (implicit wire = 1 bit, silently truncates)
    wire [8:0] cv_addr = {co, oy[3:1], ox[3:1]};

    // ========================================================
    // S_POOL: all 4 taps of the 2×2 window in one cycle (banked)
    // ========================================================
    wire [8:0] paddr = {pc, py, px};
    wire signed [15:0] p00 = cb00[paddr];  // tap (2py,   2px  )
    wire signed [15:0] p01 = cb01[paddr];  // tap (2py,   2px+1)
    wire signed [15:0] p10 = cb10[paddr];  // tap (2py+1, 2px  )
    wire signed [15:0] p11 = cb11[paddr];  // tap (2py+1, 2px+1)
    wire signed [15:0] pmax =
        (p00 > p01) ? ((p00 > p10) ? ((p00 > p11) ? p00 : p11) : ((p10 > p11) ? p10 : p11))
                    : ((p01 > p10) ? ((p01 > p11) ? p01 : p11) : ((p10 > p11) ? p10 : p11));

    // pool write: flat = pc*64+py*8+px, bank = flat[1:0], addr = flat[8:2]
    wire [8:0] pf = {pc, py, px};

    // ========================================================
    // S_FC: 4 MACs per cycle (packed weights × 4 banked activations)
    // ========================================================
    wire [8:0] fwa = {fo, fiq};
    wire [15:0] fw = fc_w_pk[fwa];
    wire signed [7:0] fv0 = {{4{fw[3]}},  fw[3:0]};
    wire signed [7:0] fv1 = {{4{fw[7]}},  fw[7:4]};
    wire signed [7:0] fv2 = {{4{fw[11]}}, fw[11:8]};
    wire signed [7:0] fv3 = {{4{fw[15]}}, fw[15:12]};
    wire signed [31:0] mac4 = pb0[fiq]*fv0 + pb1[fiq]*fv1 + pb2[fiq]*fv2 + pb3[fiq]*fv3;

    wire signed [31:0] fc_final = fc_b[fo] + acc + mac4;

    // ========================================================
    // FSM
    // ========================================================
    always @(posedge aclk) begin
        if (!aresetn) begin
            state <= S_IDLE; done <= 0; busy <= 0; run_cnt <= 0;
            oy <= 0; ox <= 0; co <= 0; ci <= 0; ky <= 0;
            lci <= 0; lr <= 0; lx <= 0;
            pc <= 0; py <= 0; px <= 0;
            fo <= 0; fiq <= 0; acc <= 0;
        end else begin
            case (state)
                S_IDLE: begin
                    // sticky done: set in S_DONE, cleared only by next start.
                    // (A 1-cycle done pulse can never be seen by PS polling
                    //  over AXI — reads take ~ms, the pulse lasts 20ns.)
                    if (start) begin
                        done <= 0;
                        busy <= 1;
                        run_cnt <= run_cnt + 4'd1;
                        oy <= 0; co <= 0; ci <= 0; ky <= 0; acc <= 0;
                        lci <= 0; lr <= 0; lx <= 0;
                        state <= S_LOAD;
                    end
                end

                // Load 3 rows × 3 channels = 48 words into lb
                S_LOAD: begin
                    lb[(lci*3+lr)*16 + lx] <= input_mem[ld_addr];
                    if (lx != 15)      lx <= lx + 4'd1;
                    else if (lr != 2) begin lx <= 0; lr <= lr + 2'd1; end
                    else if (lci != 2) begin lx <= 0; lr <= 0; lci <= lci + 2'd1; end
                    else begin
                        lx <= 0; lr <= 0; lci <= 0;
                        ox <= 0; co <= 0; ci <= 0; ky <= 0; acc <= 0;
                        state <= S_CONV;
                    end
                end

                // 9 cycles per output pixel (ci,ky each 0..2), 3 MACs/cycle
                S_CONV: begin
                    acc <= acc + mac3;
                    if (ky != 2) ky <= ky + 2'd1;
                    else if (ci != 2) begin ky <= 0; ci <= ci + 2'd1; end
                    else begin
                        // finalize this pixel (bias+acc+mac3 via conv_final)
                        case (cv_bank)
                            2'b00: cb00[cv_addr] <= conv_relu;
                            2'b01: cb01[cv_addr] <= conv_relu;
                            2'b10: cb10[cv_addr] <= conv_relu;
                            2'b11: cb11[cv_addr] <= conv_relu;
                        endcase
                        ky <= 0; ci <= 0; acc <= 0;
                        if (co != 7) co <= co + 3'd1;
                        else if (ox != 15) begin co <= 0; ox <= ox + 4'd1; end
                        else if (oy != 15) begin
                            co <= 0; ox <= 0; oy <= oy + 4'd1;
                            lci <= 0; lr <= 0; lx <= 0;
                            state <= S_LOAD;   // reload rows for next oy
                        end
                        else begin
                            pc <= 0; py <= 0; px <= 0;
                            state <= S_POOL;
                        end
                    end
                end

                // 1 output pixel per cycle (4 banks read in parallel)
                S_POOL: begin
                    case (pf[1:0])
                        2'b00: pb0[pf[8:2]] <= pmax;
                        2'b01: pb1[pf[8:2]] <= pmax;
                        2'b10: pb2[pf[8:2]] <= pmax;
                        2'b11: pb3[pf[8:2]] <= pmax;
                    endcase
                    if (px != 7) px <= px + 3'd1;
                    else if (py != 7) begin px <= 0; py <= py + 3'd1; end
                    else if (pc != 7) begin px <= 0; py <= 0; pc <= pc + 3'd1; end
                    else begin
                        fo <= 0; fiq <= 0; acc <= 0;
                        state <= S_FC;
                    end
                end

                // 128 cycles per output, 4 MACs/cycle
                S_FC: begin
                    acc <= acc + mac4;
                    if (fiq != 127) fiq <= fiq + 7'd1;
                    else begin
                        out_hold[fo] <= fc_final[15:0];
                        fiq <= 0; acc <= 0;
                        if (fo != 3) fo <= fo + 2'd1;
                        else state <= S_DONE;
                    end
                end

                S_DONE: begin
                    // atomic publish: all four outputs in one cycle
                    out_mem[0] <= out_hold[0];
                    out_mem[1] <= out_hold[1];
                    out_mem[2] <= out_hold[2];
                    out_mem[3] <= out_hold[3];
                    busy <= 0; done <= 1; state <= S_IDLE;
                end

                default: state <= S_IDLE;
            endcase
        end
    end

endmodule
