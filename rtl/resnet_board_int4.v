// ============================================================
// resnet_board_int4.v — INT4 ResNet board wrapper (Z7-Nano R20)
// ============================================================
// PS7 (GP0, AXI3) → AXI3-adapted Lite slave → resnet_top_int4 core.
// AXI3 adaptation is the proven lab09 pattern (BID/RID reflection,
// RLAST=1, WLAST latched, write backpressure) — identical to the
// INT16 resnet_board.v that ran on the board.
//
// Register map @ 0x40000000:
//   0x00 CTRL  write bit0=1 → start pulse (edge-detected)
//              read {30'0, done, busy}
//   0x08 RO    {out1, out0}   (INT16 two's complement each)
//   0x0C RO    {out3, out2}
// ============================================================
module resnet_board_int4;

    wire [3:0] fclk_bus;
    wire fclk0 = fclk_bus[0];
    wire [3:0] fclk_reset_n_bus;
    wire aresetn = fclk_reset_n_bus[0];

    // ---------- AXI GP0 ----------
    wire [31:0] gp0_awaddr;
    wire        gp0_awvalid, gp0_awready;
    wire [11:0] gp0_awid;
    wire [31:0] gp0_araddr;
    wire        gp0_arvalid, gp0_arready;
    wire [11:0] gp0_arid;
    wire [31:0] gp0_wdata;
    wire        gp0_wvalid, gp0_wready;
    wire        gp0_wlast;
    wire        gp0_bvalid, gp0_bready;
    wire [1:0]  gp0_bresp;
    wire [31:0] gp0_rdata;
    wire        gp0_rvalid, gp0_rready;
    wire [1:0]  gp0_rresp;
    reg  [11:0] gp0_bid, gp0_rid;

    // AXI3 ID reflection (lab09 proven pattern)
    always @(posedge fclk0) begin
        if (!aresetn) begin
            gp0_bid <= 12'd0;
            gp0_rid <= 12'd0;
        end else begin
            if (gp0_awvalid && gp0_awready) gp0_bid <= gp0_awid;
            if (gp0_arvalid && gp0_arready) gp0_rid <= gp0_arid;
        end
    end

    PS7 PS7_i (
        .FCLKCLK(fclk_bus), .FCLKRESETN(fclk_reset_n_bus),
        .MAXIGP0ACLK(fclk0),
        .MAXIGP0AWADDR(gp0_awaddr), .MAXIGP0AWVALID(gp0_awvalid),
        .MAXIGP0AWREADY(gp0_awready), .MAXIGP0AWPROT(), .MAXIGP0AWID(gp0_awid),
        .MAXIGP0WDATA(gp0_wdata), .MAXIGP0WVALID(gp0_wvalid),
        .MAXIGP0WREADY(gp0_wready), .MAXIGP0WSTRB(), .MAXIGP0WLAST(gp0_wlast),
        .MAXIGP0BVALID(gp0_bvalid), .MAXIGP0BREADY(gp0_bready),
        .MAXIGP0BRESP(gp0_bresp), .MAXIGP0BID(gp0_bid),
        .MAXIGP0ARADDR(gp0_araddr), .MAXIGP0ARVALID(gp0_arvalid),
        .MAXIGP0ARREADY(gp0_arready), .MAXIGP0ARPROT(), .MAXIGP0ARID(gp0_arid),
        .MAXIGP0RVALID(gp0_rvalid), .MAXIGP0RREADY(gp0_rready),
        .MAXIGP0RDATA(gp0_rdata), .MAXIGP0RRESP(gp0_rresp),
        .MAXIGP0RID(gp0_rid), .MAXIGP0RLAST(1'b1)
    );

    // ---------- Lite slave ----------
    wire [31:0] ctrl_reg, speed_reg;
    wire        core_done, core_busy;
    wire signed [15:0] o0, o1, o2, o3;

    axi_lite_slave axi_if (
        .aclk(fclk0), .aresetn(aresetn),
        .s_axi_awaddr(gp0_awaddr[3:0]), .s_axi_awvalid(gp0_awvalid), .s_axi_awready(gp0_awready),
        .s_axi_wdata(gp0_wdata), .s_axi_wvalid(gp0_wvalid), .s_axi_wready(gp0_wready),
        .s_axi_wlast(gp0_wlast),
        .s_axi_bvalid(gp0_bvalid), .s_axi_bready(gp0_bready), .s_axi_bresp(gp0_bresp),
        .s_axi_araddr(gp0_araddr[3:0]), .s_axi_arvalid(gp0_arvalid), .s_axi_arready(gp0_arready),
        .s_axi_rvalid(gp0_rvalid), .s_axi_rready(gp0_rready), .s_axi_rresp(gp0_rresp),
        .s_axi_rdata(gp0_rdata),
        .ctrl(ctrl_reg), .speed(speed_reg),
        .out_rd0({o1, o0}), .out_rd1({o3, o2}),
        .status_in({core_done, core_busy})
    );

    // ---------- Start pulse: edge-detect ctrl_reg[0] ----------
    reg ctrl_d;
    always @(posedge fclk0) ctrl_d <= ctrl_reg[0];
    wire start_pulse = ctrl_reg[0] && !ctrl_d;

    // ---------- INT4 core ----------
    resnet_top_int4 core (
        .aclk(fclk0), .aresetn(aresetn), .start(start_pulse),
        .done(core_done), .busy(core_busy),
        .out0(o0), .out1(o1), .out2(o2), .out3(o3)
    );

endmodule
