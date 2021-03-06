/*
    Open-source digital audio platform
    Copyright (C) 2009--2018 Michael Price

    da_platform: Top level HDL module with generic interfaces.
    Instantiates a slot_controller for each of 4 modules, as well as a
    fifo_arbiter to buffer audio samples in both directions.  Please consult 
    the documentation for a detailed description of the architecture.

    Warning: Use and distribution of this code is restricted.
    This HDL file is distributed under the terms of the Solderpad Hardware 
    License, Version 0.51.  Other files in this project may be subject to
    different licenses.  Please see the LICENSE file in the top level project
    directory for more information.
*/

`timescale 1ns / 1ps

module da_platform #(
    //  Note: mem_width is word width for the interface to the memory controller,
    //  which can be less than that of the physical memory.  The memory controller handles concatenation.
    //  The mem_width is the maximum number of bits per sample, since one sample is stored in each word.
    //  (As of 8/3/2016 the memory controller is yet to be implemented...)
    host_width = 16,
    mem_width = 32,
    sclk_ratio = 16,
    num_slots = 4
) (
    input reset,
    
    //  Generic memory interface
    input clk_mem,
    FIFOInterface.out mem_cmd,
    FIFOInterface.out mem_write,
    FIFOInterface.in mem_read,
    
    //  Generic host interface
    input clk_host,
    FIFOInterface.in host_in,
    FIFOInterface.out host_out,
    
    //  Interface to isolator board
    IsolatorInterface.fpga iso,
    
    //  Other
    output [3:0] led_debug
);

`include "commands.vh"

//  Internal FIFO log depth
localparam M = 10;

genvar g;

//  Core clock domain - for now, just attached to host
logic clk_core;
always_comb begin
    clk_core = clk_host;
end

//  Drive isolator reset line
//  8/10/2016: DSD1792 reset is active low.
logic reset_local;
logic reset_local_hold;
logic [7:0] reset_local_counter;
localparam reset_local_timeout_cycles = 200;
always_comb begin
    iso.reset_n = !(reset || reset_local);
end

//  SCLK generation, along with a reset synchronized to it
reg sclk_en;
reg sclk_en_latched;
(* keep = "true" *) wire sclk_ungated;
wire sclk_last;
reg reset_sclk;

always_latch if (!sclk_ungated) sclk_en_latched <= sclk_en;
always_comb iso.sclk = sclk_ungated && sclk_en_latched;

clk_divider #(.ratio(sclk_ratio)) mclkdiv(reset, clk_core, sclk_ungated);
delay sclk_delay(clk_core, reset, sclk_ungated, sclk_last);

always @(posedge clk_core) begin
    if (reset)
        reset_sclk <= 1;
    else if (!sclk_ungated && sclk_last)
        reset_sclk <= 0;
end

//  SRCLK/SRCLK2 generation - for serializers
(* keep = "true" *) logic srclk_sync;
logic srclk2_sync;
logic srclk2_fpga_launch;
logic srclk2_fpga_capture;

logic [5:0] cycle_count;
always_ff @(posedge sclk_ungated)   
    if (reset_sclk) cycle_count <= 0;
    else cycle_count <= cycle_count + 1;

logic srclk_en;
logic srclk2_modules_en;
logic srclk2_fpga_launch_en;
logic srclk2_fpga_capture_en;
always_latch if (!sclk_ungated) srclk_en = (!reset_sclk && (cycle_count % 8 == 0));
always_latch if (!sclk_ungated) srclk2_fpga_launch_en = (!reset_sclk && (cycle_count % 64 == 1));
always_latch if (!sclk_ungated) srclk2_modules_en = (!reset_sclk && (cycle_count % 64 == 17));
always_latch if (!sclk_ungated) srclk2_fpga_capture_en = (!reset_sclk && (cycle_count % 64 == 33));
always_comb begin
    iso.srclk = !(iso.sclk && srclk_en);
    iso.srclk2 = !(iso.sclk && srclk2_modules_en);
    srclk2_fpga_launch = !(sclk_ungated && srclk2_fpga_launch_en);
    srclk2_fpga_capture = !(sclk_ungated && srclk2_fpga_capture_en);
end

//  srclk2_sync is generated from negative edge so it is stable when srclk_sync changes.
//  This is intended to avoid hold violations in per-slot hwcon serializers.
always_ff @(negedge sclk_ungated) srclk2_sync <= !(cycle_count % 64 == 63);
always_ff @(posedge sclk_ungated) srclk_sync <= !(cycle_count % 8 == 7);

reg [3:0] clk_inhibit;
reg [3:0] reset_slots;

wire mclk_last;
delay mclk_delay(clk_core, reset, iso.mclk, mclk_last);


//  Parallel versions of serialized signals

//  Coming from modules to FPGA - dirchan and hwflag
wire [7:0] dirchan_parallel;
wire [7:0] hwflag_parallel;
deserializer dirchan_des(sclk_ungated, iso.dirchan, iso.srclk, dirchan_parallel);
deserializer hwflag_des(sclk_ungated, iso.hwflag, iso.srclk, hwflag_parallel);

