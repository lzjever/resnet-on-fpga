// ============================================================
// resnet_top.v — Minimal ResNet CNN on Zynq XC7Z020
// ============================================================
// Architecture:  Input(3×16×16) → Conv3×3(3→8)+ReLU → MaxPool2×2
//                → Flatten(512) → FC(512→4) → Output(4)
//
// AXI-Lite slave at GP0 base (0x40000000):
//   0x00 CTRL:   write 1=start | read bit0=done, bit1=busy
//   0x04 DUMMY
//   0x10+i*4:    input data (384 32-bit words, 2×16-bit each)
//   0x20+i*4:    output data (2 32-bit words)
//
// Weights stored as ROM (compile-time $readmemh).
// All arithmetic: 16-bit signed integer.
// ============================================================
module resnet_top (
    input  wire        aclk,
    input  wire        aresetn,
    // AXI-Lite slave (from PS GP0)
    input  wire [31:0] s_axi_awaddr,
    input  wire        s_axi_awvalid,
    output wire        s_axi_awready,
    input  wire [31:0] s_axi_wdata,
    input  wire [31:0] s_axi_wstrb,
    input  wire        s_axi_wvalid,
    output wire        s_axi_wready,
    output wire        s_axi_bvalid,
    input  wire        s_axi_bready,
    output wire [1:0]  s_axi_bresp,
    input  wire [31:0] s_axi_araddr,
    input  wire        s_axi_arvalid,
    output wire        s_axi_arready,
    output wire [31:0] s_axi_rdata,
    output wire        s_axi_rvalid,
    input  wire        s_axi_rready,
    output wire [1:0]  s_axi_rresp
);

    // ========================================================
    // Parameters
    // ========================================================
    localparam IN_CH  = 3,  IN_H  = 16, IN_W  = 16;
    localparam OUT_CH = 8;
    localparam POOL_H = 8,  POOL_W = 8;
    localparam FC_IN  = OUT_CH * POOL_H * POOL_W;  // 512
    localparam FC_OUT = 4;
    localparam NUM_INPUT_WORDS = IN_CH * IN_H * IN_W / 2;  // 384 (2×16-bit per 32-bit)
    localparam NUM_OUTPUT_WORDS = FC_OUT / 2;  // 2

    // ========================================================
    // FSM States
    // ========================================================
    typedef enum reg [3:0] {
        S_IDLE, S_CONV, S_POOL, S_FC, S_DONE
    } state_t;
    state_t state;

    // Control
    reg start;
    reg done;
    reg busy;

    // Conv loop counters
    reg [3:0] co;        // output channel 0..7
    reg [4:0] oy, ox;    // output y,x 0..15
    reg [1:0] ky, kx;    // kernel y,x 0..2
    reg [1:0] ci;        // input channel 0..2

    // Pool loop counters
    reg [3:0] pc;        // pool channel 0..7
    reg [3:0] py, px;    // pool y,x 0..7

    // FC loop counters
    reg [2:0] fo;        // fc output 0..3
    reg [9:0] fi;        // fc input 0..511

    // Accumulator (wider to avoid overflow)
    reg signed [31:0] acc;

    // ========================================================
    // BRAM: Input buffer (768 × 16-bit)
    // ========================================================
    (* ram_style = "block" *)
    reg signed [15:0] input_mem [0:IN_CH*IN_H*IN_W-1];
    initial $readmemh("sim/hex/input.hex", input_mem);

    // ========================================================
    // ROM: Weights (compile-time constants)
    // ========================================================
    (* rom_style = "block" *)
    reg signed [15:0] conv_w [0:OUT_CH*IN_CH*9-1];
    initial $readmemh("sim/hex/conv_weight.hex", conv_w);

    (* rom_style = "distributed" *)
    reg signed [15:0] conv_b [0:OUT_CH-1];
    initial $readmemh("sim/hex/conv_bias.hex", conv_b);

    (* rom_style = "block" *)
    reg signed [15:0] fc_w [0:FC_OUT*FC_IN-1];
    initial $readmemh("sim/hex/fc_weight.hex", fc_w);

    (* rom_style = "distributed" *)
    reg signed [15:0] fc_b [0:FC_OUT-1];
    initial $readmemh("sim/hex/fc_bias.hex", fc_b);

    // ========================================================
    // BRAM: Intermediate buffers
    // ========================================================
    // Conv output (also serves as pool input)
    (* ram_style = "block" *)
    reg signed [15:0] conv_out [0:OUT_CH*IN_H*IN_W-1];  // 8*16*16=2048

    // Pool output (also serves as FC input)
    (* ram_style = "block" *)
    reg signed [15:0] pool_out [0:OUT_CH*POOL_H*POOL_W-1];  // 8*8*8=512

    // Final output
    (* ram_style = "distributed" *)
    reg signed [15:0] out_mem [0:FC_OUT-1];

    // ========================================================
    // Helper functions for index calculation
    // ========================================================
    // Input index: [ci][y][x] → ci*256 + y*16 + x
    function [11:0] input_idx;
        input [1:0] ci; input [4:0] y, x;
        input_idx = ci * 256 + y * 16 + x;
    endfunction

    // Conv weight index: [co][ci][ky][kx] → co*27 + ci*9 + ky*3 + kx
    function [10:0] conv_w_idx;
        input [3:0] co; input [1:0] ci, ky, kx;
        conv_w_idx = co * 27 + ci * 9 + ky * 3 + kx;
    endfunction

    // Conv output index: [co][y][x] → co*256 + y*16 + x
    function [11:0] conv_out_idx;
        input [3:0] co; input [4:0] y, x;
        conv_out_idx = co * 256 + y * 16 + x;
    endfunction

    // Pool output index: [pc][py][px] → pc*64 + py*8 + px
    function [9:0] pool_out_idx;
        input [3:0] pc; input [3:0] py, px;
        pool_out_idx = pc * 64 + py * 8 + px;
    endfunction

    // FC weight index: [fo][fi] → fo*512 + fi
    function [12:0] fc_w_idx;
        input [2:0] fo; input [9:0] fi;
        fc_w_idx = fo * 512 + fi;
    endfunction

    // ========================================================
    // AXI-Lite Slave
    // ========================================================
    reg axi_awready_r, axi_wready_r, axi_bvalid_r, axi_arready_r, axi_rvalid_r;
    reg [31:0] axi_rdata_r;
    reg [1:0]  axi_bresp_r, axi_rresp_r;
    reg [31:0] awaddr_q;
    reg [31:0] araddr_q;
    reg        write_done;  // AW+W both captured

    assign s_axi_awready = axi_awready_r;
    assign s_axi_wready  = axi_wready_r;
    assign s_axi_bvalid  = axi_bvalid_r;
    assign s_axi_bresp   = axi_bresp_r;
    assign s_axi_arready = axi_arready_r;
    assign s_axi_rdata   = axi_rdata_r;
    assign s_axi_rvalid  = axi_rvalid_r;
    assign s_axi_rresp   = axi_rresp_r;

    // Write channel
    always @(posedge aclk) begin
        if (!aresetn) begin
            axi_awready_r <= 0;
            axi_wready_r  <= 0;
            axi_bvalid_r  <= 0;
            write_done    <= 0;
            awaddr_q      <= 0;
        end else begin
            // Accept address
            if (s_axi_awvalid && axi_awready_r == 0 && !write_done) begin
                awaddr_q      <= s_axi_awaddr;
                axi_awready_r <= 1;
            end else begin
                axi_awready_r <= 0;
            end
            // Accept data
            if (s_axi_wvalid && axi_wready_r == 0 && !write_done) begin
                axi_wready_r <= 1;
            end else begin
                axi_wready_r <= 0;
            end
            // Both captured → process write
            if (s_axi_awvalid && s_axi_wvalid && !write_done && state == S_IDLE) begin
                write_done <= 1;
                axi_bvalid_r <= 1;
                axi_bresp_r  <= 2'b00;
                // Decode address and write
                case (s_axi_awaddr[7:0])
                    8'h00: begin // CTRL
                        if (s_axi_wdata[0]) start <= 1;
                    end
                    8'h10, 8'h14, 8'h18, 8'h1C, 8'h20, 8'h24, 8'h28, 8'h2C,
                    8'h30, 8'h34, 8'h38, 8'h3C, 8'h40, 8'h44, 8'h48, 8'h4C: begin
                        // Input data: offset 0x10, word index = (addr-0x10)/4
                        reg [8:0] wi;
                        wi = (s_axi_awaddr[7:0] - 8'h10) >> 2;
                        if (wi < NUM_INPUT_WORDS) begin
                            input_mem[wi*2]   <= s_axi_wdata[15:0];
                            input_mem[wi*2+1] <= s_axi_wdata[31:16];
                        end
                    end
                    default: ;
                endcase
            end else if (write_done && s_axi_bready) begin
                write_done   <= 0;
                axi_bvalid_r <= 0;
            end
        end
    end

    // Read channel
    always @(posedge aclk) begin
        if (!aresetn) begin
            axi_arready_r <= 0;
            axi_rvalid_r  <= 0;
            axi_rdata_r   <= 0;
            axi_rresp_r   <= 0;
        end else begin
            if (s_axi_arvalid && !axi_rvalid_r) begin
                axi_arready_r <= 1;
                araddr_q      <= s_axi_araddr;
            end else begin
                axi_arready_r <= 0;
            end

            if (s_axi_arvalid && axi_arready_r) begin
                axi_rvalid_r <= 1;
                axi_rresp_r  <= 2'b00;
                case (araddr_q[7:0])
                    8'h00: axi_rdata_r <= {30'd0, done, busy};
                    8'h20: axi_rdata_r <= {out_mem[1], out_mem[0]};  // first 2 outputs
                    8'h24: axi_rdata_r <= {out_mem[3], out_mem[2]};  // last 2 outputs
                    default: axi_rdata_r <= 32'd0;
                endcase
            end else if (axi_rvalid_r && s_axi_rready) begin
                axi_rvalid_r <= 0;
            end
        end
    end


    // Pool helper wires (computed combinationally from current counters)
    wire signed [15:0] pool_v0 = conv_out[conv_out_idx(pc, py*2,   px*2)];
    wire signed [15:0] pool_v1 = conv_out[conv_out_idx(pc, py*2,   px*2+1)];
    wire signed [15:0] pool_v2 = conv_out[conv_out_idx(pc, py*2+1, px*2)];
    wire signed [15:0] pool_v3 = conv_out[conv_out_idx(pc, py*2+1, px*2+1)];
    wire signed [15:0] pool_max =
        (pool_v0 > pool_v1) ? ((pool_v0 > pool_v2) ? ((pool_v0 > pool_v3) ? pool_v0 : pool_v3)
                                                     : ((pool_v2 > pool_v3) ? pool_v2 : pool_v3))
                            : ((pool_v1 > pool_v2) ? ((pool_v1 > pool_v3) ? pool_v1 : pool_v3)
                                                     : ((pool_v2 > pool_v3) ? pool_v2 : pool_v3));

    // ========================================================
    // Compute FSM
    // ========================================================
    // Conv signed multiplier result
    wire signed [31:0] conv_mul = input_mem[input_idx(ci, oy + ky - 1, ox + kx - 1)] *
                                   conv_w[conv_w_idx(co, ci, ky, kx)];

    // FC signed multiplier result
    wire signed [31:0] fc_mul = pool_out[fi] * fc_w[fc_w_idx(fo, fi)];

    // Border validity for conv (pad=1)
    wire border_valid = (oy + ky >= 1) && (oy + ky <= IN_H) &&
                        (ox + kx >= 1) && (ox + kx <= IN_W);

    // Conv result on last MAC: include bias + current mul in the result
    wire signed [31:0] conv_final = conv_b[co] + (border_valid ? (acc + conv_mul) : acc);
    wire signed [15:0] conv_relu  = conv_final[31] ? 16'd0 : conv_final[15:0];

    // FC result on last MAC: include current mul and bias
    wire signed [31:0] fc_final = acc + fc_mul + fc_b[fo];

    always @(posedge aclk) begin
        if (!aresetn) begin
            state <= S_IDLE;
            start <= 0;
            done  <= 0;
            busy  <= 0;
            co <= 0; oy <= 0; ox <= 0; ky <= 0; kx <= 0; ci <= 0;
            pc <= 0; py <= 0; px <= 0;
            fo <= 0; fi <= 0;
            acc <= 0;
        end else begin
            case (state)
                S_IDLE: begin
                    done <= 0;
                    if (start) begin
                        start <= 0;
                        busy  <= 1;
                        state <= S_CONV;
                        // Init conv counters
                        co <= 0; oy <= 0; ox <= 0;
                        ky <= 0; kx <= 0; ci <= 0;
                        acc <= 0;
                    end
                end

                S_CONV: begin
                    // Compute one MAC per cycle
                    // Border check: pad=1 means we read input[ci][oy+ky-1][ox+kx-1]
                    if (oy + ky >= 1 && oy + ky <= IN_H && ox + kx >= 1 && ox + kx <= IN_W) begin
                        acc <= acc + conv_mul;
                    end
                    // Advance kernel position
                    if (kx < 2) begin
                        kx <= kx + 1;
                    end else if (ky < 2) begin
                        kx <= 0; ky <= ky + 1;
                    end else if (ci < IN_CH - 1) begin
                        kx <= 0; ky <= 0; ci <= ci + 1;
                    end else begin
                        // One output pixel done: write ReLU result (includes last MAC via conv_final)
                        conv_out[conv_out_idx(co, oy, ox)] <= conv_relu;
                        // Reset for next pixel
                        kx <= 0; ky <= 0; ci <= 0; acc <= 0;
                        // Advance output position
                        if (ox < IN_W - 1) begin
                            ox <= ox + 1;
                        end else if (oy < IN_H - 1) begin
                            ox <= 0; oy <= oy + 1;
                        end else if (co < OUT_CH - 1) begin
                            ox <= 0; oy <= 0; co <= co + 1;
                        end else begin
                            // Conv done → start pool
                            state <= S_POOL;
                            pc <= 0; py <= 0; px <= 0;
                        end
                    end
                end

                S_POOL: begin
                    // Max pool 2×2: read 4 values, take max (uses pool_wires above)
                    pool_out[pool_out_idx(pc, py, px)] <= pool_max;

                    if (px < POOL_W - 1) begin
                        px <= px + 1;
                    end else if (py < POOL_H - 1) begin
                        px <= 0; py <= py + 1;
                    end else if (pc < OUT_CH - 1) begin
                        px <= 0; py <= 0; pc <= pc + 1;
                    end else begin
                        // Pool done → start FC
                        state <= S_FC;
                        fo <= 0; fi <= 0; acc <= 0;
                    end
                end

                S_FC: begin
                    // FC: one MAC per cycle
                    acc <= acc + fc_mul;
                    if (fi < FC_IN - 1) begin
                        fi <= fi + 1;
                    end else begin
                        // One output done (includes last MAC via fc_final)
                        out_mem[fo] <= fc_final[15:0];
                        fi <= 0; acc <= 0;
                        if (fo < FC_OUT - 1) begin
                            fo <= fo + 1;
                        end else begin
                            // All done
                            state <= S_DONE;
                        end
                    end
                end

                S_DONE: begin
                    busy <= 0;
                    done <= 1;
                    state <= S_IDLE;
                end

                default: state <= S_IDLE;
            endcase
        end
    end

endmodule
