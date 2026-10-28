
module video #(
  parameter BORDER = 1
)(
  input clk_sys,
  input clk_vid,

  output reg hs,
  output reg vs,
  output reg hb,
  output reg vb,

  output reg [8:0] hcount,
  output reg [8:0] vcount,

  output reg [7:0] red,
  output reg [7:0] green,
  output reg [7:0] blue,

  output reg [15:0] ram_addr,
  output reg [10:0] char_addr,
  input [7:0] ram_data,
  input [7:0] char_data,

  output reg frame,
  output reg ce_pix,

  input color_board,
  input inverted,
  input [2:0] border_color,

  // $EFE0. bit6 = graphics enabled, bit7 = graphics ONLY (clear = mixed with
  // text), bits[3:0] = page. Both $40-$4F (mixed) and $C0-$CF (graphics only)
  // have bit 6 set -- that is the enable; bit 7 picks between them. MAME only
  // ever tests bit 7 and calls bit 6 "unknown, set in tandem".
  //   base = $0900 + $200 * (mode & $0F); page 1 $0900, page 2 $2100.
  // Bitmap bytes are row-interleaved per character cell -- the 8 scanlines of
  // one cell are 32 bytes apart. [bm2 depend.c:259-285, 327-370]
  input [7:0] screen_mode,

  input [7:0] charcolor,
  input [9:0] color_ram_addr,
  input color_ram_wr

);

// Native picture: 256x192. With the MP-1710 border enabled, expose bm2's
// documented 32 pixels on each side and 24 lines above/below as a 320x240
// active frame. The framebuffer remains native-sized.
localparam ACTIVE_W = BORDER ? 320 : 256;
localparam ACTIVE_H = BORDER ? 240 : 192;
localparam H_TOTAL  = BORDER ? 400 : 344;
localparam H_FP     = BORDER ? 16  : 16;
localparam H_SYNC   = BORDER ? 40  : 40;
localparam V_TOTAL  = BORDER ? 262 : 262;
localparam V_FP     = BORDER ? 4   : 24;
localparam V_SYNC   = BORDER ? 3   : 34;
localparam X_OFF    = BORDER ? 32  : 0;
localparam Y_OFF    = BORDER ? 24  : 0;

// Scan-side sync and blanking. The registered outputs hs/vs/hb/vb trail these
// by one pixel, the same pixel of latency red/green/blue have.
reg hs_i = 1'b1, vs_i = 1'b1, hb_i, vb_i;

initial begin
  hs = 1'b1;
  vs = 1'b1;
end

reg [7:0] color_ram[0:767];

// ---------------------------------------------------------------------------
// Character-cell renderer
//
// Runs free of the display scan, filling `vram` one pixel at a time. px/py walk
// the 256x192 picture; each pixel needs the cell's attribute, its pattern byte
// (character generator in text mode, RAM in graphics mode) and one bit of it.
// ---------------------------------------------------------------------------
reg [2:0] state;
reg [7:0] px, py;

wire [9:0] cell_idx = { py[7:3], px[7:3] };          // (py/8)*32 + (px/8)
wire [15:0] gfx_base = 16'h0900 + {3'd0, screen_mode[3:0], 9'd0};  // $900 + $200*n
wire graphics_en   = screen_mode[6];
wire graphics_only = screen_mode[7];

// In mixed mode bm2 alternates whole frames between the text page and the
// bitmap; whether real hardware overlays them instead is unconfirmed.
reg mix_phase;
(* altera_attribute = "-name SYNCHRONIZER_IDENTIFICATION FORCED_IF_ASYNCHRONOUS" *)
reg mix_phase_meta, mix_phase_sys;
reg blink_meta, blink_sys;
wire show_gfx = graphics_en & (graphics_only | mix_phase_sys);

reg [7:0] color;
reg [7:0] pattern;

// Screen reverse rotates the whole attribute byte by a nibble, so it swaps the
// two blink flags along with the two colours. [bm2 depend.c:240]
wire [7:0] attr = inverted ? { color[3:0], color[7:4] } : color;

// Blink: bit 3 blanks the foreground on one phase, bit 7 blanks the background
// on the other. [bm2 depend.c:150-160]
reg blink;

always @(posedge clk_sys) begin
  mix_phase_meta <= mix_phase;
  mix_phase_sys  <= mix_phase_meta;
  blink_meta     <= blink;
  blink_sys      <= blink_meta;
end

wire [7:0] attr_b = blink_sys ? (attr[3] ? (attr & 8'h70) : (attr & 8'h77))
                          : (attr[7] ? (attr & 8'h07) : (attr & 8'h77));
wire [2:0] fg = attr_b[2:0];
wire [2:0] bg = attr_b[6:4];

wire render_bit = show_gfx ? pattern[3'd7-px[2:0]] : char_data[3'd7-px[2:0]];
wire [2:0] render_color = color_board ? (render_bit ? fg : bg)
                                      : (render_bit ?
                                          (inverted ? 3'b000 : 3'b111) :
                                          (inverted ? 3'b111 : 3'b000));

wire in_picture = (hcount >= X_OFF) && (hcount < X_OFF + 256)
               && (vcount >= Y_OFF) && (vcount < Y_OFF + 192);