//  Going from FPGA to modules - hwcon and cs_n
(* keep = "true" *) wire [7:0] hwcon_parallel;
(* keep = "true" *) wire [7:0] cs_n_parallel;
serializer #(.launch_negedge(1)) hwcon_ser(sclk_ungated, iso.hwcon, srclk_sync, hwcon_parallel);
serializer #(.launch_negedge(1)) cs_n_ser(sclk_ungated, iso.cs_n, srclk_sync, cs_n_parallel);


//  FIFOs for clock domain conversion (host interface (USB/FX2) to core)
FIFOInterface #(.num_bits(host_width)) host_in_core (clk_core);
FIFOInterface #(.num_bits(host_width)) host_out_core (clk_core);

wire [M:0] host_in_wr_count;
wire [M:0] host_in_rd_count;
wire [M:0] host_out_wr_count;
wire [M:0] host_out_rd_count;

fifo_async #(.Nb(host_width), .M(M), .N(1 << M)) host_in_h2c(
    .reset,
    .in(host_in),
    .in_count(host_in_wr_count),
    .out(host_in_core.out),
    .out_count(host_in_rd_count)
);

fifo_async #(.Nb(host_width), .M(M), .N(1 << M)) host_out_c2h(
    .reset,
    .in(host_out_core.in),
    .in_count(host_out_wr_count),
    .out(host_out),
    .out_count(host_out_rd_count)
);

reg [7:0] slot_index;

localparam STATE_IDLE = 4'h0;
localparam STATE_HANDLE_INPUT = 4'h1;
localparam STATE_HANDLE_OUTPUT = 4'h2;

reg [23:0] word_counter;
reg [23:0] fifo_read_length;
reg [23:0] fifo_write_length;
localparam cmd_length_words = 24 / (host_width + 1) + 1;

localparam checksum_words = 2;
reg [host_width * checksum_words - 1 : 0] data_checksum_calculated;
reg [host_width * checksum_words - 1 : 0] data_checksum_received;

reg [7:0] current_cmd;
reg [7:0] current_report;
reg [7:0] report_slot_index;
reg [23:0] report_msg_length;
reg [31:0] report_checksum;
reg [3:0] state;

reg [7:0] report_data_waiting;

reg [7:0] sample_bit_counter;

reg cmd_stall;
reg [7:0] cmd_data_waiting;

//  Monitor AMCS and DMCS to estimate what the values are on the board
wire [7:0] cs_n_parallel_est;
deserializer cs_n_des(sclk_ungated, iso.cs_n, iso.srclk, cs_n_parallel_est);

//  Things which are replicated for each slot
assign cs_n_parallel[7:4] = 4'b1111;
assign hwcon_parallel[7:4] = 4'b0000;

/*  FIFO interface declarations
    - Audio data goes through RAM-based arbiter; control data goes through plain FIFOs
    - "In" refers to data coming from the host (i.e. commands, or DAC samples);
      "Out" refers to data going to the host (i.e. responses, or ADC samples).
    - For audio, "Write" refers to the FIFO going into the arbiter, "read" is the one coming out.
      The connection of these FIFOs is reversed for the "in" and "out" directions.
      
      Note that we don't need aud_slots_out_read since the data can only be read
      into one FIFO at a time, and that is audio_out_fifo (defined below, after
      the generate loop for per-slot logic).
 */

FIFOInterface #(.num_bits(32)) aud_slots_in_read[num_slots] (clk_core);
FIFOInterface #(.num_bits(32)) aud_slots_out_write[num_slots] (clk_core);

(* keep = "true" *) FIFOInterface #(.num_bits(8)) ctl_slots_in[num_slots] (clk_core);
(* keep = "true" *) FIFOInterface #(.num_bits(8)) ctl_slots_out[num_slots] (clk_core);

//  RAM-based arbiter for audio FIFOs
//  (in both directions; that's why num_ports = num_slots * 2
//  The inputs and outputs of the arbiter include audio FIFOs in both directions, 
//  and we can't concatenate interface arrays, so there is some plumbing here.

//  Temporary - breakout FIFO interfaces
logic arb_in_ready[num_slots * 2];
logic arb_in_enable[num_slots * 2];
logic [31:0] arb_in_data[num_slots * 2];
logic arb_out_ready[num_slots * 2];
logic arb_out_enable[num_slots * 2];
logic [31:0] arb_out_data[num_slots * 2];

generate for (g = 0; g < num_slots; g++) always_comb begin
    //  Audio in (DAC) has arbitrator I/O ports from 0 to num_slots - 1
    arb_out_ready[g] = aud_slots_in_read[g].ready;
    aud_slots_in_read[g].valid = arb_out_enable[g];
    aud_slots_in_read[g].data = arb_out_data[g];
    
    //  Audio out (ADC) has arbitrator I/O ports from num_slots to 2 * num_slots - 1
    aud_slots_out_write[g].ready = arb_in_ready[num_slots + g];
    arb_in_enable[num_slots + g] = aud_slots_out_write[g].valid;
    arb_in_data[num_slots + g] = aud_slots_out_write[g].data;
