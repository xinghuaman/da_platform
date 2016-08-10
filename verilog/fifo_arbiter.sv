/*
    FIFO arbiter - uses external DDR SDRAM to implement a vector of byte-wide FIFOs
    SV port (8/3/2016)
    Async FIFOs are included here since this is the endpoint of the memory related interfaces.
    For now, fixed 32 bit sample width.  (Internally, FIFOs are serialized to match memory interface width.)
*/

`timescale 1ns / 1ps

module fifo_arbiter #(
    num_ports = 4,
    mem_width = 32
) (
    ClockReset.client cr_core,
    /*
    //  Vector of FIFOs to arbitrate
    //  TODO: Back off to unbundled syntax if simulation/synthesis don't support it.
    FIFOInterface.in ports_in[num_ports],
    FIFOInterface.out ports_out[num_ports],
    */
    //  TEMPORARY: Vector of individual FIFO signals since array of interfaces is broken.
    output logic ports_in_ready[num_ports],
    input logic ports_in_enable[num_ports],
    input logic [mem_width - 1 : 0] ports_in_data[num_ports],
    input logic ports_out_ready[num_ports],
    output logic ports_out_enable[num_ports],
    output logic [mem_width - 1 : 0] ports_out_data[num_ports],
    
    //  Memory interface
    ClockReset.client cr_mem,
    FIFOInterface.out mem_cmd,
    FIFOInterface.out mem_write,
    FIFOInterface.in mem_read
);

`include "structures.sv"

localparam   STATE_WAITING = 4'h0;
localparam   STATE_READ_INIT = 4'h1;
localparam   STATE_READ_CMD = 4'h2;
localparam	STATE_READ_DATA = 4'h3;
localparam	STATE_WRITE_INIT = 4'h4;
localparam	STATE_WRITE_CMD = 4'h5;
localparam   STATE_WRITE_DATA = 4'h6;

//  How many words (samples) are allocated to FIFO storage for each port?
//  For now, 64k.  This can be increased.
localparam region_log_depth = 16;

//  Log depth of FIFOs (write, read).
localparam M_fw = 6;
localparam N_fw = (1 << M_fw);
localparam M_fr = 6;
localparam N_fr = (1 << M_fr);

logic [3:0] state;

logic [M_fw:0] write_words_target;
logic [M_fw:0] write_words_count;

logic [M_fw:0] read_words_target;
logic [M_fw:0] read_words_count;

logic port_in_active;
logic port_out_active;
logic [$clog2(num_ports) - 1 : 0] current_port_index;

logic [31:0] last_write_addr[num_ports - 1 : 0];
logic [31:0] last_read_addr[num_ports - 1 : 0];

/*
    Just redoing everything in SV interfaces.
    - Each port has its own FIFO in order to keep track of counts within the module.
    - Mux selects active port interface to feed into
    - Async FIFOs handle clock domain crossing from selected port to mem interface
*/

//  Here is the code for the FIFOs placed at each port
FIFOInterface #(.num_bits(mem_width)) ports_in_buf[num_ports] (cr_core.clk);
FIFOInterface #(.num_bits(mem_width)) ports_out_buf[num_ports] (cr_core.clk);

logic [M_fw:0] in_count[num_ports];
logic [M_fr:0] out_count[num_ports];

genvar g;
//  Experimenting to solve problem of ports_in / ports_out not being an array
/*
generate for (g = 0; g < num_ports; g++) begin: io_fifos
    fifo_sync_sv #(.width(mem_width), .depth(N_fw)) write_fifo (
        .cr(cr_core),
        .in(ports_in[g]),
        .out(ports_in_buf[g].out),
        .count(in_count[g])
    );
    fifo_sync_sv #(.width(mem_width), .depth(N_fr)) read_fifo (
        .cr(cr_core),
        .in(ports_out_buf[g].in),
        .out(ports_out[g]),
        .count(out_count[g])
    );
end
endgenerate
*/
/*
fifo_sync_sv #(.width(mem_width), .depth(N_fw)) write_fifos[num_ports] (
    .cr(cr_core),
    .in(ports_in),
    .out(ports_in_buf.out),
    .count(in_count)
);
fifo_sync_sv #(.width(mem_width), .depth(N_fr)) read_fifos[num_ports] (
    .cr(cr_core),
    .in(ports_out_buf.in),
    .out(ports_out),
    .count(out_count)
);
*/
//  RRRR....
FIFOInterface #(.num_bits(mem_width)) ports_in_rep[num_ports] (cr_core.clk);
FIFOInterface #(.num_bits(mem_width)) ports_out_rep[num_ports] (cr_core.clk);
/*
generate for (g = 0; g < num_ports; g++) begin: ports_dup
    assign ports_in[g].ready = ports_in_rep[g].ready;
    assign ports_in_rep[g].enable = ports_in[g].enable;
    assign ports_in_rep[g].data = ports_in[g].data;
    assign ports_out_rep[g].ready = ports_out[g].ready;
    assign ports_out[g].enable = ports_out_rep[g].enable;
    assign ports_out[g].data = ports_out_rep[g].data;
end
endgenerate
*/
generate for (g = 0; g < num_ports; g++) begin: ports_dup
    assign ports_in_ready[g] = ports_in_rep[g].ready;
    assign ports_in_rep[g].enable = ports_in_enable[g];
    assign ports_in_rep[g].data = ports_in_data[g];
    assign ports_out_rep[g].ready = ports_out_ready[g];
    assign ports_out_enable[g] = ports_out_rep[g].enable;
    assign ports_out_data[g] = ports_out_rep[g].data;
    fifo_sync_sv #(.width(mem_width), .depth(N_fw)) write_fifo (
        .cr(cr_core),
        .in(ports_in_rep[g].in),
        .out(ports_in_buf[g].out),
        .count(in_count[g])
    );
    fifo_sync_sv #(.width(mem_width), .depth(N_fr)) read_fifo (
        .cr(cr_core),
        .in(ports_out_buf[g].in),
        .out(ports_out_rep[g].out),
        .count(out_count[g])
    );
