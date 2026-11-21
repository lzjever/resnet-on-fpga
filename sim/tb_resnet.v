// ============================================================
// tb_resnet.v — Testbench for resnet_top
// ============================================================
// Loads input from hex file, triggers computation, polls done,
// then compares output against golden reference.
// ============================================================
`timescale 1ns / 1ps

module tb_resnet;
    // Clock & reset
    reg aclk = 0;
    reg aresetn = 0;
    always #10 aclk = ~aclk;  // 50MHz

    // AXI signals (reg = driven by TB, wire = driven by DUT)
    reg  [31:0] awaddr;
    reg         awvalid;
    wire        awready;
    reg  [31:0] wdata;
    reg  [31:0] wstrb;
    reg         wvalid;
    wire        wready;
    wire        bvalid;
    reg         bready;
    wire [1:0]  bresp;
    reg  [31:0] araddr;
    reg         arvalid;
    wire        arready;
    wire [31:0] rdata;
    wire        rvalid;
    reg         rready;
    wire [1:0]  rresp;

    // Instantiate DUT
    resnet_top dut (
        .aclk(aclk), .aresetn(aresetn),
        .s_axi_awaddr(awaddr), .s_axi_awvalid(awvalid), .s_axi_awready(awready),
        .s_axi_wdata(wdata), .s_axi_wstrb(wstrb), .s_axi_wvalid(wvalid), .s_axi_wready(wready),
        .s_axi_bvalid(bvalid), .s_axi_bready(bready), .s_axi_bresp(bresp),
        .s_axi_araddr(araddr), .s_axi_arvalid(arvalid), .s_axi_arready(arready),
        .s_axi_rdata(rdata), .s_axi_rvalid(rvalid), .s_axi_rready(rready), .s_axi_rresp(rresp)
    );

    // Golden output (from Python)
    reg signed [15:0] golden [0:3];
    initial $readmemh("sim/hex/golden_output.hex", golden);

    integer i;
    integer errors;
    reg [31:0] read_val;
    reg [31:0] poll_val;
    integer poll_count;

    // AXI write task
    task axi_write(input [31:0] addr, input [31:0] data);
    begin
        @(posedge aclk);
        awaddr <= addr; awvalid <= 1;
        wdata  <= data; wstrb <= 32'hFFFFFFFF; wvalid <= 1;
        @(posedge aclk);
        while (!awready || !wready) @(posedge aclk);
        awvalid <= 0; wvalid <= 0;
        bready <= 1;
        @(posedge aclk);
        while (!bvalid) @(posedge aclk);
        @(posedge aclk);
        bready <= 0;
    end
    endtask

    // AXI read task
    task axi_read(input [31:0] addr, output [31:0] data);
    begin
        @(posedge aclk);
        araddr <= addr; arvalid <= 1;
        @(posedge aclk);
        while (!arready) @(posedge aclk);
        arvalid <= 0;
        rready <= 1;
        @(posedge aclk);
        while (!rvalid) @(posedge aclk);
        data = rdata;
        @(posedge aclk);
        rready <= 0;
    end
    endtask

    // Input data (2 halves per 32-bit word)
    reg [15:0] input_data [0:767];
    initial $readmemh("sim/hex/input.hex", input_data);

    initial begin
        $display("=== ResNet Testbench Start ===");
        errors = 0;

        // Reset
        aresetn = 0;
        repeat(10) @(posedge aclk);
        aresetn = 1;
        repeat(5) @(posedge aclk);

        // Write input data (768 16-bit values = 384 32-bit words)
        $display("Writing input data...");
        for (i = 0; i < 384; i = i + 1) begin
            axi_write(32'h10 + i * 4, {input_data[i*2+1], input_data[i*2]});
        end
        $display("Input written (%0d words)", 384);

        // Start computation
        $display("Starting computation...");
        axi_write(32'h00, 32'h1);  // CTRL = start

        // Poll done
        poll_count = 0;
        while (poll_count < 1000000) begin
            axi_read(32'h00, poll_val);
            poll_count = poll_count + 1;
            if (poll_val[0]) poll_count = 1000001; // force exit
        end
        if (poll_count == 1000000) begin
            $display("ERROR: Timeout waiting for done");
            $finish;
        end
        $display("Done after %0d polls", poll_count);

        // Read output
        $display("Reading output...");
        axi_read(32'h20, read_val);
        $display("  out[0]=%0d out[1]=%0d", $signed(read_val[15:0]), $signed(read_val[31:16]));
        axi_read(32'h24, read_val);
        $display("  out[2]=%0d out[3]=%0d", $signed(read_val[15:0]), $signed(read_val[31:16]));

        // Compare with golden
        $display("\n=== Verification ===");
        $display("Golden: [%0d, %0d, %0d, %0d]",
                 golden[0], golden[1], golden[2], golden[3]);

        // Re-read for comparison
        axi_read(32'h20, read_val);
        if ($signed(read_val[15:0]) !== golden[0]) begin
            $display("MISMATCH out[0]: got=%0d exp=%0d", $signed(read_val[15:0]), golden[0]);
            errors = errors + 1;
        end
        if ($signed(read_val[31:16]) !== golden[1]) begin
            $display("MISMATCH out[1]: got=%0d exp=%0d", $signed(read_val[31:16]), golden[1]);
            errors = errors + 1;
        end
        axi_read(32'h24, read_val);
        if ($signed(read_val[15:0]) !== golden[2]) begin
            $display("MISMATCH out[2]: got=%0d exp=%0d", $signed(read_val[15:0]), golden[2]);
            errors = errors + 1;
        end
        if ($signed(read_val[31:16]) !== golden[3]) begin
            $display("MISMATCH out[3]: got=%0d exp=%0d", $signed(read_val[31:16]), golden[3]);
            errors = errors + 1;
        end

        if (errors == 0)
            $display("=== ALL PASS ===");
        else
            $display("=== %0d ERRORS ===", errors);

        $finish;
    end

endmodule