end
endgenerate

logic [31:0] fifo_write_counters[num_slots * 2];
logic [31:0] fifo_read_counters[num_slots * 2];

fifo_arbiter #(.num_ports(num_slots * 2), .mem_width(mem_width)) arbiter(
    .reset,
    .clk_core,
    /*
    .ports_in(arb_in.in),
    .ports_out(arb_out.out),
    */
    //  Temporary - breakout FIFO interfaces
    .ports_in_ready(arb_in_ready),
    .ports_in_enable(arb_in_enable),
    .ports_in_data(arb_in_data),
    .ports_out_ready(arb_out_ready),
    .ports_out_enable(arb_out_enable),
    .ports_out_data(arb_out_data),
    
    .clk_mem,
    .mem_cmd(mem_cmd),
    .mem_read(mem_read),
    .mem_write(mem_write),
    
    .write_counters(fifo_write_counters),
    .read_counters(fifo_read_counters)
);

//  Master FIFO interfaces that the logic below deals with
//  (port connection is automatically selected)

FIFOInterface #(.num_bits(32)) aud_in_write (clk_core);
FIFOInterface #(.num_bits(32)) aud_in_read (clk_core);
FIFOInterface #(.num_bits(32)) aud_out_write (clk_core);
FIFOInterface #(.num_bits(32)) aud_out_read (clk_core);

FIFOInterface #(.num_bits(8)) ctl_in (clk_core);
//  FIFOInterface #(.num_bits(host_width)) ctl_out (clk_core);

//  Extra flow control for host input FIFO
logic host_in_ready_int;
always_comb begin
    host_in_core.ready = host_in_ready_int;
    if ((state == STATE_HANDLE_INPUT) && (slot_index != GLOBAL_TARGET_INDEX)) begin
        if ((current_cmd == AUD_FIFO_WRITE) && !aud_in_write.ready)
            host_in_core.ready = 0;
        if ((current_cmd == CMD_FIFO_WRITE) && !ctl_in.ready)
            host_in_core.ready = 0;
    end
end

/*
//  Extra flow control for audio and control FIFOs
logic aud_out_read_ready_int;
logic ctl_out_ready_int;
always_comb begin
    aud_out_read.ready = aud_out_read_ready_int;
    ctl_out.ready = ctl_out_ready_int;
end
*/

//  Global enable - used to atomically start/stop groups of slots
//  in order to get perfect output synchronization
(* keep = "true" *) logic [num_slots - 1 : 0] slot_fifo_en;

//  New experiment for slot muxing - 8/9/2016
logic ctl_slots_in_ready[num_slots];
logic ctl_slots_out_ready[num_slots];
logic ctl_slots_out_enable[num_slots];
logic ctl_slots_out_waiting[num_slots];
logic [host_width - 1 : 0] ctl_slots_out_data[num_slots];
generate for (g = 0; g < num_slots; g++) begin: ctl_slot_map
    always_comb begin
        ctl_slots_in_ready[g] = ctl_slots_in[g].ready;
        ctl_slots_out[g].ready = ctl_slots_out_ready[g];
        ctl_slots_out_enable[g] = ctl_slots_out[g].valid;
        ctl_slots_out_data[g] = ctl_slots_out[g].data;
    end
end
endgenerate

always_comb begin
    aud_in_write.ready = 0;
    aud_out_read.valid = 0;
    aud_out_read.data = 0;
    for (int i = 0; i < num_slots; i++) if (slot_index == i) begin
        aud_in_write.ready = arb_in_ready[i];
        aud_out_read.valid = arb_out_enable[num_slots + i];
        aud_out_read.data = arb_out_data[num_slots + i];
    end
    
    ctl_in.ready = 0;
    //  ctl_out.valid = 0;
    //  ctl_out.data = 0;
    for (int i = 0; i < num_slots; i++) if (slot_index == i) begin
        ctl_in.ready = ctl_slots_in_ready[i];
        //  ctl_out.valid = ctl_slots_out_enable[i];
        //  ctl_out.data = ctl_slots_out_data[i];
    end
end

