//------------------------------------------------------------------------------
// A cache in front of a ROM that lives in SDRAM, for a CPU that cannot wait.
//
// The 6809 on the sound board clocks the CVSD decoder with its own writes, so
// its execution rate IS the speech's pitch (docs/hardware.md section 6), and it
// reads its ROM through the same SDRAM the blitter is bursting from.  A read
// has 44 clocks to answer before the 6809's cycle has to be stretched; an
// SDRAM read behind a 32-word burst chunk and another client's turn can take
// a hundred.  Measured on sim/run_pocket.sh without this: 414 stretched
// cycles in the hundred frames of the power-up RAM test alone.
//
// Direct mapped, 16-bit words, over a ROM - nothing can go stale, so there is
// no coherency question, only the valid bits, which are cleared at reset and
// whenever a new image is coming in (a zero cached before the image arrives
// would be served for ever: the Xenophobe core's rom_icache found that out).
//
// After every word it serves it fetches the NEXT word if that is not in yet.
// Code runs forwards and sample data is read forwards, so the miss that is
// left is the first word after a jump; the loops that matter - the CVSD bit
// loop, the DAC loop - sit in the cache whole.
//
// The line is chosen by the low address bits XORed with the TOP three, which
// for the sound ROM are the bank.  The sound program keeps a header at the
// same offset in every bank and reads it after each bank switch; indexed by
// the low bits alone those headers share one line and evict each other for
// ever.  Measured on the 6809's own access log, 9 s of play, 2048 lines with
// the prefetch: 125,181 misses indexed plainly, 4,633 indexed this way.
//
// Ports: level request, one-clock ack with the data, both sides.
//------------------------------------------------------------------------------
`default_nettype none

module rom_cache #(
    parameter int AW  = 17,             // word address width
    parameter int IDX = 11              // log2 lines
) (
    input  logic          clk,
    input  logic          flush,        // clear every line (held or pulsed)

    input  logic          req,
    input  logic [AW-1:0] addr,
    output logic          ack,
    output logic   [15:0] q,

    output logic          m_req,        // to the memory
    output logic [AW-1:0] m_addr,
    input  logic          m_ack,
    input  logic   [15:0] m_q,

    output logic   [15:0] misses        // demand misses, saturating: for the bench
);
    localparam int TW = AW - IDX;
    function automatic logic [IDX-1:0] line(input logic [AW-1:0] a);
        return a[IDX-1:0] ^ {a[AW-1:AW-3], {(IDX-3){1'b0}}};
    endfunction

    logic [15:0]  data_ram [1 << IDX];
    logic [TW:0]  tag_ram  [1 << IDX];  // {valid, tag}
    logic [15:0]  data_q;
    logic [TW:0]  tag_q;
    logic [IDX-1:0] rd_idx;
    logic           wr_en;
    logic [IDX-1:0] wr_idx;
    logic [15:0]    wr_data;
    logic [TW:0]    wr_tag;

    always_ff @(posedge clk) begin
        data_q <= data_ram[rd_idx];
        tag_q  <= tag_ram[rd_idx];
        if (wr_en) begin
            data_ram[wr_idx] <= wr_data;
            tag_ram[wr_idx]  <= wr_tag;
        end
    end

    typedef enum logic [2:0] { C_CLEAR, C_IDLE, C_LOOK, C_MISS, C_NEXT, C_NLOOK, C_NFILL } st_t;
    st_t           st;
    logic [AW-1:0] cur;                 // the word being looked up or fetched
    logic          demand;              // ...for the CPU, as opposed to ahead of it
    logic [IDX-1:0] clr;

    wire hit = tag_q[TW] && (tag_q[TW-1:0] == cur[AW-1:IDX]);

    always_comb begin
        rd_idx  = (st == C_IDLE) ? line(addr) : line(cur);
        wr_en   = 1'b0; wr_idx = line(cur); wr_data = m_q; wr_tag = {1'b1, cur[AW-1:IDX]};
        if (st == C_CLEAR) begin wr_en = 1'b1; wr_idx = clr; wr_tag = '0; end
        else if ((st == C_MISS || st == C_NFILL) && m_ack) wr_en = 1'b1;
    end

    always_ff @(posedge clk) begin
        ack <= 1'b0;
        if (flush) begin
            st <= C_CLEAR; clr <= '0; m_req <= 1'b0; misses <= '0;
        end else case (st)
            C_CLEAR: begin
                clr <= clr + 1'd1;
                if (&clr) st <= C_IDLE;
            end
            C_IDLE: if (req && !ack) begin
                cur <= addr; demand <= 1'b1;
                st  <= C_LOOK;                  // rd_idx was addr this clock
            end
            C_LOOK: begin
                if (hit) begin
                    q <= data_q; ack <= 1'b1;
                    st <= C_NEXT;
                end else begin
                    m_req <= 1'b1; m_addr <= cur;
                    if (!(&misses)) misses <= misses + 16'd1;
                    st <= C_MISS;
                end
            end
            C_MISS: if (m_ack) begin
                m_req <= 1'b0;
                q <= m_q; ack <= 1'b1;
                st <= C_NEXT;
            end
            // look one word ahead
            C_NEXT: begin
                cur <= cur + 1'd1; demand <= 1'b0;
                st  <= C_NLOOK;
            end
            C_NLOOK: begin
                // rd_idx has been cur for a clock only now; take one more
                st <= C_NFILL;
            end
            C_NFILL: begin
                if (!m_req) begin
                    if (hit) st <= C_IDLE;
                    else begin m_req <= 1'b1; m_addr <= cur; end
                end else if (m_ack) begin
                    m_req <= 1'b0;
                    st <= C_IDLE;
                end
            end
            default: st <= C_IDLE;
        endcase
    end

    wire _unused = demand;
endmodule

`default_nettype wire
