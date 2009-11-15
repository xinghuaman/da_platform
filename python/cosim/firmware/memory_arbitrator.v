//  Memory arbitrator
//  Controls who reads and writes the off-chip memory.

//  8 write ports:
//  -   4 from EP2, selected by the port number in each data packet
//  -   4 from the audio converter interface bus.
//  8 read ports:
//  -   4 to the audio converter interface bus.
//  -   4 to EP6, read by a data encoder that checks the in/out delta

//  Context:
//  - This module is needed so multiple sources/sinks of data can share 
//  - Each of the ports of this module is connected to an asynchronous FIFO.
//  - The clock frequency of the arbitrator is limited by memory bandwidth.
//    It is set to twice the memory clock here because it reads/writes one
//    byte at a time to/from FIFOs, but the memory bus is 16 bits.

//  Algorithm:
//  Cycles through all write ports then all read ports.
//  For each port, if the in/out delta is greater than 0,
//  - store the in address and the delta D
//  - [write port] Read D bytes from the port FIFO and write them to RAM
//  - [read port] 

module memory_arbitrator(
    //  Connections to write port FIFOs
    write_in_addr[7:0], write_out_addr[7:0], write_read_data[7:0], write_read[7:0],
    //  Connections to read port FIFOs
    read_in_addr[7:0], read_out_addr[7:0], read_write_data[7:0], read_write[7:0],
    //  Connections to other devices
    write_fifo_byte_count[7:0],         //  Byte count on the "in" side of the write FIFOs
    read_fifo_byte_count[7:0],          //  Byte count on the "in" side of the read FIFOs
    //  Connections to memory
    mem_addr, mem_data, mem_oe, mem_we, mem_clk, mem_addr_valid, 
    //  Double the memory clock; synchronous reset
    clk, reset);
    
    input [10:0] write_in_addr[7:0];
    input [10:0] write_out_addr[7:0];
    input [7:0] write_read_data[7:0];
    output reg write_read[7:0];
    
    input [10:0] read_in_addr[7:0];
    input [10:0] read_out_addr[7:0];
    output [7:0] read_write_data[7:0];
    output reg read_write[7:0];
    
    input [31:0] write_fifo_byte_count[7:0];
    output reg [31:0] read_fifo_byte_count[7:0];
    
    input clk;
    input reset;

    //  Internal signals
    reg clk_div2;
    
    //  Concatenated memory buses for read and write
    wire [15:0] mem_write_data;
    reg [7:0] write_lower_byte;
    reg [7:0] write_upper_byte;
    assign mem_write_data = {write_upper_byte, write_lower_byte};
    wire [15:0] mem_read_data;
    wire [7:0] read_lower_byte;
    wire [7:0] read_upper_byte;
    assign read_lower_byte = mem_read_data[7:0];
    assign read_upper_byte = mem_read_data[15:8];

    //  States
    parameter READING = 1'b0;       //  READING cellram into FIFO (destination: EP6 or DAC)
    parameter WRITING = 1'b1;       //  WRITING FIFO into cellram (source: EP2 or ADC)
    parameter NUM_PORTS = 4;
    reg current_direction;          //  READING or WRITING
    reg [2:0] current_port;         //  Port index (0 to 7)
    reg [10:0] current_fifo_addr;
    reg [10:0] current_delta;
    reg start_flag;                 //  Single clk_div2 pulse at beginning of each cycle
    
    //  Internal byte counter for data as it is written to RAM
    reg [31:0] write_mem_byte_count[7:0];
    
    //  Memory definition (elsewhere) looks like this:
    //  cellram = bram_8m_16(.clk(clk_div2), .we(mem_we), .addr(mem_addr), .din(mem_data), .dout(mem_data));
    
    always @(posedge clk) begin
        if (reset) 
            for (i = 0; i < 8; i++) begin
                write_read[i] <= 0;
                read_write_data[i] <= 0;
                read_write[i] <= 0;
                read_fifo_byte_count[i] <= 0;
            end
            current_direction <= READING;
            current_port <= 0;
            current_fifo_addr <= 0;
            current_delta <= 0;
            start_flag <= 1;
            clk_div2 <= 0;
        else begin
            //  Run clk_div2
            clk_div2 <= clk_div2 + 1;
            
            //  Load lower/upper byte
            if (clk_div2 == 0)
                write_lower_byte <= write_read_data[current_port];
            else
                write_upper_byte <= write_read_data[current_port];
            
        end
    end
    
    always @(posedge clk_div2) begin
        //  Advance state if necessary
        if ((current_delta == 0) && (!start_flag)) begin
            //  If the last port was reached, reset to port 0 and switch directions.
            if (current_port == (NUM_PORTS - 1)) begin
                current_port <= 0;
                if (current_direction == READING)
                    current_direction <= WRITING;
                else
                    current_direction <= READING;
            end
            //  Otherwise go to the next port
            else
                current_port <= current_port + 1;
                
            write_read[current_port] <= 0;
            read_write[current_port] <= 0;
            start_flag <= 1;
        end
        //  At beginning of cycle, load parameters and clear start flag
        else if (start_flag) begin
            
            if (current_direction == WRITING) begin
                //  Latch effective byte count at input.
                write_mem_byte_count[current_port] <= write_fifo_byte_count[current_port];
                
                current_fifo_addr <= write_out_addr[current_port];
                current_delta <= write_in_addr[current_port] - write_out_addr[current_port];
            end
            else begin
                current_fifo_addr <= read_in_addr[current_port];
                
                //  Compute delta from byte count lag between read side and write site.
                current_delta <= write_mem_byte_count[current_port] - read_fifo_byte_count[current_port];
            end
        
            write_read[current_port] <= 0;
            read_write[current_port] <= 0;
            start_flag <= 0;
        end
        //  Once cycle is under way, perform read or write task
        else

            if (current_direction == READING) begin
                read_write[current_port] <= 1;
                write_read[current_port] <= 0;
            end

            else begin
                read_write[current_port] <= 0;
                write_read[current_port] <= 1;
                //  Update counters
                current_fifo_addr <= current_fifo_addr + 1;
                current_delta <= current_delta - 1;
            end
        end
        
    end

endmodule