generate for (g = 0; g < num_slots; g++) begin: slots

    //  Muxing of audio FIFOs.  Assignment to array elements can be done with always_comb,
    //  but assignment to master interfaces has to be done with assign.
    always_comb begin
        if (slot_index == g) begin
            arb_in_enable[g] = aud_in_write.valid;
            arb_in_data[g] = aud_in_write.data;
        end
        else begin
            arb_in_enable[g] = 0;
            arb_in_data[g] = 0;
        end
    end
    
    //  Muxing of control FIFOs.
    always_comb begin
        if (slot_index == g) begin
            ctl_slots_in[g].valid = ctl_in.valid;
            ctl_slots_in[g].data = ctl_in.data;
            //  ctl_slots_out[g].ready = ctl_out.ready;

        end
        else begin
            ctl_slots_in[g].valid = 0;
            ctl_slots_in[g].data = 0;
            //  ctl_slots_out[g].ready = 0;
        end
    end

    //  Muxing of isolator interface signals
    wire slot_clk = (!clk_inhibit[g]) && iso.mclk;

    wire slot_dir = dirchan_parallel[g];
    wire slot_chan = dirchan_parallel[g+4];
    wire [7:0] slot_hwflag;
    wire [7:0] slot_hwcon;

    //  Ser/des of hwcon and hwflag
    deserializer slot_hwflag_deser(iso.srclk, hwflag_parallel[g], srclk2_fpga_capture, slot_hwflag);
    serializer #(.launch_negedge(1)) slot_hwcon_ser(srclk_sync, hwcon_parallel[g], srclk2_sync, slot_hwcon);

    wire slot_spi_ss_out;
    assign cs_n_parallel[g] = slot_spi_ss_out;
    
    wire slot_spi_ss_in = cs_n_parallel_est[g];
    wire slot_spi_sck;
    wire slot_spi_mosi;
    assign iso.mosi = (slot_spi_ss_in == 0) ? slot_spi_mosi : 1'bz;
    wire slot_spi_miso = iso.miso;

    //  Debug - monitor SPI state
    wire [3:0] slot_spi_state;
    assign led_debug = (g == 0) ? slot_spi_state : 4'bzzzz;

    //  Slot controllers
    //  Note: control protocol uses 8 LSBs only
    slot_controller ctl(
        .clk_core(clk_core), 
        .reset(reset_slots[g]),
        .ctl_rd(ctl_slots_in[g]),
        .ctl_wr(ctl_slots_out[g]),
        .aud_rd(aud_slots_in_read[g]),
        .aud_wr(aud_slots_out_write[g]),
        .spi_ss_out(slot_spi_ss_out), 
        .spi_ss_in(slot_spi_ss_in),
        .spi_sck(slot_spi_sck), 
        .spi_mosi(slot_spi_mosi), 
        .spi_miso(slot_spi_miso),
        .slot_data(iso.slotdata[(g+1)*6-1:g*6]), 
        .slot_clk(slot_clk), 
        .sclk(sclk_ungated), 
        .dir(slot_dir), 
        .chan(slot_chan),
        .hwcon(slot_hwcon), 
        .hwflag(slot_hwflag),
        .spi_state(slot_spi_state),
        .ctl_wr_waiting(ctl_slots_out_waiting[g]),
        .fifo_en(slot_fifo_en[g])
    );

end
endgenerate

//  Audio output (ADC) FIFO:
//  Stores samples so they can be sent out in batches.
//  FIFO interfaces and some control registers

localparam audio_out_fifo_depth = 128;
localparam audio_out_fifo_timeout_cycles = 1200;  //  should normally be 48000 (1 ms), but that makes simulation longer

FIFOInterface #(.num_bits(32)) audio_out_fifo_in(clk_core);
FIFOInterface #(.num_bits(32)) audio_out_fifo_out(clk_core);
logic [$clog2(audio_out_fifo_depth):0] audio_out_fifo_count;
logic [1:0] audio_out_fifo_slot;
logic audio_out_fifo_write_active;
logic audio_out_fifo_read_active;
logic [15:0] audio_out_fifo_write_count;

logic [15:0] audio_out_lsb_word;
logic audio_out_lsb_pending;

logic [15:0] audio_out_fifo_timeout_counter;

fifo_sync #(.Nb(32), .M($clog2(audio_out_fifo_depth))) audio_out_fifo(
    .clk(clk_core),
    .reset,
    .in(audio_out_fifo_in.in),
    .out(audio_out_fifo_out.out),
    .count(audio_out_fifo_count)
);

always_comb begin
    //  Connect selected arb_out port to audio_out_fifo_in when audio_out_fifo_write_active = 1
    audio_out_fifo_in.valid = 0;
    audio_out_fifo_in.data = 0;
    if (audio_out_fifo_write_active) begin
        audio_out_fifo_in.valid = arb_out_enable[num_slots + audio_out_fifo_slot];
        audio_out_fifo_in.data = arb_out_data[num_slots + audio_out_fifo_slot];
    end
    //  Stall audio_out_fifo_out when host isn't ready
    audio_out_fifo_out.ready = audio_out_fifo_read_active && !audio_out_lsb_pending && host_out_core.ready;
end

generate for (g = 0; g < num_slots; g = g + 1) begin
    always_comb begin
        arb_out_ready[num_slots + g] = 0;
        if (audio_out_fifo_write_active && (g == audio_out_fifo_slot)) 
            arb_out_ready[num_slots + g] = audio_out_fifo_in.ready;
    end
end
endgenerate

