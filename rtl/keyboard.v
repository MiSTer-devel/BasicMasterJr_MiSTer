
module keyboard(
  input reset,
  input clk_sys,
  input [10:0] ps2_key,
  input swap_alt_win,     // OSD Swap Alt/Win keys: Win types the machine's Kana Shift, Alt nothing
  input [3:0] kb_col,
  output reg [3:0] kb_key,
  output reg [3:0] kb_mod,
  output reg break_key,   // active high; core.v turns this into an NMI
  output reg status
);

// $EEC0 read bits 7:4, all ACTIVE LOW:
//   [0] Normal (leaves kana mode)  [1] Shift  [2] Kana Shift  [3] Kana

reg [3:0] keys[15:0];

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

  kb_key <= keys[kb_col];

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
    kb_mod <= 4'b1111;
    break_key <= 1'b0;
  end
  else begin

    case (code)

      8'h12,
      8'h59: kb_mod[1] <= ~status;  // Shift
      8'h14: kb_mod[0] <= ~status;  // Left Ctrl  -> Normal
      8'h11: kb_mod[2] <= ~status;  // Alt (or Win, swapped) -> Kana Shift
      8'h58: kb_mod[3] <= ~status;  // Caps Lock  -> Kana

      8'h76: break_key <= status;   // Esc -> BREAK

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

      8'h0e: keys[10][0] <= ~status; // _   (backtick)
      8'h52: keys[10][1] <= ~status; // : * (apostrophe)
      8'h4e: keys[10][3] <= ~status; // - = (minus)

      8'h29: keys[11][0] <= ~status; // space
      8'h5b: keys[11][1] <= ~status; // ]

      8'h5a: keys[12][1] <= ~status; // enter
      8'h66: keys[12][2] <= ~status; // backspace

      // The four cursor keys ARE the @ / [ / ^ / yen keys on this machine --
      // the arrows are their second function -- so one matrix bit each, and
      // the PS/2 arrow and numeric-keypad codes are the same byte.
      8'h75: keys[10][2] <= ~status; // @ / up
      8'h72: keys[11][2] <= ~status; // [ / down
      8'h74: keys[11][3] <= ~status; // ^ / right
      8'h6b: keys[12][3] <= ~status; // yen / left
      8'h5d: keys[12][3] <= ~status; // yen (JP backslash key)
      default: ;

    endcase

  end

end


endmodule
