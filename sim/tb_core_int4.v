// ============================================================
// tb_core_int4.v — testbench for resnet_top_int4
// ============================================================
// Pulses start, waits for done (with timeout), then compares the
// 4 outputs against sim/hex_int4/golden_output.hex (Python golden
// model). Also reports cycle count start→done for the speed story.
// ============================================================
`timescale 1ns/1ps
module tb_core_int4;

    reg aclk = 0;
    reg aresetn = 0;
    reg start = 0;
    wire done, busy;
    wire signed [15:0] o0, o1, o2, o3;

    resnet_top_int4 dut (
        .aclk(aclk), .aresetn(aresetn), .start(start),
        .done(done), .busy(busy),
        .out0(o0), .out1(o1), .out2(o2), .out3(o3)
    );

    always #5 aclk = ~aclk;  // 100 MHz

    reg [15:0] golden [0:3];
    integer i;
    integer cycles = 0;
    integer to = 0;
    reg finished = 0;
    integer errors = 0;
    integer st_count [0:7];

    initial begin
        $readmemh("/home/percy/works/resnet-on-fpga/sim/hex_int4/golden_output.hex", golden);
        for (i = 0; i < 8; i = i + 1) st_count[i] = 0;
        forever @(posedge aclk) st_count[dut.state] = st_count[dut.state] + 1;
    end

    initial begin

        repeat (10) @(posedge aclk);
        aresetn = 1;
        @(posedge aclk);

        // start pulse (1 cycle)
        start <= 1;
        @(posedge aclk);
        start <= 0;

        // wait done with timeout (iverilog has no break — use flag)
        to = 0; finished = 0; cycles = 0;
        while (!finished && to < 100000) begin
            @(posedge aclk);
            cycles = cycles + 1;
            if (done) finished = 1;
            to = to + 1;
        end

        if (!finished) begin
            $display("TIMEOUT after 100000 cycles! state stuck.");
            $finish;
        end

        // state histogram (0=IDLE 1=LOAD 2=CONV 3=POOL 4=FC 5=DONE)
        $display("States: IDLE=%0d LOAD=%0d CONV=%0d POOL=%0d FC=%0d DONE=%0d",
                 st_count[0], st_count[1], st_count[2], st_count[3], st_count[4], st_count[5]);

        // compare (16-bit two's complement, golden stored as &0xFFFF)
        if (o0 !== golden[0]) begin errors = errors + 1; $display("MISMATCH out0: dut=%0d golden=%0d", $signed(o0), $signed(golden[0])); end
        if (o1 !== golden[1]) begin errors = errors + 1; $display("MISMATCH out1: dut=%0d golden=%0d", $signed(o1), $signed(golden[1])); end
        if (o2 !== golden[2]) begin errors = errors + 1; $display("MISMATCH out2: dut=%0d golden=%0d", $signed(o2), $signed(golden[2])); end
        if (o3 !== golden[3]) begin errors = errors + 1; $display("MISMATCH out3: dut=%0d golden=%0d", $signed(o3), $signed(golden[3])); end

        if (errors == 0)
            $display("PASS: outputs [%0d, %0d, %0d, %0d] match golden after %0d cycles",
                     $signed(o0), $signed(o1), $signed(o2), $signed(o3), cycles);
        else
            $display("FAIL: %0d mismatched outputs", errors);
        $finish;
    end

endmodule