end
endgenerate

//  Here is the code for the async FIFOs to/from the memory interface
FIFOInterface #(.num_bits(mem_width)) port_in_sel(cr_core.clk);
FIFOInterface #(.num_bits(mem_width)) port_out_sel(cr_core.clk);

//  Vivado simulator hacks
FIFOInterface #(.num_bits(mem_width)) mem_write_rep(cr_mem.clk);
FIFOInterface #(.num_bits(mem_width)) mem_read_rep(cr_mem.clk);
ClockReset cr_mem_rep ();

always_comb begin
    cr_mem_rep.clk = cr_mem.clk;
    cr_mem_rep.reset = cr_mem.reset;
    mem_write_rep.ready = mem_write.ready;
    mem_write.enable = mem_write_rep.enable;
    mem_write.data = mem_write_rep.data;
    mem_read.ready = mem_read_rep.ready;
    mem_read_rep.enable = mem_read.enable;
    mem_read_rep.data = mem_read.data;
end

logic [4:0] c2m_wr_count;
logic [4:0] c2m_rd_count;
fifo_async_sv2 #(.width(mem_width), .depth(16), .debug_display(1)) main_write_fifo(
    .clk_in(cr_core.clk),
    .reset_in(cr_core.reset),
    .in(port_in_sel.in),
    .count_in(c2m_wr_count),
    .clk_out(cr_mem.clk),
    .reset_out(cr_mem.reset),
    .out(mem_write_rep.out),
    .count_out(c2m_rd_count)
);

logic [4:0] m2c_wr_count;
logic [4:0] m2c_rd_count;
fifo_async_sv2 #(.width(mem_width), .depth(16), .debug_display(1)) main_read_fifo(
    .clk_in(cr_mem.clk),
    .reset_in(cr_mem.reset),
    .in(mem_read_rep.in),
    .count_in(m2c_wr_count),
    .clk_out(cr_core.clk),
    .reset_out(cr_core.reset),
    .out(port_out_sel.out),
    .count_out(m2c_rd_count)
);

//  Here is the code that acts as a FIFO mux.
//  First there are some extra signals defined to work around SystemVerilog interface array limitations.
logic ports_in_buf_ready[num_ports];
logic ports_in_buf_enable[num_ports];
logic [mem_width - 1 : 0] ports_in_buf_data[num_ports];
logic ports_out_buf_ready[num_ports];
logic ports_out_buf_enable[num_ports];
logic [mem_width - 1 : 0] ports_out_buf_data[num_ports];
generate for (g = 0; g < num_ports; g++) always_comb begin
    ports_in_buf[g].ready = ports_in_buf_ready[g];
    ports_in_buf_enable[g] = ports_in_buf[g].enable;
    ports_in_buf_data[g] = ports_in_buf[g].data;
    ports_out_buf_ready[g] = ports_out_buf[g].ready;
    ports_out_buf[g].enable = ports_out_buf_enable[g];
    ports_out_buf[g].data = ports_out_buf_data[g];
end
endgenerate

always_comb begin

    for (int i = 0; i < num_ports; i++) begin
        ports_in_buf_ready[i] = 0;
        port_in_sel.enable = 0;
        port_in_sel.data = 0;
        ports_out_buf_enable[i] = 0;
        ports_out_buf_data[i] = 0;
        port_out_sel.ready = 0;
    end

    if (port_in_active) begin
        ports_in_buf_ready[current_port_index] = port_in_sel.ready;
        port_in_sel.enable = ports_in_buf_enable[current_port_index];
        port_in_sel.data = ports_in_buf_data[current_port_index];
    end

    if (port_out_active) begin
        port_out_sel.ready = ports_out_buf_ready[current_port_index];
        ports_out_buf_enable[current_port_index] = port_out_sel.enable;
        ports_out_buf_data[current_port_index] = port_out_sel.data;
    end

