// ============================================================
// Lab 09 · AXI4-Lite 从机(两寄存器版)
// ============================================================
// 相比 lab08 版的全部改动(DIFF 已标注):
//   1. 多了一个寄存器 SPEED(偏移 0x04)
//   2. 写/读时用锁存的地址做译码(case),CTRL/SPEED 各归各门
// 行为仍然一句话:写 = 存值,读 = 回值。
//
// 寄存器映射(Register Map):
//   偏移 0x00  CTRL   写=bit0 启动脉冲;读={30'0, done, busy}(int4 版)
//   偏移 0x04  SPEED  读写  (保留,ResNet 未用)
//   偏移 0x08  RO     ResNet 输出 [0:1](写入忽略——全译码)
//   偏移 0x0C  RO     ResNet 输出 [2:3](写入忽略——全译码)
// 注:CTRL 读回原为写入值影子,int4 版改为回状态(done/busy)——仅读路径,
//     写路径(AXI3 背压/WLAST/BID 反射)保持 lab09 验证过的原样;
//     写译码已从 1 位(awbuf[2],0x08 会误落 CTRL)改为全译码(awbuf[3:2])。
module axi_lite_slave #(
    parameter ADDR_W = 5
)(
    input  wire              aclk,
    input  wire              aresetn,
    // ---------- 写地址通道 AW ----------
    input  wire [ADDR_W-1:0] s_axi_awaddr,
    input  wire              s_axi_awvalid,
    output wire              s_axi_awready,
    // ---------- 写数据通道 W ----------
    input  wire [31:0]       s_axi_wdata,
    input  wire              s_axi_wvalid,
    output wire              s_axi_wready,
    input  wire              s_axi_wlast,   // AXI3:末拍标记(单拍写恒 1)
    // ---------- 写响应通道 B ----------
    output reg               s_axi_bvalid,
    input  wire              s_axi_bready,
    output reg  [1:0]        s_axi_bresp,
    // ---------- 读地址通道 AR ----------
    input  wire [ADDR_W-1:0] s_axi_araddr,
    input  wire              s_axi_arvalid,
    output wire              s_axi_arready,
    // ---------- 读数据通道 R ----------
    output reg               s_axi_rvalid,
    output reg  [31:0]       s_axi_rdata,
    input  wire              s_axi_rready,
    output reg  [1:0]        s_axi_rresp,
    // ---------- 两个旋钮的对外化身 ----------
    output wire [31:0]       ctrl,      // ← 0x00 的影子
    output wire [31:0]       speed,     // ← 0x04 的影子
    input  wire [31:0]       out_rd0,   // ← 0x08 RO(ResNet 输出)
    input  wire [31:0]       out_rd1,   // ← 0x0C RO(ResNet 输出)
    input  wire [5:0]        status_in  // ← {run_cnt[3:0], done, busy},CTRL 读回
);

    // bresp/rresp: OKAY inside the 0x00–0x0C aperture, SLVERR outside
    // (codex #8: upper address bits were dropped — a write to 0x10 etc.
    //  aliased into CTRL and could START the core; now rejected).

    // ========================================================
    // 写路径(与 lab08 相同的"各自记账,到齐落值",多了 case 译码)
    // ========================================================
    reg              aw_seen, w_seen;
    reg              wlastbuf;       // AXI3:锁存 WLAST(单拍写=1)
    reg [ADDR_W-1:0] awbuf;          // 成交拍锁存的地址(译码用它的低位)
    reg [31:0]       wbuf;           // 成交拍锁存的数据
    reg [31:0]       reg_ctrl;       // 0x00 CTRL
    reg [31:0]       reg_speed;      // 0x04 SPEED        ← DIFF:多一个寄存器
    wire write_fire = aw_seen && w_seen && wlastbuf;  // AXI3:须确认末拍

    // 背压修复(codex):BVALID 挂着时不收新写——防丢响应
    assign s_axi_awready = aresetn && !aw_seen && !s_axi_bvalid;
    assign s_axi_wready  = aresetn && !w_seen  && !s_axi_bvalid;

    always @(posedge aclk) begin
        if (!aresetn) begin
            aw_seen <= 1'b0;  w_seen <= 1'b0;
            reg_ctrl <= 32'd0;  reg_speed <= 32'd0;
            s_axi_bvalid <= 1'b0;
            s_axi_bresp  <= 2'b00;
        end else begin
            if (s_axi_awvalid && s_axi_awready) begin
                aw_seen <= 1'b1;
                awbuf   <= s_axi_awaddr;
            end
            if (s_axi_wvalid && s_axi_wready) begin
                w_seen <= 1'b1;
                wbuf   <= s_axi_wdata;
                wlastbuf <= s_axi_wlast;   // AXI3:随数据锁存末拍标记
            end
            if (write_fire) begin
                if (awbuf[4]) begin
                    s_axi_bresp <= 2'b10;        // outside aperture → SLVERR
                end else begin
                    s_axi_bresp <= 2'b00;        // OKAY
                    case (awbuf[3:2])            // 全译码:0x08/0x0C 为只读,写入忽略
                        2'b00: reg_ctrl  <= wbuf;    //    偏移 0x00 → CTRL
                        2'b01: reg_speed <= wbuf;    //    偏移 0x04 → SPEED
                        default: ;                   //    0x08/0x0C → RO,忽略
                    endcase
                end
                aw_seen <= 1'b0;
                w_seen  <= 1'b0;
                s_axi_bvalid <= 1'b1;
            end
            if (s_axi_bvalid && s_axi_bready)
                s_axi_bvalid <= 1'b0;
        end
    end

    // ========================================================
    // 读路径(同样的 case 译码;ARREADY 跟复位门控——codex #5:
    // 复位期间若 PS 发读,旧版 ARREADY=1 会吞掉地址却不回数据,PS 挂死)
    // ========================================================
    assign s_axi_arready = aresetn && !s_axi_rvalid;

    always @(posedge aclk) begin
        if (!aresetn) begin
            s_axi_rvalid <= 1'b0;
            s_axi_rdata  <= 32'd0;
            s_axi_rresp  <= 2'b00;
        end else begin
            if (s_axi_arvalid && s_axi_arready) begin
                s_axi_rvalid <= 1'b1;
                if (s_axi_araddr[4]) begin
                    s_axi_rresp <= 2'b10;          // outside aperture → SLVERR
                    s_axi_rdata <= 32'd0;
                end else begin
                    s_axi_rresp <= 2'b00;
                    case ({s_axi_araddr[3], s_axi_araddr[2]})
                        2'b00: s_axi_rdata <= {26'd0, status_in};  // {run_cnt,done,busy}
                        2'b01: s_axi_rdata <= reg_speed;
                        2'b10: s_axi_rdata <= out_rd0;   // 0x08: ResNet 输出[0:1]
                        2'b11: s_axi_rdata <= out_rd1;   // 0x0C: ResNet 输出[2:3]
                    endcase
                end
            end else if (s_axi_rvalid && s_axi_rready) begin
                s_axi_rvalid <= 1'b0;
            end
        end
    end

    assign ctrl  = reg_ctrl;         // 旋钮手柄 ×2
    assign speed = reg_speed;

endmodule
