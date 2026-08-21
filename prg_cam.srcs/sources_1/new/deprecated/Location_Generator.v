`timescale 1ns / 1ps
// DEPRECATED (2026-07 FIFO/SRAM refactor): unrelated SPI metadata prototype;
// it is not part of the active camera-to-packet path.
`ifdef ENABLE_DEPRECATED_LOCATION_PATH
// 注释导读：这是旧 SPI 位流转 byte 的实验模块，不属于相机包链。
// spi_pulse 是经 Alarmer 同步后的 SPI 上升沿；temp_data 是 8-bit 移位寄存器；
// ptr 标记当前接收的 bit 位置；ready/loc_valid 只在第 8 bit 到达时保持一拍。
//////////////////////////////////////////////////////////////////////////////////
// Company: 
// Engineer: 
// 
// Create Date: 2026/06/18 14:05:15
// Design Name: 
// Module Name: Location_Generator
// Project Name: 
// Target Devices: 
// Tool Versions: 
// Description: 
// 
// Dependencies: 
// 
// Revision:
// Revision 0.01 - File Created
// Additional Comments:
// 
//////////////////////////////////////////////////////////////////////////////////


module Location_Generator(
    // clk=系统处理时钟；spi_clk=异步串行时钟；rst=高有效异步复位。
    input            clk, spi_clk, rst,
    // data_stream 是 spi_clk 边沿上的串行 bit；loc_valid 在组满 byte 后一拍有效。
    input            data_stream,
    output wire[7:0] loc_data,
    output wire      loc_valid
    );

    localparam MODULE_DEPRECATED = 1'b1;
    
    reg [7:0] temp_data; // 左移输入缓存，最新 bit 进入 bit0
    reg [2:0] ptr;       // 3-bit 自然回卷计数器：0..7
    reg       ready;     // 输出事件寄存器，每拍默认清零
    assign loc_data  = temp_data;
    assign loc_valid = ready;

    // spi_clk is a FOREIGN serial clock, not a data enable. Sample it into the
    // system clk domain and turn each rising edge into a 1-clk strobe, exactly
    // like Pixel_Generator does for cam_clk. This removes the clock-as-data hazard.
    wire spi_pulse;
    Alarmer alarmer_loc (
        .clk_data (spi_clk),
        .clk      (clk),
        .rst      (rst),
        .alarm    (spi_pulse)
    );

    always @(posedge clk or posedge rst) begin
        if (rst) begin
            temp_data <= 8'd0;   // reset was in the sensitivity list but never used
            ptr       <= 3'd0;
            ready     <= 1'b0;
        end else begin
            // valid 为 pulse 而不是 level；消费者必须在该拍采样 loc_data。
            ready <= 1'b0;
            if (spi_pulse) begin
                // BUGFIX: old code {temp_data[7:1], data_stream} only wrote bit0 and
                // never shifted. Proper MSB-first serial shift-in:
                temp_data <= {temp_data[6:0], data_stream};
                if (ptr == 3'd7) ready <= 1'b1; // full byte assembled this strobe
                ptr <= ptr + 1'b1;
            end
        end
    end
endmodule
`endif
