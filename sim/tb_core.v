// Minimal testbench: directly drive start/done, verify compute logic
// (bypasses AXI to isolate computation from interface)
`timescale 1ns / 1ps

module tb_core;
    reg aclk = 0;
    reg aresetn = 0;

    always #10 aclk = ~aclk;

    resnet_top dut (
        .aclk(aclk), .aresetn(aresetn),
        .s_axi_awaddr(32'd0), .s_axi_awvalid(1'b0), .s_axi_awready(),
        .s_axi_wdata(32'd0), .s_axi_wstrb(32'd0), .s_axi_wvalid(1'b0), .s_axi_wready(),
        .s_axi_bvalid(), .s_axi_bready(1'b1), .s_axi_bresp(),
        .s_axi_araddr(32'd0), .s_axi_arvalid(1'b0), .s_axi_arready(),
        .s_axi_rdata(), .s_axi_rvalid(), .s_axi_rready(1'b1), .s_axi_rresp()
    );

    // Golden output
    reg signed [15:0] golden [0:3];
    initial $readmemh("sim/hex/golden_output.hex", golden);

    integer errors;
    integer cycles;

    initial begin
        $display("=== Core Compute Testbench ===");
        $display("Golden: [%0d, %0d, %0d, %0d]", golden[0], golden[1], golden[2], golden[3]);
        errors = 0;
        cycles = 0;

        // Reset
        aresetn = 0;
        repeat(20) @(posedge aclk);
        aresetn = 1;
        repeat(10) @(posedge aclk);

        // Pulse start (set on negedge to avoid race with posedge sampling)
        $display("Pulsing start...");
        @(negedge aclk);
        dut.start = 1;
        @(posedge aclk);
        @(negedge aclk);
        dut.start = 0;
        $display("Start pulsed, state=%0d", dut.state);

        // Wait for done
        while (!dut.done && cycles < 200000) begin
            @(posedge aclk);
            cycles = cycles + 1;
        end

        if (cycles >= 200000) begin
            $display("ERROR: Timeout after %0d cycles. state=%0d", cycles, dut.state);
            $finish;
        end

        $display("Done after %0d cycles", cycles);

        // Check output
        $display("Got:    [%0d, %0d, %0d, %0d]",
                 dut.out_mem[0], dut.out_mem[1], dut.out_mem[2], dut.out_mem[3]);

        if (dut.out_mem[0] !== golden[0]) begin $display("MISMATCH[0]: %0d vs %0d", dut.out_mem[0], golden[0]); errors = errors + 1; end
        if (dut.out_mem[1] !== golden[1]) begin $display("MISMATCH[1]: %0d vs %0d", dut.out_mem[1], golden[1]); errors = errors + 1; end
        if (dut.out_mem[2] !== golden[2]) begin $display("MISMATCH[2]: %0d vs %0d", dut.out_mem[2], golden[2]); errors = errors + 1; end
        if (dut.out_mem[3] !== golden[3]) begin $display("MISMATCH[3]: %0d vs %0d", dut.out_mem[3], golden[3]); errors = errors + 1; end

        if (errors == 0) $display("=== ALL PASS ===");
        else $display("=== %0d ERRORS ===", errors);
        $finish;
    end
endmodule