//  Control output FIFO:
//  Same idea as audio output FIFO: give each slot a certain window of time to provide control messages
//  This also helps since we'll know the right length in advance by watching the FIFO count
localparam ctl_out_fifo_depth = 32;
localparam ctl_out_fifo_timeout_cycles = 480;   //  10 us

FIFOInterface #(.num_bits(host_width)) ctl_out_fifo_in(clk_core);
FIFOInterface #(.num_bits(host_width)) ctl_out_fifo_out(clk_core);
logic [$clog2(ctl_out_fifo_depth):0] ctl_out_fifo_count;
logic [1:0] ctl_out_fifo_slot;
logic ctl_out_fifo_write_active;
logic ctl_out_fifo_read_active;

logic [15:0] ctl_out_fifo_timeout_counter;

fifo_sync #(.Nb(host_width), .M($clog2(ctl_out_fifo_depth))) ctl_out_fifo(
    .clk(clk_core),
    .reset,
    .in(ctl_out_fifo_in.in),
    .out(ctl_out_fifo_out.out),
    .count(ctl_out_fifo_count)
);

always_comb begin
    //  Connect selected ctl_out port to audio_out_fifo_in when audio_out_fifo_write_active = 1
    for (int i = 0; i < num_slots; i++) ctl_slots_out_ready[i] = 0;
    ctl_out_fifo_in.valid = 0;
    ctl_out_fifo_in.data = 0;
    if (ctl_out_fifo_write_active) begin
        ctl_slots_out_ready[ctl_out_fifo_slot] = ctl_out_fifo_in.ready;
        ctl_out_fifo_in.valid = ctl_slots_out_enable[ctl_out_fifo_slot];
        ctl_out_fifo_in.data = ctl_slots_out_data[ctl_out_fifo_slot];
    end
    //  Stall audio_out_fifo_out when host isn't ready
    ctl_out_fifo_out.ready = ctl_out_fifo_read_active && host_out_core.ready;
end


//  Temporary echo FIFO

FIFOInterface #(.num_bits(8)) echo_wr(clk_core);
FIFOInterface #(.num_bits(8)) echo_rd(clk_core);

wire [4:0] echo_fifo_count;
fifo_sync #(.Nb(8), .M(4)) echo_fifo(
	.clk(clk_core), 
	.reset(reset),
	.in(echo_wr.in),
	.out(echo_rd.out),
	.count(echo_fifo_count)
);
reg [3:0] echo_count;

//  Sequential logic
integer i;

