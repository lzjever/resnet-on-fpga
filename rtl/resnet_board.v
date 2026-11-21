// ============================================================
// resnet_board.v — Board wrapper using lab09's PROVEN AXI slave
// ============================================================
// Uses the same AXI3-adapted architecture as lab09 (verified working):
//   - BID/RID reflection
//   - RLAST=1, WLAST to slave
//   - Write backpressure (awready/wready gated by bvalid)
// ResNet FSM triggered via CTRL register bit0.
// Output readable from CTRL readback when done.
// ============================================================
module resnet_board;

    wire [3:0] fclk_bus;
    wire fclk0 = fclk_bus[0];
    wire [3:0] fclk_reset_n_bus;
    wire aresetn = fclk_reset_n_bus[0];

    // AXI GP0 signals
    wire [31:0] gp0_awaddr;
    wire        gp0_awvalid, gp0_awready;
    wire [11:0] gp0_awid;
    wire [31:0] gp0_wdata;
    wire        gp0_wvalid, gp0_wready;
    wire        gp0_wlast;
    wire        gp0_bvalid, gp0_bready;
    wire [1:0]  gp0_bresp;
    reg [11:0] gp0_bid;
    wire [31:0] gp0_araddr;
    wire        gp0_arvalid, gp0_arready;
    wire [11:0] gp0_arid;
    wire [31:0] gp0_rdata;
    wire        gp0_rvalid, gp0_rready;
    wire [1:0]  gp0_rresp;
    reg [11:0] gp0_rid;

    // AXI3 ID reflection (lab09 pattern)
    always @(posedge fclk0) begin
        if (!aresetn) begin
            gp0_bid <= 12'd0;
            gp0_rid <= 12'd0;
        end else begin
            if (gp0_awvalid && gp0_awready)
                gp0_bid <= gp0_awid;
            if (gp0_arvalid && gp0_arready)
                gp0_rid <= gp0_arid;
        end
    end

    PS7 PS7_i (
        .FCLKCLK         (fclk_bus),
        .FCLKRESETN      (fclk_reset_n_bus),
        .MAXIGP0ACLK     (fclk0),
        .MAXIGP0AWADDR  (gp0_awaddr),
        .MAXIGP0AWVALID (gp0_awvalid),
        .MAXIGP0AWREADY (gp0_awready),
        .MAXIGP0AWPROT  (),
        .MAXIGP0AWID    (gp0_awid),
        .MAXIGP0WDATA   (gp0_wdata),
        .MAXIGP0WVALID  (gp0_wvalid),
        .MAXIGP0WREADY  (gp0_wready),
        .MAXIGP0WSTRB   (),
        .MAXIGP0WLAST   (gp0_wlast),
        .MAXIGP0BVALID  (gp0_bvalid),
        .MAXIGP0BREADY  (gp0_bready),
        .MAXIGP0BRESP   (gp0_bresp),
        .MAXIGP0BID     (gp0_bid),
        .MAXIGP0ARADDR  (gp0_araddr),
        .MAXIGP0ARVALID (gp0_arvalid),
        .MAXIGP0ARREADY (gp0_arready),
        .MAXIGP0ARPROT  (),
        .MAXIGP0ARID    (gp0_arid),
        .MAXIGP0RVALID  (gp0_rvalid),
        .MAXIGP0RREADY  (gp0_rready),
        .MAXIGP0RDATA   (gp0_rdata),
        .MAXIGP0RRESP   (gp0_rresp),
        .MAXIGP0RID     (gp0_rid),
        .MAXIGP0RLAST   (1'b1)
    );

    // Lab09-style AXI-Lite slave (proven working, with backpressure)
    wire [31:0] ctrl_reg;   // 0x00: CTRL (bit0 = start)
    wire [31:0] speed_reg;  // 0x04: SPEED (unused for ResNet, kept for compat)

    axi_lite_slave axi_if (
        .aclk(fclk0), .aresetn(aresetn),
        .s_axi_awaddr(gp0_awaddr[3:0]),
        .s_axi_awvalid(gp0_awvalid), .s_axi_awready(gp0_awready),
        .s_axi_wdata(gp0_wdata),
        .s_axi_wvalid(gp0_wvalid), .s_axi_wready(gp0_wready),
        .s_axi_wlast(gp0_wlast),
        .s_axi_bvalid(gp0_bvalid), .s_axi_bready(gp0_bready), .s_axi_bresp(gp0_bresp),
        .s_axi_araddr(gp0_araddr[3:0]),
        .s_axi_arvalid(gp0_arvalid), .s_axi_arready(gp0_arready),
        .s_axi_rvalid(gp0_rvalid), .s_axi_rready(gp0_rready), .s_axi_rresp(gp0_rresp),
        .s_axi_rdata(gp0_rdata),
        .ctrl(ctrl_reg), .speed(speed_reg),
        .out_rd0({out_mem[1], out_mem[0]}),
        .out_rd1({out_mem[3], out_mem[2]}),
        .status_in({done, busy})
    );

    // ========================================================
    // ResNet FSM (connected to AXI via ctrl_reg[0] = start)
    // ========================================================
    localparam IN_CH=3, IN_H=16, IN_W=16, OUT_CH=8, POOL_H=8, POOL_W=8;
    localparam FC_IN=512, FC_OUT=4;

    localparam [3:0] S_IDLE=0, S_CONV=1, S_POOL=2, S_FC=3, S_DONE=4;
    reg [3:0] state;
    reg done, busy;

    // Counters
    reg [3:0] co; reg [4:0] oy, ox; reg [1:0] ky, kx, ci;
    reg [3:0] pc; reg [3:0] py, px;
    reg [2:0] fo; reg [9:0] fi;
    reg signed [31:0] acc;

    // Memory
    (* ram_style = "block" *) reg signed [15:0] input_mem [0:767];
    initial $readmemh("/home/percy/works/resnet-on-fpga/sim/hex/input.hex", input_mem);
    (* rom_style = "block" *) reg signed [15:0] conv_w [0:215];
    initial $readmemh("/home/percy/works/resnet-on-fpga/sim/hex/conv_weight.hex", conv_w);
    (* rom_style = "distributed" *) reg signed [15:0] conv_b [0:7];
    initial $readmemh("/home/percy/works/resnet-on-fpga/sim/hex/conv_bias.hex", conv_b);
    (* rom_style = "block" *) reg signed [15:0] fc_w [0:2047];
    initial $readmemh("/home/percy/works/resnet-on-fpga/sim/hex/fc_weight.hex", fc_w);
    (* rom_style = "distributed" *) reg signed [15:0] fc_b [0:3];
    initial $readmemh("/home/percy/works/resnet-on-fpga/sim/hex/fc_bias.hex", fc_b);
    (* ram_style = "block" *) reg signed [15:0] conv_out [0:2047];
    (* ram_style = "block" *) reg signed [15:0] pool_out [0:511];
    (* ram_style = "distributed" *) reg signed [15:0] out_mem [0:3];

    // Index functions
    function [11:0] input_idx(input [1:0] ci, input [4:0] y, input [4:0] x);
        input_idx = ci*256 + y*16 + x;
    endfunction
    function [10:0] conv_w_idx(input [3:0] co, input [1:0] ci, input [1:0] ky, input [1:0] kx);
        conv_w_idx = co*27 + ci*9 + ky*3 + kx;
    endfunction
    function [11:0] conv_out_idx(input [3:0] co, input [4:0] y, input [4:0] x);
        conv_out_idx = co*256 + y*16 + x;
    endfunction
    function [9:0] pool_out_idx(input [3:0] pc, input [3:0] py, input [3:0] px);
        pool_out_idx = pc*64 + py*8 + px;
    endfunction
    function [12:0] fc_w_idx(input [2:0] fo, input [9:0] fi);
        fc_w_idx = fo*512 + fi;
    endfunction

    // Helper wires
    wire border_valid = (oy + ky >= 1) && (oy + ky <= 16) && (ox + kx >= 1) && (ox + kx <= 16);
    wire signed [31:0] conv_mul = input_mem[input_idx(ci, oy+ky-1, ox+kx-1)] *
                                   conv_w[conv_w_idx(co, ci, ky, kx)];
    wire signed [31:0] conv_final = conv_b[co] + (border_valid ? (acc + conv_mul) : acc);
    wire signed [15:0] conv_relu = conv_final[31] ? 16'd0 : conv_final[15:0];
    wire signed [31:0] fc_mul = pool_out[fi] * fc_w[fc_w_idx(fo, fi)];
    wire signed [31:0] fc_final = acc + fc_mul + fc_b[fo];
    wire signed [15:0] pool_v0 = conv_out[conv_out_idx(pc, py*2, px*2)];
    wire signed [15:0] pool_v1 = conv_out[conv_out_idx(pc, py*2, px*2+1)];
    wire signed [15:0] pool_v2 = conv_out[conv_out_idx(pc, py*2+1, px*2)];
    wire signed [15:0] pool_v3 = conv_out[conv_out_idx(pc, py*2+1, px*2+1)];
    wire signed [15:0] pool_max =
        (pool_v0 > pool_v1) ? ((pool_v0 > pool_v2) ? ((pool_v0 > pool_v3) ? pool_v0 : pool_v3)
                                                    : ((pool_v2 > pool_v3) ? pool_v2 : pool_v3))
                            : ((pool_v1 > pool_v2) ? ((pool_v1 > pool_v3) ? pool_v1 : pool_v3)
                                                    : ((pool_v2 > pool_v3) ? pool_v2 : pool_v3));

    // FSM
    always @(posedge fclk0) begin
        if (!aresetn) begin
            state <= S_IDLE; done <= 0; busy <= 0;
            co <= 0; oy <= 0; ox <= 0; ky <= 0; kx <= 0; ci <= 0;
            pc <= 0; py <= 0; px <= 0; fo <= 0; fi <= 0; acc <= 0;
        end else begin
            case (state)
                S_IDLE: begin
                    done <= 0;
                    if (ctrl_reg[0]) begin
                        busy <= 1; state <= S_CONV;
                        co <= 0; oy <= 0; ox <= 0; ky <= 0; kx <= 0; ci <= 0; acc <= 0;
                    end
                end
                S_CONV: begin
                    if (border_valid) acc <= acc + conv_mul;
                    if (kx < 2) kx <= kx + 1;
                    else if (ky < 2) begin kx <= 0; ky <= ky + 1; end
                    else if (ci < 2) begin kx <= 0; ky <= 0; ci <= ci + 1; end
                    else begin
                        conv_out[conv_out_idx(co, oy, ox)] <= conv_relu;
                        kx <= 0; ky <= 0; ci <= 0; acc <= 0;
                        if (ox < 15) ox <= ox + 1;
                        else if (oy < 15) begin ox <= 0; oy <= oy + 1; end
                        else if (co < 7) begin ox <= 0; oy <= 0; co <= co + 1; end
                        else begin state <= S_POOL; pc <= 0; py <= 0; px <= 0; end
                    end
                end
                S_POOL: begin
                    pool_out[pool_out_idx(pc, py, px)] <= pool_max;
                    if (px < 7) px <= px + 1;
                    else if (py < 7) begin px <= 0; py <= py + 1; end
                    else if (pc < 7) begin px <= 0; py <= 0; pc <= pc + 1; end
                    else begin state <= S_FC; fo <= 0; fi <= 0; acc <= 0; end
                end
                S_FC: begin
                    acc <= acc + fc_mul;
                    if (fi < 511) fi <= fi + 1;
                    else begin
                        out_mem[fo] <= fc_final[15:0];
                        fi <= 0; acc <= 0;
                        if (fo < 3) fo <= fo + 1;
                        else state <= S_DONE;
                    end
                end
                S_DONE: begin
                    busy <= 0; done <= 1; state <= S_IDLE;
                end
            endcase
        end
    end

endmodule
