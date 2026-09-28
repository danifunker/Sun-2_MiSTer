//
// sun2_mister_block.sv
//
// Bridge between MiSTer sd_card block interface and the Sun-2 blk_* seam.
//
`timescale 1ns / 1ps

module sun2_mister_block (
    input  wire        clk,
    input  wire        rst,

    // Sun-2 controller side (blk_* seam)
    input  wire        blk_start,
    input  wire        blk_we,
    input  wire [31:0] blk_lba,
    output wire [7:0]  blk_buf_rdata,
    output reg         blk_done,
    output reg         blk_err,
    output reg         blk_ready,
    output reg  [31:0] blk_count,
    output reg         blk_buf_we,
    output reg  [8:0]  blk_buf_addr,
    output reg  [7:0]  blk_buf_wdata,

    // MiSTer sd_card interface
    output reg  [31:0] sd_lba,
    output reg         sd_rd,
    output reg         sd_wr,
    input  wire        sd_ack,
    input  wire [8:0]  sd_buff_addr,
    input  wire [7:0]  sd_buff_dout,
    output wire [7:0]  sd_buff_din,
    input  wire        sd_buff_wr,
    input  wire        img_mounted,
    input  wire [63:0] img_size
);

    typedef enum logic [2:0] {
        ST_IDLE,
        ST_READ_WAIT,
        ST_WRITE_REQ,
        ST_WRITE_WAIT,
        ST_DONE
    } state_t;

    state_t state = ST_IDLE;
    reg     ack_d = 1'b0;

    // Direct buffer data routing
    assign sd_buff_din   = blk_buf_rdata;

    always @(posedge clk) begin
        ack_d <= sd_ack;

        if (rst) begin
            state        <= ST_IDLE;
            sd_rd        <= 1'b0;
            sd_wr        <= 1'b0;
            blk_done     <= 1'b0;
            blk_err      <= 1'b0;
            blk_buf_we   <= 1'b0;
            blk_ready    <= 1'b0;
            blk_count    <= 32'd0;
        end else begin
            blk_done   <= 1'b0;
            blk_buf_we <= 1'b0;

            // Update disk presence and block capacity from MiSTer mount
            if (img_mounted) begin
                blk_ready <= (img_size != 0);
                blk_count <= img_size[40:9]; // number of 512-byte sectors
            end

            case (state)
                ST_IDLE: begin
                    if (blk_start) begin
                        sd_lba  <= blk_lba;
                        blk_err <= 1'b0;
                        if (blk_lba >= blk_count && blk_count != 0) begin
                            blk_err  <= 1'b1;
                            blk_done <= 1'b1;
                        end else if (!blk_we) begin
                            // Read request
                            sd_rd <= 1'b1;
                            state <= ST_READ_WAIT;
                        end else begin
                            // Write request
                            sd_wr <= 1'b1;
                            state <= ST_WRITE_WAIT;
                        end
                    end
                end

                ST_READ_WAIT: begin
                    // Forward bytes being read into the controller buffer
                    blk_buf_we    <= sd_buff_wr;
                    blk_buf_addr  <= sd_buff_addr;
                    blk_buf_wdata <= sd_buff_dout;

                    if (sd_ack && !ack_d) begin
                        sd_rd    <= 1'b0;
                        blk_done <= 1'b1;
                        state    <= ST_IDLE;
                    end
                end

                ST_WRITE_WAIT: begin
                    // Forward read address from sd_card to controller buffer
                    blk_buf_addr <= sd_buff_addr;

                    if (sd_ack && !ack_d) begin
                        sd_wr    <= 1'b0;
                        blk_done <= 1'b1;
                        state    <= ST_IDLE;
                    end
                end

                default: state <= ST_IDLE;
            endcase
        end
    end

endmodule