always @(posedge clk_core) begin
    if (reset) begin
        host_in_ready_int <= 0;
        host_out_core.valid <= 0;
        host_out_core.data <= 0;
        
        slot_index <= 0;
        report_slot_index <= 0;
        
        aud_in_write.valid <= 0;
        aud_in_write.data <= 0;
        //  aud_out_read_ready_int <= 0;
        ctl_in.valid <= 0;
        ctl_in.data <= 0;
        //  ctl_out_ready_int <= 0;

        iso.clksel <= 0;
        clk_inhibit <= 0;
        reset_slots <= 4'hF;
        
        word_counter <= 0;
        fifo_read_length <= 0;
        fifo_write_length <= 0;
        data_checksum_calculated <= 0;
        data_checksum_received <= 0;
        current_cmd <= 0;
        current_report <= 0;
        state <= STATE_IDLE;
        
        sclk_en <= 1;
        
        report_data_waiting <= 0;
        report_msg_length <= 0;
        report_checksum <= 0;

        echo_wr.valid <= 0;
        echo_wr.data <= 0;
        echo_rd.ready <= 0;
        echo_count <= 0;

        cmd_stall <= 0;
        cmd_data_waiting <= 0;

        sample_bit_counter <= 0;

        audio_out_fifo_slot <= 0;
        audio_out_fifo_write_active <= 0;
        audio_out_fifo_read_active <= 0;
        audio_out_fifo_timeout_counter <= 0;
        audio_out_fifo_write_count <= 0;
        audio_out_lsb_pending <= 0;
        audio_out_lsb_word <= 0;
        
        ctl_out_fifo_slot <= 0;
        ctl_out_fifo_write_active <= 0;
        ctl_out_fifo_read_active <= 0;
        ctl_out_fifo_timeout_counter <= 0;
        
        //  Start out with all slots enabled to reduce confusion
        slot_fifo_en <= '1;
        
        reset_local <= 0;
        reset_local_hold <= 0;
        reset_local_counter <= 0;
    end
    else begin
        host_in_ready_int <= 0;
        if (host_out_core.ready) host_out_core.valid <= 0;

        if (aud_in_write.ready) aud_in_write.valid <= 0;
        //  aud_out_read_ready_int <= 0;
        if (ctl_in.ready) ctl_in.valid <= 0;
        //  ctl_out_ready_int <= 0;

        echo_wr.valid <= 0;
        echo_rd.ready <= 0;
        clk_inhibit <= 0;

        if (reset_local) begin
            if (reset_local_counter == reset_local_timeout_cycles - 1)
                reset_local <= 0;
            else if (!reset_local_hold)
                reset_local_counter <= reset_local_counter + 1;
        end

        for (i = 0; i < 4; i = i + 1) begin
            if (reset_slots[i] && !clk_inhibit[i] && !reset_sclk) begin
                //  Wait for MCLK pulse before disabling reset for that slot
                if (iso.mclk && !mclk_last) begin
                    reset_slots[i] <= 0;
                end
            end
        end

        if (host_out_core.ready && host_out_core.valid)
            report_checksum <= report_checksum + host_out_core.data;

        case (state)
        STATE_IDLE: begin
            
            host_in_ready_int <= 1;

            if (host_in_core.ready && host_in_core.valid) begin
                slot_index <= host_in_core.data;
                word_counter <= 0;
                state <= STATE_HANDLE_INPUT;
            end
            else begin
                
                if ((ctl_out_fifo_count == ctl_out_fifo_depth) || (ctl_out_fifo_timeout_counter == ctl_out_fifo_timeout_cycles)) begin
                    //  If the control output FIFO has filled, go output it to the host.
                    ctl_out_fifo_write_active <= 0;
                    ctl_out_fifo_timeout_counter <= 0;
                    report_slot_index <= ctl_out_fifo_slot;
                    report_msg_length <= ctl_out_fifo_count;
                    report_checksum <= 0;
                    word_counter <= 0;
                    current_report <= CMD_FIFO_REPORT;
                    state <= STATE_HANDLE_OUTPUT;
                end
                /*
                //  Experimenting with new audio FIFO discharge method - 1/1/2017
                else if ((audio_out_fifo_count == audio_out_fifo_depth) || (audio_out_fifo_timeout_counter == audio_out_fifo_timeout_cycles)) begin
                    //  If the audio output FIFO has filled, go output it to the host.
                    audio_out_fifo_write_active <= 0;
                    audio_out_fifo_timeout_counter <= 0;
                    audio_out_lsb_pending <= 0;
                    report_slot_index <= audio_out_fifo_slot;
                    report_msg_length <= audio_out_fifo_count * (32 / host_width);
                    report_checksum <= 0;
                    word_counter <= 0;
                    current_report <= AUD_FIFO_REPORT;
                    state <= STATE_HANDLE_OUTPUT;
                end
                
                //  Parallel part 1: audio FIFO management
                
                //  Update cycle counter for timeout
                if (audio_out_fifo_write_active) begin
                    if (audio_out_fifo_in.valid)
                        audio_out_fifo_timeout_counter <= 0;
                    else if (audio_out_fifo_timeout_counter < audio_out_fifo_timeout_cycles)
                        audio_out_fifo_timeout_counter <= audio_out_fifo_timeout_counter + 1;
                end
            
                //  Start an audio output transfer if there is valid data at the next slot
                if (!audio_out_fifo_write_active) begin
                    assert (audio_out_fifo_count == 0);
                    if (arb_out_enable[num_slots + audio_out_fifo_slot]) begin
                        audio_out_fifo_timeout_counter <= 0;
                        audio_out_fifo_write_active <= 1;
                    end
                    else begin
                        //  Cycle the slot index so we're always checking for data
                        if (audio_out_fifo_slot == num_slots - 1)
                            audio_out_fifo_slot <= 0;
                        else
                            audio_out_fifo_slot <= audio_out_fifo_slot + 1;
                    end
                end
                */

                /*  Parallel part 2: control FIFO management */
                
                //  Update cycle counter for timeout
                if (ctl_out_fifo_write_active) begin
                    if (ctl_out_fifo_in.valid)
                        ctl_out_fifo_timeout_counter <= 0;
                    else if (ctl_out_fifo_timeout_counter < ctl_out_fifo_timeout_cycles)
                        ctl_out_fifo_timeout_counter <= ctl_out_fifo_timeout_counter + 1;
                end
            
                //  Start an audio output transfer if there is valid data at the next slot
                if (!ctl_out_fifo_write_active) begin
                    assert (ctl_out_fifo_count == 0);
                    if (ctl_slots_out_waiting[ctl_out_fifo_slot]) begin
                        ctl_out_fifo_timeout_counter <= 0;
                        ctl_out_fifo_write_active <= 1;
                    end
                    else begin
                        //  Cycle the slot index so we're always checking for data
                        if (ctl_out_fifo_slot == num_slots - 1)
                            ctl_out_fifo_slot <= 0;
                        else
                            ctl_out_fifo_slot <= ctl_out_fifo_slot + 1;
                    end
                end

            end

        end
        STATE_HANDLE_INPUT: begin
            /*
                This state is entered after the target slot has been read and stored
                in slot_index.
                - Byte counter = 0: command index
                - Byte counter = 1 to N - 1: command-specific data
            */
            host_in_ready_int <= 1;
            if (host_in_core.ready && host_in_core.valid) begin
                word_counter <= word_counter + 1;
                if (word_counter == 0) begin
                    current_cmd <= host_in_core.data;
                    data_checksum_calculated <= 0;
                    data_checksum_received <= 0;
                    report_checksum <= 0;
                    case (host_in_core.data)
                    DIRCHAN_READ: begin
                        word_counter <= 0;
                        report_slot_index <= GLOBAL_TARGET_INDEX;
                        report_msg_length <= 1;
                        current_report <= DIRCHAN_REPORT;
                        state <= STATE_HANDLE_OUTPUT;
                    end
                    AOVF_READ: begin
                        word_counter <= 0;
                        report_slot_index <= GLOBAL_TARGET_INDEX;
                        report_msg_length <= 1;
                        current_report <= AOVF_REPORT;
                        state <= STATE_HANDLE_OUTPUT;
                    end
                    FIFO_READ_STATUS: begin
                        word_counter <= 0;
                        report_slot_index <= GLOBAL_TARGET_INDEX;
                        report_msg_length <= num_slots * 4 * 32 / host_width;
                        current_report <= FIFO_REPORT_STATUS;
                        state <= STATE_HANDLE_OUTPUT;
                    end
                    RESET_SLOTS: begin
                        reset_local <= 1;
                        reset_local_hold <= 0;
                        reset_local_counter <= 0;
                        state <= STATE_IDLE;
                    end
                    ENTER_RESET: begin
                        reset_local <= 1;
                        reset_local_hold <= 1;
                        reset_local_counter <= 0;
                        state <= STATE_IDLE;
                    end
                    LEAVE_RESET: begin
                        reset_local_hold <= 0;
                        state <= STATE_IDLE;
                    end
                    STOP_SCLK: begin
                        sclk_en <= 0;
                        state <= STATE_IDLE;
                    end
                    START_SCLK: begin
                        sclk_en <= 1;
                        state <= STATE_IDLE;
                    end
                    endcase
                end
                else case (current_cmd)
                AUD_FIFO_WRITE, CMD_FIFO_WRITE: begin
                    if (word_counter < (1 + cmd_length_words)) begin
                        fifo_read_length <= {fifo_read_length, host_in_core.data};
                        sample_bit_counter <= 0;
                    end
                    else if (word_counter > fifo_read_length + cmd_length_words) begin
                        data_checksum_received <= {data_checksum_received, host_in_core.data};
                        if (word_counter == fifo_read_length + cmd_length_words + checksum_words) begin
                            //  Compare checksums
                            if ({data_checksum_received, host_in_core.data} != data_checksum_calculated) begin
                                word_counter <= 0;
                                report_slot_index <= slot_index;
                                report_msg_length <= 4;
                                current_report <= CHECKSUM_ERROR;
                                state <= STATE_HANDLE_OUTPUT;
                            end
                            else begin
                                state <= STATE_IDLE;
                            end
                        end
                    end
                    else begin
                        if (current_cmd == AUD_FIFO_WRITE) begin
                            //  Data is written to target FIFO
                            if (sample_bit_counter + host_width >= 32) begin
                                aud_in_write.valid <= 1;
                                sample_bit_counter <= 0;
                            end
                            else begin
                                aud_in_write.valid <= 0;
                                sample_bit_counter <= sample_bit_counter + host_width;
                            end
                            aud_in_write.data <= {aud_in_write.data, host_in_core.data};
                        end
                        else if (current_cmd == CMD_FIFO_WRITE) begin
                            ctl_in.valid <= 1;
                            ctl_in.data <= host_in_core.data[7:0];
                        end
                        /*
                        else begin  // if (current_cmd == AUD_FIFO_READ)
                            if (word_counter - cmd_length_words - 1 == 0) begin
                                audio_out_fifo_slot <= 
                            end
                        end
                        */
                        
                        //  Update checksum
                        data_checksum_calculated <= data_checksum_calculated + host_in_core.data;
                    end
                end
                
                AUD_FIFO_READ: begin
                    //  Added 1/1/2017
                    //  2 words: the number of samples to read
                    fifo_read_length <= {fifo_read_length, host_in_core.data};
                    if (word_counter == 2) begin
                        audio_out_fifo_write_active <= 1;
                        audio_out_fifo_write_count <= 0;
                        audio_out_fifo_slot <= slot_index;
                        audio_out_lsb_pending <= 0;
                        report_slot_index <= slot_index;
                        report_msg_length <= {fifo_read_length, host_in_core.data} * (32 / host_width);
                        report_checksum <= 0;
                        word_counter <= 0;
                        current_report <= AUD_FIFO_REPORT;
    
                        state <= STATE_HANDLE_OUTPUT;
                    end
                end
                
                UPDATE_BLOCKING: begin
                    //  We only care about the first word...
                    slot_fifo_en <= host_in_core.data;
                    state <= STATE_IDLE;
                end

                ECHO_SEND: begin
                    if (word_counter == 1) begin
                        echo_count <= host_in_core.data;
                    end
                    else begin
                        echo_wr.valid <= 1;
                        echo_wr.data <= host_in_core.data;
                        if (word_counter == echo_count + 1) begin
                            word_counter <= 0;
                            report_slot_index <= slot_index;
                            report_msg_length <= echo_count;
                            current_report <= ECHO_REPORT;
                            state <= STATE_HANDLE_OUTPUT;
                        end
                    end
                end

                SELECT_CLOCK: begin
                    //  For each slot that is being switched over, stop the clock and reset it.
                    clk_inhibit <= (iso.clksel ^ host_in_core.data[0]);
                    reset_slots <= (iso.clksel ^ host_in_core.data[0]);
                    iso.clksel <= host_in_core.data[0];
                    word_counter <= 0;
                    state <= STATE_IDLE;
                end

                endcase
                
            end
        end
        STATE_HANDLE_OUTPUT: begin
        
            //  Monitor audio output FIFO and stop it once we collected the right number of samples
            if (audio_out_fifo_write_active) begin
                if (audio_out_fifo_in.ready && audio_out_fifo_in.valid) begin
                    audio_out_fifo_write_count <= audio_out_fifo_write_count + 1;
                    if (audio_out_fifo_write_count == fifo_read_length - 1)
                        audio_out_fifo_write_active <= 0;
                end
            end
        
            if (host_out_core.ready) begin

                word_counter <= word_counter + 1;
                host_out_core.valid <= 1;
                if (word_counter < 4) case (word_counter)
                    //  Header
                    0:  host_out_core.data <= report_slot_index;
                    1:  host_out_core.data <= current_report;
                    2:  host_out_core.data <= report_msg_length[23:16];
                    3:  host_out_core.data <= report_msg_length[15:0];
                endcase
                else if (word_counter < 4 + report_msg_length) begin
                    //  Message contents
                    case (current_report)
                    AUD_FIFO_REPORT: begin
                        audio_out_fifo_read_active <= 1;
                        if (audio_out_fifo_out.ready && audio_out_fifo_out.valid) begin
                            //  This will need to be reworked if host width is changed from 16 bits
                            host_out_core.data <= audio_out_fifo_out.data[15:0];
                            audio_out_lsb_word <= audio_out_fifo_out.data[31:16];
                            audio_out_lsb_pending <= 1;
                        end
                        else if (audio_out_lsb_pending) begin
                            host_out_core.data <= audio_out_lsb_word;
                            audio_out_lsb_pending <= 0;
                        end
                        else begin
                            //  Skip...
                            host_out_core.valid <= 0;
                            word_counter <= word_counter;
                        end
                    end
                    CMD_FIFO_REPORT: begin
                        ctl_out_fifo_read_active <= 1;
                        if (ctl_out_fifo_out.ready && ctl_out_fifo_out.valid)
                            host_out_core.data <= ctl_out_fifo_out.data;
                        else begin
                            //  Skip...
                            host_out_core.valid <= 0;
                            word_counter <= word_counter;
                        end
                    end
                    DIRCHAN_REPORT: begin
                    	host_out_core.data <= dirchan_parallel;
                    end
                    AOVF_REPORT: begin
                        //  TODO: Expand, since this is now 8 bits per module = 32 bits.
                        host_out_core.data <= hwflag_parallel;
                    end
                    FIFO_REPORT_STATUS: begin
                        case ((word_counter - 4) % 4)
                        0: host_out_core.data <= fifo_write_counters[(word_counter - 4) / 4][31:16];
                        1: host_out_core.data <= fifo_write_counters[(word_counter - 4) / 4][15:0];
                        2: host_out_core.data <= fifo_read_counters[(word_counter - 4) / 4][31:16];
                        3: host_out_core.data <= fifo_read_counters[(word_counter - 4) / 4][15:0];
                        endcase
                    end
                    CHECKSUM_ERROR: begin
                        //  TODO: Fix
                        case (word_counter)
                        4: host_out_core.data <= data_checksum_received[15:8];
                        5: host_out_core.data <= data_checksum_received[7:0];
                        6: host_out_core.data <= data_checksum_calculated[15:8];
                        7: host_out_core.data <= data_checksum_calculated[7:0];
                        endcase
                    end
                    ECHO_REPORT: begin
                        echo_rd.ready <= 1;
                        if (echo_rd.valid) begin
                            host_out_core.data <= echo_rd.data;
                        end
                        else begin
                            //  Skip...
                            host_out_core.valid <= 0;
                            word_counter <= word_counter;
                        end
                    end
                    endcase
                end
                else begin
                    //  Stop changing the checksum when we're outputting the checksum...
                    report_checksum <= report_checksum;
                    
                    //  Footer (checksum)
                    case (word_counter)
                    4 + report_msg_length: host_out_core.data <= report_checksum[31:16];
                    5 + report_msg_length: begin
                        host_out_core.data <= report_checksum[15:0];
                        word_counter <= 0;
                        audio_out_fifo_read_active <= 0;
                        ctl_out_fifo_read_active <= 0;
                        state <= STATE_IDLE;
                    end
                    endcase
                end

            end
        end
        endcase
    end
end


endmodule


