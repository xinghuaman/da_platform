/*
    Open-source digital audio platform
    Copyright (C) 2009--2018 Michael Price

    clk_divider: Fixed integer clock divider.

    Warning: Use and distribution of this code is restricted.
    This HDL file is distributed under the terms of the Solderpad Hardware 
    License, Version 0.51.  Other files in this project may be subject to
    different licenses.  Please see the LICENSE file in the top level project
    directory for more information.
*/

`timescale 1ns / 1ps

module clk_divider #(
    parameter int ratio = 3,
    parameter int B = 16,
    parameter int threshold = ratio / 2
) (
    input reset, 
    input clkin,
    output logic clkout
);

logic [B-1:0] counter;

initial begin
    counter <= 0;
    clkout <= 0;
end

always @(posedge clkin) begin
	if (reset) begin
		counter <= 0;
		clkout <= 0;
	end
	else begin
		if (counter < ratio - 1)
			counter <= counter + 1;
		else
			counter <= 0;
			
		if (counter < threshold)
			clkout <= 1;
		else
			clkout <= 0;
	end
end

endmodule

