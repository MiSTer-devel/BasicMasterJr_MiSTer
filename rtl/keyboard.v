
module keyboard(
  input reset,
  input clk_sys,
  input [10:0] ps2_key,
  input swap_alt_win,     // OSD Swap Alt/Win keys: Win types the machine's Kana Shift, Alt nothing
  input us_layout,        // OSD Keyboard layout: 0 JIS (by position), 1 US (by legend)
  input [11:0] joy,       // gamepad buttons, hps_io joystick_0[11:0]
  input [95:0] pad_map,   // a key per button, from tape_hint (see below)
  input [3:0] kb_col,
  output reg [3:0] kb_key,
  output reg [3:0] kb_mod,
  output reg break_key,   // active high; core.v turns this into an NMI
  output reg status
);

// $EEC0 read bits 7:4, all ACTIVE LOW:
//   [0] Normal (leaves kana mode)  [1] Shift  [2] Kana Shift  [3] Kana

reg [3:0] keys[15:0];
reg [3:0] mods;
reg brk;

// Gamepad. pad_map holds one byte per joy bit, [8*i+7:8*i] for joy[i]:
//   [7] mapped  [6] also hold Shift  [5:2] column  [1:0] row
// Columns 0-12 are the matrix, 13 the modifiers (row = the kb_mod bit) and
// 14 BREAK; 15 is a button mapped to nothing. A held button presses its key
// as if typed, on top of the PS/2 keyboard.
reg [63:0] pad_keys;
reg [3:0] pad_mods;
reg pad_brk;
integer i;