wire [8:0] picture_x = hcount - (BORDER ? 9'd32 : 9'd0);
wire [8:0] picture_y = vcount - (BORDER ? 9'd24 : 9'd0);
wire [15:0] scan_addr = in_picture
                        ? {picture_y[7:0], picture_x[7:0]} : 16'd0;
wire [2:0] vram_data;

video_framebuffer framebuffer(
  .wr_clk(clk_sys),
  .wr_en(state == 3'd5),
  .wr_addr({py, px}),
  .wr_data(render_color),
  .rd_clk(clk_vid),
  .rd_addr(scan_addr),
  .rd_data(vram_data)
);

always @(posedge clk_sys) begin
  color <= color_ram[cell_idx];
  if (color_ram_wr) color_ram[color_ram_addr] <= charcolor;
end

always @(posedge clk_sys) begin
  case (state)
    3'd0: begin
      // Graphics mode reads the bitmap directly; text mode reads the character
      // code and looks it up in the generator after the RAM read completes.
      ram_addr <= show_gfx ? (gfx_base + {3'd0, py[7:3], 8'd0} + {8'd0, py[2:0], 5'd0} + {11'd0, px[7:3]})
                           : (16'h100 + { 6'd0, cell_idx });
      state <= 3'd1;
    end
    3'd1: begin
      // Port B of dpram registers both its address and output.
      state <= 3'd2;
    end
    3'd2: begin
      // Wait for the second system-RAM read stage. Without this cycle, px=0
      // of every cell uses the preceding character code and loses bit 7 of
      // glyphs such as A, M, and V.
      state <= 3'd3;
    end
    3'd3: begin
      char_addr <= { ram_data, py[2:0] };
      pattern <= ram_data;
      state <= 3'd4;
    end
    3'd4: begin
      // Wait for the synchronous character-ROM read port.
      state <= 3'd5;
    end
    3'd5: begin
      px <= px + 8'd1;
      if (px == 255) begin
        py <= py + 8'd1;
        if (py == 8'd191) py <= 8'd0;
      end
      state <= 3'd0;
    end
    default: state <= 3'd0;
  endcase
end

// ---------------------------------------------------------------------------
// Display scan
// ---------------------------------------------------------------------------
reg [5:0] blink_div;
reg pixel_subphase = 1'b0;
(* altera_attribute = "-name SYNCHRONIZER_IDENTIFICATION FORCED_IF_ASYNCHRONOUS" *)
reg [2:0] border_color_meta, border_color_vid;

always @(posedge clk_vid) begin

  border_color_meta <= border_color;
  border_color_vid  <= border_color_meta;
  pixel_subphase <= ~pixel_subphase;
  if (!BORDER || pixel_subphase) begin

  frame <= 1'b0;
  ce_pix <= ~ce_pix;

  if (ce_pix) begin

    // The framebuffer has read scan_addr for the current hcount by now in both
    // BORDER modes (one clk_vid edge after the hcount update without it, three
    // with it). Sampling it on the ~ce_pix step instead caught the previous
    // pixel when BORDER=0, and its border test then disagreed with the data.
    // RGB written here is shown during the next pixel, so the sync and blank
    // outputs are delayed by one step to match.
    if (~(hb_i|vb_i)) begin
      red <= (in_picture ? vram_data[2] : border_color_vid[2]) ? 8'hff : 8'd0;
      green <= (in_picture ? vram_data[1] : border_color_vid[1]) ? 8'hff : 8'd0;
      blue <= (in_picture ? vram_data[0] : border_color_vid[0]) ? 8'hff : 8'd0;
    end
    hs <= hs_i;
    vs <= vs_i;
    hb <= hb_i;
    vb <= vb_i;

    hcount <= hcount + 9'd1;
    case (hcount)
      ACTIVE_W-1: hb_i <= 1'b1;
      ACTIVE_W+H_FP-1: hs_i <= 1'b0;
      ACTIVE_W+H_FP+H_SYNC-1: hs_i <= 1'b1;
      H_TOTAL-1: begin
        vcount <= vcount + 9'd1;
        hcount <= 9'b0;
        hb_i <= 1'b0;
        case (vcount)
          ACTIVE_H-1: vb_i <= 1'b1;
          ACTIVE_H+V_FP-1: vs_i <= 1'b0;
          ACTIVE_H+V_FP+V_SYNC-1: vs_i <= 1'b1;
          V_TOTAL-1: begin
            vcount <= 9'd0;
            vb_i <= 1'b0;
            frame <= 1'b1;
            mix_phase <= ~mix_phase;
            // ~1 Hz attribute blink: flip every 30 frames.
            blink_div <= blink_div + 6'd1;
            if (blink_div == 6'd29) begin
              blink_div <= 6'd0;
              blink <= ~blink;
            end
          end
        endcase
      end
    endcase

  end

  end
end

endmodule

module video_framebuffer(
  input         wr_clk,
  input         wr_en,
  input  [15:0] wr_addr,
  input   [2:0] wr_data,
  input         rd_clk,
  input  [15:0] rd_addr,
  output reg [2:0] rd_data
);

(* ramstyle = "M10K, no_rw_check" *) reg [2:0] mem[0:49151];

always @(posedge wr_clk) begin
  if (wr_en) mem[wr_addr] <= wr_data;
end

always @(posedge rd_clk) begin
  rd_data <= mem[rd_addr];
end

endmodule