end

//  Here is an async FIFO for mem commands.
MemoryCommand cur_mem_cmd;
FIFOInterface #(.num_bits(65 /* $sizeof(MemoryCommand) */)) mem_cmd_core (cr_core.clk);
logic [2:0] c2m_cmd_wr_count;
logic [2:0] c2m_cmd_rd_count;
fifo_async_sv2 #(.width(65), .depth(4)) main_cmd_fifo(
    .clk_in(cr_core.clk),
    .reset_in(cr_core.reset),
    .in(mem_cmd_core.in),
    .count_in(c2m_cmd_wr_count),
    .clk_out(cr_mem.clk),
    .reset_out(cr_mem.reset),
    .out(mem_cmd),
    .count_out(c2m_cmd_rd_count)
);
always_comb mem_cmd_core.data = cur_mem_cmd;

always @(posedge cr_core.clk) begin
    if (cr_core.reset) begin
        for (int i = 0; i < num_ports; i = i + 1) begin
            last_write_addr[i] <= 0;
            last_read_addr[i] <= 0;
        end
        
        write_words_target <= 0;
        write_words_count <= 0;
        read_words_target <= 0;
        read_words_count <= 0;        

        port_in_active <= 0;
        port_out_active <= 0;
        current_port_index <= 0;
        
        mem_cmd_core.enable <= 0;
        cur_mem_cmd <= 0;
        
        state <= 0;
    end
    else begin
        if (mem_cmd_core.ready) mem_cmd_core.enable <= 0;

        //  Watch data go by and stop when we have target number of words
        if (port_in_sel.enable && port_in_sel.ready) begin
            write_words_count <= write_words_count + 1;
            if (write_words_count == write_words_target - 1)
                port_in_active <= 0;
        end

        case (state)
        STATE_WAITING: begin
            //  Identify next port needing attention
            current_port_index <= current_port_index + 1;
            //	Begin a read when the address is mismatched and there is space in the FIFO
            if (ports_out_buf_ready[current_port_index + 1] && (last_read_addr[current_port_index + 1] != last_write_addr[current_port_index + 1])) begin
                port_out_active <= 1;
                state <= STATE_READ_INIT;
            end
            //  Begin a write when there is data waiting
            else if (in_count[current_port_index + 1] != 0) begin
                port_in_active <= 1;
                //  Count the number of words we are going to write
                write_words_target <= in_count[current_port_index + 1];
                write_words_count <= 0;
                state <= STATE_WRITE_CMD;
            end
        end
        STATE_READ_INIT: begin
            //  Count the number of words we are going to read
            if (last_write_addr[current_port_index] - last_read_addr[current_port_index] > ((1 << M_fr) - out_count[current_port_index]))
                read_words_target <= (1 << M_fr) - out_count[current_port_index];
            else
                read_words_target <= last_write_addr[current_port_index] - last_read_addr[current_port_index];
            read_words_count <= 0;
            state <= STATE_READ_CMD;
        end
        STATE_READ_CMD: begin
            //  Submit command for read
            cur_mem_cmd.length <= read_words_target;
            cur_mem_cmd.address <= last_read_addr[current_port_index] + (current_port_index << region_log_depth);
            cur_mem_cmd.read_not_write <= 1;
            mem_cmd_core.enable <= 1;
            state <= STATE_READ_DATA;
        end
        STATE_READ_DATA: begin
            //  Watch data go by and stop when we have target number of words
            if (port_out_sel.enable && port_out_sel.ready) begin
                read_words_count <= read_words_count + 1;
                if (read_words_count == read_words_target - 1) begin
                    last_read_addr[current_port_index] <= last_read_addr[current_port_index] + read_words_target;
                    port_out_active <= 0;
                    state <= STATE_WAITING;
                end
            end
        end
        STATE_WRITE_INIT: begin
            
        end
        STATE_WRITE_CMD: begin
            //  Submit command for write
            cur_mem_cmd.length <= write_words_target;
            cur_mem_cmd.address <= last_write_addr[current_port_index] + (current_port_index << region_log_depth);
            cur_mem_cmd.read_not_write <= 0;
            mem_cmd_core.enable <= 1;
            last_write_addr[current_port_index] <= last_write_addr[current_port_index] + write_words_target;
            state <= STATE_WRITE_DATA;
        end
        STATE_WRITE_DATA: begin
            //  Transaction is finished.
            if (write_words_target == write_words_count)
                state <= STATE_WAITING;
        end
        endcase
    end
end


endmodule