/*  FX2 interface

Contains glue logic that connects the FX2 USB processor to:
-   Endpoint 2: write ports of tracking FIFOs to DAC buffer
-   Endpoint 4: command decoder
-   Endpoint 6: read ports of tracking FIFOs to ADC buffer
-   Endpoint 8: status/command generator

All inputs are active high.

*/

module fx2_interface(
    //  USB interface
    usb_ifclk, usb_slwr, usb_slrd, usb_sloe, usb_addr, usb_data_in, usb_data_out, usb_ep2_empty, usb_ep4_empty, usb_ep6_full, usb_ep8_full,
    //  Endpoint ports
    ep2_port_data, ep2_port_write, ep2_port_clk, ep6_port_addr_ins, ep6_port_addr_outs, ep6_port_datas, ep6_port_read, ep6_port_clk,
    //  Connection to configuration RAM
    config_addr, config_write, config_clk, config_data,
    //  Connection to command encoder
    cmd_new_command, cmd_data, cmd_clk, cmd_read,
    //  Control
    reset, clk);
    
    /*  In/out declarations  */
    
    //  USB interface
    input usb_ifclk;
    output reg usb_slwr;            //  Active low
    output reg usb_slrd;            //  Active low
    output usb_sloe;            //  Active low
    output [1:0] usb_addr;
    output reg [7:0] usb_data_in;
    input [7:0] usb_data_out;
    input usb_ep2_empty;
    input usb_ep4_empty;
    input usb_ep6_full;
    input usb_ep8_full;
    
    //  Endpoint ports to/from tracking FIFOs
    //  They share data and clock, but only one is being read or written at any given time
    output [7:0] ep2_port_data;
    output [3:0] ep2_port_write;
    output ep2_port_clk;
    input [43:0] ep6_port_addr_ins;          //  EP6 tracking FIFO has address lines so FX2 interface knows when to start and stop reading
    input [43:0] ep6_port_addr_outs;
    input [31:0] ep6_port_datas;
    output [3:0] ep6_port_read;
    output ep6_port_clk;
    
    //  Connection to configuration RAM
    output [10:0] config_addr;
    output config_write;
    output config_clk;
    output [7:0] config_data;
    
    //  Connection to command encoder
    input cmd_new_command;
    input [7:0] cmd_data;
    output cmd_clk;
    output cmd_read;
    
    input clk;
    input reset;


    /*  State machine parameters   */
    
    //  USB endpoint index (state_endpoint_index)
    parameter [1:0] EP2 = 2'b00;
    parameter [1:0] EP4 = 2'b01;
    parameter [1:0] EP6 = 2'b10;
    parameter [1:0] EP8 = 2'b11;
    
    //  USB packet status (state_packet_status)
    parameter [2:0] PACKET_WAITING = 3'b000;
    parameter [2:0] PACKET_HEADER_COMMAND = 3'b001;
    parameter [2:0] PACKET_HEADER_LENGTH_UPPER = 3'b010;
    parameter [2:0] PACKET_HEADER_LENGTH_LOWER = 3'b011;
    parameter [2:0] PACKET_DATA = 3'b100;
    parameter [2:0] PACKET_DONE = 3'b101;

    //  Header byte
    parameter [7:0] HEADER_BYTE = 8'hFF;
    parameter [7:0] UNSET_BYTE = 8'h76;
    
    //  Command stuff
    parameter [7:0] COMMAND_NOP = 8'h38;


    /*  Internal signals  */
    integer i;
    genvar g;
    
    //  Global 
    reg [1:0] state_endpoint_index;         //  The index of the current tracking FIFO
    reg [2:0] state_packet_status [1:0];    //  The status of the packet being read or written at the endpoint index
    
    //  State for when a data packet is coming in from EP2:
    reg [1:0] ep2_port_index;           //  The port selected
    reg [15:0] ep2_data_length;         //  The amount of data to write to a tracking FIFO
    
    //  State for when a command packet is coming in from EP4:
    reg [7:0] ep4_command_index;        //  The command selected.
    reg [15:0] ep4_command_length;         //  The amount of data to write to a tracking FIFO
    
    //  State for when a data packet is going out via EP6:
    reg [1:0] ep6_port_index;           //  The index of the current tracking FIFO
    reg [10:0] ep6_destination_length;  //  The number of bytes to read from the tracking FIFO
    reg [10:0] ep6_destination_byte;    //  The target end address for the tracking FIFO
    
    //  State for when a command packet is going out via EP8:
    //  To do: make this work
    
    //  Whether this is a read or write operation (from/to the FX2).
    wire state_read;
    wire state_write;
    
    //  Whether this is a data or command operation
    wire state_data;
    wire state_command;
    
    //  Whether EP6 ports should be used.
    wire state_ep6_active [3:0];
    
    //  Break out signal lists
    wire [7:0] ep6_port_data [3:0];
    wire [10:0] ep6_port_addr_in [3:0];
    wire [10:0] ep6_port_addr_out [3:0];
    generate for (g = 0; g < 4; g = g + 1) begin
        assign ep6_port_data[g] = ep6_port_datas[((g + 1) * 8 - 1):(g * 8)];
        assign ep6_port_addr_in[g] = ep6_port_addr_ins[((g + 1) * 11 - 1):(g * 11)];
        assign ep6_port_addr_out[g] = ep6_port_addr_outs[((g + 1) * 11 - 1):(g * 11)];       
        end
    endgenerate
    
    /*  Logic processes */
    
    //  Assign read/write flags
    assign state_read = ((state_endpoint_index == EP2) || (state_endpoint_index == EP4));
    assign state_write = ((state_endpoint_index == EP6) || (state_endpoint_index == EP8));
    assign state_data = ((state_endpoint_index == EP2) || (state_endpoint_index == EP6));
    assign state_command = ((state_endpoint_index == EP4) || (state_endpoint_index == EP8));
    generate for (g = 0; g < 4; g = g + 1) begin
        assign state_ep6_active[g] = (ep6_port_addr_out[g] != ep6_port_addr_in[g]);
        end
    endgenerate
    
    //  Tell the FX2 to always drive its outputs
    assign usb_sloe = 0;
    
    //  Use the currently selected endpoint
    assign usb_addr = state_endpoint_index;
    
    always @(posedge clk) begin
        if (reset) begin
            //  Handle a reset by switching to the beginning state.
            state_endpoint_index <= EP2;
            for (i = 0; i < 4; i = i + 1)
                state_packet_status[i] <= PACKET_WAITING;
                
            ep2_port_index <= 0;
            ep2_data_length <= 0;
            ep4_command_index <= COMMAND_NOP;
            ep4_command_length <= 0;
            ep6_destination_byte <= 0;
            ep6_destination_length <= 0;
            ep6_port_index <= 0;
        end
        else begin
            //  To do: these conditions will need to be made more specific to avoid data corruption.
            //  Read if EP2 or EP4 is selected and the endpoint is not empty.
            usb_slrd <= ~(state_read && ~((state_endpoint_index == EP2) ? usb_ep2_empty : usb_ep4_empty));
            //  Write if EP6 or EP8 is selected and the endpoint is not full.
            usb_slwr <= ~(state_write && ~((state_endpoint_index == EP6) ? usb_ep6_full : usb_ep8_full) && state_ep6_active[ep6_port_index]);
            
            //  Main state machine
            case (state_packet_status[state_endpoint_index])
                //  If waiting, wait for a header byte and, once it is received, move on to the header state. 
                PACKET_WAITING: begin
                    case (state_endpoint_index)
                        EP2, 
                        EP4: begin
                            if (~usb_slrd && (usb_data_out == HEADER_BYTE))
                                //  If a packet starts arriving, move on to reading the header.
                                state_packet_status[state_endpoint_index] <= PACKET_HEADER_COMMAND;
                            else 
                                //  Otherwise, go on to service the next endpoint.
                                state_packet_status[state_endpoint_index] <= PACKET_DONE;
                        end
                        EP6: begin
                            if (state_ep6_active[ep6_port_index]) begin
                                //  If the tracking FIFO for the current port has data, write a header byte and move on.
                                usb_data_in <= HEADER_BYTE;
                                state_packet_status[state_endpoint_index] <= PACKET_HEADER_COMMAND;
                            end
                            else
                                //  Otherwise, call it a day and move on to the next endpoint.
                                state_packet_status[state_endpoint_index] <= PACKET_DONE;
                        end
                        EP8: begin
                            //  We are servicing EP8; this is currently not defined.  So, just move on to the next endpoint.
                            state_packet_status[state_endpoint_index] <= PACKET_DONE;
                        end
                    endcase
                end
                
                //  If the header is coming in or going, store the data in the appropriate location.
                //  While dealing with a packet, you can abandon an endpoint temporarily by switching the state_endpoint_index
                //  and leaving the state_packet_status for the current state_endpoint_index intact.
                PACKET_HEADER_COMMAND: begin
                    case (state_endpoint_index)
                        EP2: begin
                            if (~usb_slrd) begin
                                ep2_port_index <= usb_data_out;
                                state_packet_status[state_endpoint_index] <= PACKET_HEADER_LENGTH_UPPER;
                            end
                            else
                                state_endpoint_index <= state_endpoint_index + 1;
                        end
                        EP4: begin
                            if (~usb_slrd) begin
                                ep4_command_index <= usb_data_out;
                                state_packet_status[state_endpoint_index] <= PACKET_HEADER_LENGTH_UPPER;
                            end
                            else
                                state_endpoint_index <= state_endpoint_index + 1;
                        end
                        EP6: begin
                            //  At this point we need to set a target address to read up to in the appropriate tracking FIFO.
                            //  Because the amount of data to be written is known, we do not allow abandoning the endpoint until the packet is done.
                            usb_slwr <= 0;
                            usb_data_in <= ep6_port_index;
                            ep6_destination_byte <= ep6_port_addr_in[ep6_port_index];
                            ep6_destination_length <= ep6_port_addr_in[ep6_port_index] - ep6_port_addr_out[ep6_port_index];
                            state_packet_status[state_endpoint_index] <= PACKET_HEADER_LENGTH_UPPER;
                        end
                        EP8: begin
                            //  Commands to computer not yet supported
                            state_packet_status[state_endpoint_index] <= PACKET_DONE;
                        end
                    endcase
                end
                PACKET_HEADER_LENGTH_UPPER: begin
                    case (state_endpoint_index)
                        EP2: begin
                            //  Save the upper byte of the packet data length if it has arrived, otherwise abandon the endpoint.
                            if (~usb_slrd) begin
                                ep2_data_length[15:8] <= usb_data_out;
                                state_packet_status[state_endpoint_index] <= PACKET_HEADER_LENGTH_LOWER;
                            end
                            else
                                state_endpoint_index <= state_endpoint_index + 1;
                        end
                        EP4: begin
                            //  Save the upper byte of the packet command length if it has arrived, otherwise abandon the endpoint.
                            if (~usb_slrd) begin
                                ep4_command_length[15:8] <= usb_data_out;
                                state_packet_status[state_endpoint_index] <= PACKET_HEADER_LENGTH_LOWER;
                            end
                            else
                                state_endpoint_index <= state_endpoint_index + 1;
                        end
                        EP6: begin
                            //  Write the upper byte of the packet data length and move on.
                            usb_slwr <= 0;
                            usb_data_in <= ep6_destination_length[15:8];
                            state_packet_status[state_endpoint_index] <= PACKET_HEADER_LENGTH_LOWER;
                        end
                        EP8: begin
                            //  Commands to computer not yet supported
                            state_packet_status[state_endpoint_index] <= PACKET_DONE;
                        end
                    endcase
                end
                PACKET_HEADER_LENGTH_LOWER: begin
                    case (state_endpoint_index)
                        EP2: begin
                            //  Save the lower byte of the packet data length if it has arrived; abandon the endpoint otherwise.
                            if (~usb_slrd) begin
                                ep2_data_length[7:0] <= usb_data_out;
                                state_packet_status[state_endpoint_index] <= PACKET_DATA;
                            end
                            else
                                state_endpoint_index <= state_endpoint_index + 1;
                        end
                        EP4: begin
                            //  Save the lower byte of the packet command length if it has arrived; abandon the endpoint otherwise.
                            if (~usb_slrd) begin
                                ep4_command_length[7:0] <= usb_data_out;
                                state_packet_status[state_endpoint_index] <= PACKET_DATA;
                            end
                            else
                                state_endpoint_index <= state_endpoint_index + 1;
                        end
                        EP6: begin
                            //  Write the lower byte of the packet data length and start on data.
                            usb_slwr <= 0;
                            usb_data_in <= ep6_destination_length[7:0];
                            state_packet_status[state_endpoint_index] <= PACKET_DATA;
                        end
                        EP8: begin
                            //  Commands to computer not yet supported
                            state_packet_status[state_endpoint_index] <= PACKET_DONE;
                        end
                    endcase
                end
                
                //  If data is currently being read/written, move it to the appropriate destination buffer
                //  while keeping count of the number of bytes against the total for this packet.  The endpoint may be abandoned.
                PACKET_DATA: begin
                    case (state_endpoint_index)
                        EP2: begin
                        
                        end
                        EP4: begin
                        
                        end
                        EP6: begin
                        
                        end
                        EP8: begin
                            //  Commands to computer not yet supported
                            state_packet_status[state_endpoint_index] <= PACKET_DONE;
                        end
                    endcase
                end
                
                //  If the current packet is done, move to the next endpoint
                PACKET_DONE: begin
                    state_packet_status[state_endpoint_index] <= PACKET_WAITING;
                    case (state_endpoint_index)
                        EP2: state_endpoint_index <= EP4;
                        EP4: state_endpoint_index <= EP6;
                        EP6: state_endpoint_index <= EP8;
                        EP8: state_endpoint_index <= EP2;
                    endcase
                end
            endcase
            
        end
    end

endmodule

