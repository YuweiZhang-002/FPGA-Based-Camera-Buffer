`timescale 1ns / 1ps

module tb_Arbitration;
    reg        sys_clk = 1'b0;
    reg        rst = 1'b1;
    reg  [3:0] request = 4'd0;
    reg        released = 1'b0;
    wire [3:0] grant_onehot;
    integer    errors = 0;

    always #5 sys_clk = ~sys_clk;

    Arbitration dut (
        .sys_clk      (sys_clk),
        .rst          (rst),
        .request      (request),
        .released     (released),
        .grant_onehot (grant_onehot)
    );

    task automatic expect_grant(input [3:0] expected);
        begin
            @(posedge sys_clk); #1;
            if (grant_onehot !== expected) begin
                $display("ERROR grant=%b expected=%b", grant_onehot, expected);
                errors = errors + 1;
            end
        end
    endtask

    task automatic release_current;
        begin
            @(negedge sys_clk);
            released = 1'b1;
            @(posedge sys_clk); #1;
            if (grant_onehot !== 4'b0000) begin
                $display("ERROR grant was not cleared on release: %b",
                         grant_onehot);
                errors = errors + 1;
            end
            @(negedge sys_clk);
            released = 1'b0;
        end
    endtask

    initial begin
        repeat (3) @(posedge sys_clk);
        @(negedge sys_clk);
        rst     = 1'b0;
        request = 4'b1111;

        expect_grant(4'b0001);
        release_current();
        expect_grant(4'b0010);

        // Request changes cannot disturb an active full-packet grant.
        @(negedge sys_clk);
        request = 4'b1000;
        expect_grant(4'b0010);
        expect_grant(4'b0010);
        @(negedge sys_clk);
        request = 4'b1111;

        release_current();
        expect_grant(4'b0100);
        release_current();
        expect_grant(4'b1000);
        release_current();
        expect_grant(4'b0001);

        if (errors == 0)
            $display("PASS: lightweight four-camera packet arbitration");
        else
            $display("FAIL: %0d errors", errors);
        $finish;
    end
endmodule