always @* begin
  pad_keys = 64'd0;
  pad_mods = 4'd0;
  pad_brk = 1'b0;
  for (i = 0; i < 12; i = i + 1)
    if (joy[i] && pad_map[8*i+7]) begin
      if (pad_map[8*i+5 -: 4] < 4'd13) pad_keys[{pad_map[8*i+5 -: 4], pad_map[8*i+1 -: 2]}] = 1'b1;
      else if (pad_map[8*i+5 -: 4] == 4'd13) pad_mods[pad_map[8*i+1 -: 2]] = 1'b1;
      else if (pad_map[8*i+5 -: 4] == 4'd14) pad_brk = 1'b1;
      if (pad_map[8*i+6]) pad_mods[1] = 1'b1;
    end
end

// Keys that need the machine's Shift set a particular way. key_map gives the
// machine's key for {E0, code} with PC Shift up or down, as {hit, Shift,
// column, row} (column 15: the machine has no such character).
//   Both layouts: the arrows are the cursor keys (Shift with @ [ ^ yen, the
//   keys the arrows are printed on) and the keypad types digits.
//   US layout: each key types what is printed on it. Letters lose Shift (the
//   machine has no lower case), Shift+2 is @ without Shift, ' is Shift+7.
// Keys not in the table (in JIS, all but the arrows and keypad; in US the
// modifiers, Space, Return, BS and Esc) go through the case statement below.
function [7:0] t(input [3:0] col, input [1:0] row, input sh);
  t = {1'b1, sh, col, row};
endfunction

function [7:0] key_map(input [8:0] k, input sh, input us);
begin
  case (k)
    9'h175: key_map = t(10, 2, 1);                    // cursor up
    9'h172: key_map = t(11, 2, 1);                    // cursor down
    9'h174: key_map = t(11, 3, 1);                    // cursor right
    9'h16b: key_map = t(12, 3, 1);                    // cursor left

    9'h070: key_map = t(9, 3, 0);  9'h069: key_map = t(0, 3, 0);  9'h072: key_map = t(1, 3, 0);
    9'h07a: key_map = t(2, 3, 0);  9'h06b: key_map = t(3, 3, 0);  9'h073: key_map = t(4, 3, 0);
    9'h074: key_map = t(5, 3, 0);  9'h06c: key_map = t(6, 3, 0);  9'h075: key_map = t(7, 3, 0);
    9'h07d: key_map = t(8, 3, 0);  9'h071: key_map = t(8, 0, 0);  9'h14a: key_map = t(9, 0, 0);
    9'h079: key_map = t(9, 1, 1);  9'h07b: key_map = t(10, 3, 0); 9'h07c: key_map = t(10, 1, 1);
    default: key_map = 8'd0;
  endcase
  if (us) case (k)
    9'h01a: key_map = t(0, 0, 0);  9'h01c: key_map = t(0, 1, 0);  9'h015: key_map = t(0, 2, 0);
    9'h022: key_map = t(1, 0, 0);  9'h01b: key_map = t(1, 1, 0);  9'h01d: key_map = t(1, 2, 0);
    9'h021: key_map = t(2, 0, 0);  9'h023: key_map = t(2, 1, 0);  9'h024: key_map = t(2, 2, 0);
    9'h02a: key_map = t(3, 0, 0);  9'h02b: key_map = t(3, 1, 0);  9'h02d: key_map = t(3, 2, 0);
    9'h032: key_map = t(4, 0, 0);  9'h034: key_map = t(4, 1, 0);  9'h02c: key_map = t(4, 2, 0);
    9'h031: key_map = t(5, 0, 0);  9'h033: key_map = t(5, 1, 0);  9'h035: key_map = t(5, 2, 0);
    9'h03a: key_map = t(6, 0, 0);  9'h03b: key_map = t(6, 1, 0);  9'h03c: key_map = t(6, 2, 0);
    9'h042: key_map = t(7, 1, 0);  9'h043: key_map = t(7, 2, 0);
    9'h04b: key_map = t(8, 1, 0);  9'h044: key_map = t(8, 2, 0);  9'h04d: key_map = t(9, 2, 0);

    9'h016: key_map = sh ? t(0, 3, 1)  : t(0, 3, 0);   // 1 !
    9'h01e: key_map = sh ? t(10, 2, 0) : t(1, 3, 0);   // 2 @
    9'h026: key_map = sh ? t(2, 3, 1)  : t(2, 3, 0);   // 3 #
    9'h025: key_map = sh ? t(3, 3, 1)  : t(3, 3, 0);   // 4 $
    9'h02e: key_map = sh ? t(4, 3, 1)  : t(4, 3, 0);   // 5 %
    9'h036: key_map = sh ? t(11, 3, 0) : t(5, 3, 0);   // 6 ^
    9'h03d: key_map = sh ? t(5, 3, 1)  : t(6, 3, 0);   // 7 &
    9'h03e: key_map = sh ? t(10, 1, 1) : t(7, 3, 0);   // 8 *
    9'h046: key_map = sh ? t(7, 3, 1)  : t(8, 3, 0);   // 9 (
    9'h045: key_map = sh ? t(8, 3, 1)  : t(9, 3, 0);   // 0 )
    9'h04e: key_map = sh ? t(10, 0, 1) : t(10, 3, 0);  // - _
    9'h055: key_map = sh ? t(9, 1, 1)  : t(10, 3, 1);  // = +
    9'h054: key_map = sh ? t(15, 0, 0) : t(11, 2, 0);  // [ {
    9'h05b: key_map = sh ? t(15, 0, 0) : t(11, 1, 0);  // ] }
    9'h05d: key_map = sh ? t(15, 0, 0) : t(12, 3, 0);  // \ |  (\ is yen)
    9'h04c: key_map = sh ? t(10, 1, 0) : t(9, 1, 0);   // ; :
    9'h052: key_map = sh ? t(1, 3, 1)  : t(6, 3, 1);   // ' "
    9'h041: key_map = t(7, 0, sh);                     // , <
    9'h049: key_map = t(8, 0, sh);                     // . >
    9'h04a: key_map = t(9, 0, sh);                     // / ?
    9'h00e: key_map = t(15, 0, 0);                     // ` ~

    default: ;
  endcase
end
endfunction

wire [7:0] km_now = key_map(ps2_key[8:0], ~mods[1], us_layout);  // with the PC's Shift as it is
wire [7:0] km_0   = key_map(ps2_key[8:0], 1'b0, us_layout);
wire [7:0] km_1   = key_map(ps2_key[8:0], 1'b1, us_layout);

// The machine's Shift while a table key is held: what that key needs, not
// the PC's. The last key pressed decides until it is released.
reg       ovr;
reg       ovr_sh;
reg [8:0] ovr_code;
wire      jr_shift_n = ovr ? ~ovr_sh : mods[1];

// Alt (11, or E0 11 on the right) is the machine's Kana Shift. With the swap,
// the Win keys (E0 1F, E0 27) take that job and Alt maps to nothing.
wire win_key = ps2_key[8] && (ps2_key[7:0] == 8'h1f || ps2_key[7:0] == 8'h27);
wire [7:0] code = !swap_alt_win        ? ps2_key[7:0]
                : win_key              ? 8'h11
                : ps2_key[7:0] == 8'h11 ? 8'h00
                :                        ps2_key[7:0];

always @(posedge clk_sys) begin
  reg toggle;

  toggle <= ps2_key[10];
  if (toggle != ps2_key[10]) status <= ps2_key[9];

  kb_key <= keys[kb_col] & ~pad_keys[{kb_col, 2'b00} +: 4];
  kb_mod <= {mods[3:2], jr_shift_n, mods[0]} & ~pad_mods;
  break_key <= brk | pad_brk;

  if (reset) begin
    keys[0] <= 4'b1111;
    keys[1] <= 4'b1111;
    keys[2] <= 4'b1111;
    keys[3] <= 4'b1111;
    keys[4] <= 4'b1111;
    keys[5] <= 4'b1111;
    keys[6] <= 4'b1111;
    keys[7] <= 4'b1111;
    keys[8] <= 4'b1111;
    keys[9] <= 4'b1111;
    keys[10] <= 4'b1111;
    keys[11] <= 4'b1111;
    keys[12] <= 4'b1111;
    keys[13] <= 4'b1111;
    keys[14] <= 4'b1111;
    keys[15] <= 4'b1111;
    mods <= 4'b1111;
    brk <= 1'b0;
    ovr <= 1'b0;
  end
  else if (km_now[7]) begin

    // A key from key_map. A release lets go of both keys it could have
    // pressed, in case Shift changed while it was down.
    if (status) begin
      if (km_now[5:2] != 4'd15) keys[km_now[5:2]][km_now[1:0]] <= 1'b0;
      ovr <= 1'b1;
      ovr_sh <= km_now[6];
      ovr_code <= ps2_key[8:0];
    end
    else begin
      if (km_0[5:2] != 4'd15) keys[km_0[5:2]][km_0[1:0]] <= 1'b1;
      if (km_1[5:2] != 4'd15) keys[km_1[5:2]][km_1[1:0]] <= 1'b1;
      if (ovr_code == ps2_key[8:0]) ovr <= 1'b0;
    end

  end
  else begin

    case (code)

      8'h12,
      8'h59: mods[1] <= ~status;  // Shift
      8'h14: mods[0] <= ~status;  // Left Ctrl  -> Normal
      8'h11: mods[2] <= ~status;  // Alt (or Win, swapped) -> Kana Shift
      8'h58: mods[3] <= ~status;  // Caps Lock  -> Kana

      8'h76: brk <= status;      // Esc -> BREAK

      8'h1a: keys[0][0] <= ~status; // z
      8'h1c: keys[0][1] <= ~status; // a
      8'h15: keys[0][2] <= ~status; // q
      8'h16: keys[0][3] <= ~status; // 1

      8'h22: keys[1][0] <= ~status; // x
      8'h1b: keys[1][1] <= ~status; // s
      8'h1d: keys[1][2] <= ~status; // w
      8'h1e: keys[1][3] <= ~status; // 2

      8'h21: keys[2][0] <= ~status; // c
      8'h23: keys[2][1] <= ~status; // d
      8'h24: keys[2][2] <= ~status; // e
      8'h26: keys[2][3] <= ~status; // 3

      8'h2a: keys[3][0] <= ~status; // v
      8'h2b: keys[3][1] <= ~status; // f
      8'h2d: keys[3][2] <= ~status; // r
      8'h25: keys[3][3] <= ~status; // 4

      8'h32: keys[4][0] <= ~status; // b
      8'h34: keys[4][1] <= ~status; // g
      8'h2c: keys[4][2] <= ~status; // t
      8'h2e: keys[4][3] <= ~status; // 5

      8'h31: keys[5][0] <= ~status; // n
      8'h33: keys[5][1] <= ~status; // h
      8'h35: keys[5][2] <= ~status; // y
      8'h36: keys[5][3] <= ~status; // 6

      8'h3a: keys[6][0] <= ~status; // m
      8'h3b: keys[6][1] <= ~status; // j
      8'h3c: keys[6][2] <= ~status; // u
      8'h3d: keys[6][3] <= ~status; // 7

      8'h41: keys[7][0] <= ~status; // ,
      8'h42: keys[7][1] <= ~status; // k
      8'h43: keys[7][2] <= ~status; // i
      8'h3e: keys[7][3] <= ~status; // 8

      8'h49: keys[8][0] <= ~status; // .
      8'h4b: keys[8][1] <= ~status; // l
      8'h44: keys[8][2] <= ~status; // o
      8'h46: keys[8][3] <= ~status; // 9

      8'h4a: keys[9][0] <= ~status; // /
      8'h4c: keys[9][1] <= ~status; // ; +
      8'h4d: keys[9][2] <= ~status; // p
      8'h45: keys[9][3] <= ~status; // 0

      // JIS: the punctuation keys where a Japanese keyboard has them, which
      // is also where the machine has them.
      8'h51: keys[10][0] <= ~status; // _   (ro key, \ _)
      8'h52: keys[10][1] <= ~status; // : *
      8'h54: keys[10][2] <= ~status; // @
      8'h4e: keys[10][3] <= ~status; // - =

      8'h29: keys[11][0] <= ~status; // space
      8'h5d: keys[11][1] <= ~status; // ]
      8'h5b: keys[11][2] <= ~status; // [
      8'h55: keys[11][3] <= ~status; // ^

      8'h5a: keys[12][1] <= ~status; // enter
      8'h66: keys[12][2] <= ~status; // backspace
      8'h6a: keys[12][3] <= ~status; // yen

      default: ;

    endcase

  end

end


endmodule
