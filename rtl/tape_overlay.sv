// tape_overlay.sv - tape status bar over the picture (OSD "Tape overlay").
//
// Ported from the Sharp X1 core's rtl/x1_tape_overlay.sv (GPL-2.0), the
// reference for the MiSTer tape-core conventions. While the tape plays, the bottom-left
// corner shows
//
//     TAPE > 0:09/ 0:24 x32
//     [=========---------]
//
// elapsed/total time at the real 300 baud, the turbo factor while turbo is on,
// and a 64-step progress bar. A Jr tape image is the demodulated byte stream at
// a fixed 300 baud, 11 bit-times a byte, so the times are exact: a byte is 11
// bit-times of 1/300 s. tape_status (clk_sys) packs everything into one word
// and hands it to tape_overlay (clk_vid) with a toggle handshake. The overlay
// is mixed in after the machine and before video_mixer; it never changes the
// machine.
//
// While the deck is stopped, the same corner shows what to type next
// (tape_hint): the load command for the tape's first file, then the start
// command once the tape has played to the end, with a note from the tape list
// (boot1.rom) if it has one. Text is drawn with the machine's own character
// ROM.

// Special character codes in hint and status text (the ROM has block graphics
// there; the overlay draws its own glyphs instead).
`define TH_RETURN 8'h01
`define TH_SPACE  8'h02
`define TH_PLAY   8'h03
`define TH_NEWLINE 8'h0A   // hint text only: continue on the second line

// tape_hint - what to type next, read from the tape's block headers.
//
// The image is parsed as hps_io writes it: each block is a $FF leader, $01,
// a 12-byte header (kind, ascii block, 6-char name, ".B"/".S", binary block,
// size), the load address, a header checksum, `size` data bytes (0 = 256),
// a data checksum and one trailing byte. The tape says nothing about where a
// program starts. Almost every machine-code tape starts where its first block
// loads, so the hint uses that unless the tape list (below) says otherwise, or
// the first byte there is not an instruction a program starts with; then it
// says the start is unknown.
//
// The first file is A. The first later header with another kind or name is B:
// Tiny Galaxy and MISSILE FIGHT are a machine-code file followed by a BASIC
// one. Files after B are ignored. With the deck stopped:
//
//   at the start of the tape     load A      TYPE MON <ret> L MAZY <spc>
//   between A and B              load B      TYPE E <ret> LOAD GALAXY <ret>
//   at the end of the tape       start it    TYPE G 1000 <spc> / TYPE RUN <ret>
//
// A BASIC program that uses the graphics page needs CALL $E37E before its
// LOAD; the hint then takes two lines: TYPE CALL $E37E <ret> / THEN LOAD WINE <ret>.
//
// The start hint goes away when its last key (Space or Return) is pressed.
// After a recording the tape also sits at its end, so the start hint stays
// off until the tape is rewound (which then shows the load hint).
//
// Tape list. Main loads games/BasicMasterJr/boot1.rom at core start; it is a
// text file, one line per program:
//
//   # comment
//   NAME  LOAD  START  [END]  [| note]
//   CAR   2000  2500          | S START  N M STEER
//
// NAME is the tape's 6-character name, LOAD and END the first and last
// address of the file (END optional, to tell versions apart), START the
// address to G to; '-' for LOAD matches any address, '-' for START keeps the
// load address. The note, up to 22 characters, is the start hint's second
// line. The line for the file the start hint is about (B if there is one,
// else A) is looked up by scanning the text whenever that file changes; the
// first matching line wins.

module tape_hint (
  input  logic         clk,
  input  logic         wr,          // tape image byte written (download or recording)
  input  logic         rec,         // ... by the recorder
  input  logic  [24:0] addr,
  input  logic   [7:0] data,
  input  logic         list_wr,     // tape list byte written (boot1.rom)
  input  logic  [24:0] list_addr,
  input  logic   [7:0] list_data,
  input  logic  [24:0] position,    // cassette byte pointer
  input  logic  [24:0] length,      // bytes on the tape
  input  logic         playing,
  input  logic  [10:0] ps2_key,
  output logic         show,
  output logic   [4:0] len,         // width of the wider line
  output logic         two,         // a second line (CALL $E37E, or a note)
  output logic [351:0] text         // 2 x 22 characters, the first in [351:344]
);
  localparam logic [1:0] P_SEEK = 2'd0, P_HDR = 2'd1, P_SKIP = 2'd2;
  localparam int SLOTS = 101;
  localparam int LIST_AW = 13;      // 8 KiB of tape list

  logic [1:0]  pstate;
  logic [3:0]  hidx;
  logic [7:0]  hdr [0:14];
  logic [8:0]  skip;
  logic [24:0] mark;
  // File A and file B.
  logic        a_valid, a_bin, b_valid, b_bin;
  logic [47:0] a_name, b_name;
  logic [15:0] a_addr, b_addr, a_end, b_end;
  logic [7:0]  a_first, b_first;  // first data byte (the would-be entry)
  logic [1:0]  first_of;          // 1: next data byte is A's first, 2: B's
  logic [24:0] a_last, b_off;     // A's last block and B's first, as $01 offsets
  logic [24:0] z_last;            // the image's last block
  // Each file's first end-of-file block. A tape may hold a second copy of a
  // file (LIFE2, Jumping Paru-san); the loader stops at the first copy's end.
  logic        a_eof_ok, b_eof_ok;
  logic [24:0] a_eof, b_eof;
  logic        need_call;         // a BASIC block mentions $EFE0 (see below)
  logic [39:0] tail;              // the last five BASIC text bytes

  wire  [7:0]  kind = hdr[0];
  wire  [47:0] hname = {hdr[2], hdr[3], hdr[4], hdr[5], hdr[6], hdr[7]};
  wire  [15:0] haddr = {hdr[12], hdr[13]};
  wire  [7:0]  up = data >= 8'h61 && data <= 8'h7A ? data - 8'h20 : data;
  wire  [8:0]  size = hdr[11] != 8'd0 ? {1'b0, hdr[11]} : kind == 8'd0 ? 9'd0 : 9'd256;
  wire  [15:0] hend = haddr + {7'd0, size} - 16'd1;

  initial begin
    pstate = P_SEEK; hidx = 0; skip = 0; mark = 0;
    a_valid = 0; a_bin = 0; b_valid = 0; b_bin = 0;
    a_name = 0; b_name = 0; a_addr = 0; b_addr = 0; a_end = 0; b_end = 0;
    a_first = 0; b_first = 0; first_of = 0; a_last = 0; b_off = 0; z_last = 0;
    a_eof_ok = 0; b_eof_ok = 0; a_eof = 0; b_eof = 0;
    need_call = 0; tail = 0;
  end

  always_ff @(posedge clk) begin
    if (wr) begin
      if (addr == 25'd0) begin
        a_valid <= 0; b_valid <= 0; need_call <= 0; tail <= 0; first_of <= 0;
        a_eof_ok <= 0; b_eof_ok <= 0;
        pstate <= data == 8'h01 ? P_HDR : P_SEEK;
        hidx <= 0; mark <= 0;
      end else case (pstate)
        P_SEEK: if (data == 8'h01) begin pstate <= P_HDR; hidx <= 0; mark <= addr; end
        P_HDR: begin
          hdr[hidx] <= data;
          hidx <= hidx + 4'd1;
          if (hidx == 4'd14) begin
            // hdr[14] (the header checksum) is this byte; the rest are in.
            skip <= size + 9'd2;
            pstate <= P_SKIP;
            z_last <= mark;
            if (kind == 8'd0) begin
              if (a_valid && !b_valid && !a_eof_ok) begin a_eof_ok <= 1; a_eof <= mark; end
              if (b_valid && !b_eof_ok) begin b_eof_ok <= 1; b_eof <= mark; end
            end
            if (!a_valid) begin
              if (kind != 8'd0) begin
                a_valid <= 1; a_bin <= kind == 8'h01; a_name <= hname;
                a_addr <= haddr; a_end <= hend; a_last <= mark; first_of <= 2'd1;
              end
            end else if (!b_valid) begin
              if (kind != 8'd0 && ((kind == 8'h01) != a_bin || hname != a_name)) begin
                b_valid <= 1; b_bin <= kind == 8'h01; b_name <= hname;
                b_addr <= haddr; b_end <= hend; b_off <= mark; first_of <= 2'd2;
              end else begin
                a_last <= mark;
                if (kind != 8'd0) a_end <= hend;
              end
            end else if (kind != 8'd0 && (kind == 8'h01) == b_bin && hname == b_name)
              b_end <= hend;
          end
        end
        P_SKIP: begin
          skip <= skip - 9'd1;
          if (first_of == 2'd1) a_first <= data;
          if (first_of == 2'd2) b_first <= data;
          first_of <= 0;
          // BASIC text that switches to graphics ($EFE0 = 61408) needs
          // CALL $E37E first: it moves the program from $0900, the first
          // graphics page, up to $2100. Without it the program draws over
          // its own text (SYNTAX ERROR or a crash). Holds for every BASIC
          // tape we have whose instructions ask for the call, and none else.
          if (kind == 8'h10) begin
            tail <= {tail[31:0], up};
            if ({tail[23:0], up} == "EFE0" || {tail[31:0], up} == "61408")
              need_call <= 1;
          end
          if (skip == 9'd1) pstate <= P_SEEK;
        end
        default: pstate <= P_SEEK;
      endcase
    end
  end

  // The file the start hint is about.
  wire        run_bin = b_valid ? b_bin : a_bin;
  wire [47:0] r_name  = b_valid ? b_name : a_name;
  wire [15:0] r_addr  = b_valid ? b_addr : a_addr;
  wire [15:0] r_end   = b_valid ? b_end : a_end;
  wire  [7:0] r_first = b_valid ? b_first : a_first;

  // ---- tape list -----------------------------------------------------------
  logic [7:0] list [0:(1 << LIST_AW) - 1];
  logic [LIST_AW:0] list_len;
  logic [7:0] lq;
  logic [LIST_AW:0] s_addr;
  initial list_len = 0;

  always_ff @(posedge clk) begin
    if (list_wr && list_addr < 25'(1 << LIST_AW)) begin
      list[list_addr[LIST_AW-1:0]] <= list_data;
      list_len <= list_addr[LIST_AW:0] + 1'd1;
    end
    lq <= list[s_addr[LIST_AW-1:0]];
  end

  // Scanner: rescans whenever the key or the list changes.
  localparam logic [1:0] L_FIELDS = 2'd0, L_NOTE = 2'd1, L_SKIP = 2'd2;
  wire [95:0] key = {list_len, r_name, r_addr, r_end, a_valid, b_valid};
  logic [95:0] last_key;
  logic        busy, rdv;
  logic [1:0]  lstate;
  logic [2:0]  fcnt, ncnt;
  logic        infield, lbad, load_any, start_keep;
  logic [47:0] lname;
  logic [15:0] lload, lstart, lend;
  logic [175:0] lnote;
  logic [4:0]  ncount, nlast;
  // The match.
  logic        found, f_keep;
  logic [15:0] f_start;
  logic [175:0] f_note;
  logic [4:0]  f_nlen;

  initial begin
    last_key = 0; busy = 0; rdv = 0; s_addr = 0; lstate = L_FIELDS;
    fcnt = 0; ncnt = 0; infield = 0; lbad = 0; load_any = 0; start_keep = 0;
    lname = {6{8'h20}}; lload = 0; lstart = 0; lend = 0; lnote = 0; ncount = 0; nlast = 0;
    found = 0; f_keep = 0; f_start = 0; f_note = 0; f_nlen = 0;
  end

  function automatic logic [4:0] hexval(input logic [7:0] c);
    if (c >= "0" && c <= "9") return {1'b1, 4'(c - "0")};
    if (c >= "A" && c <= "F") return {1'b1, 4'(c - "A" + 8'd10)};
    return 5'd0;
  endfunction

  wire        eof = busy && !rdv && s_addr >= list_len;
  wire        lgo = rdv || eof;                  // a character to scan
  wire  [7:0] c   = eof ? 8'h0A : lq;            // a final newline ends the last line
  wire  [7:0] uc  = c >= 8'h61 && c <= 8'h7A ? c - 8'h20 : c;
  wire        ws  = c == 8'h20 || c == 8'h09 || c == 8'h0D;
  wire  [2:0] fi  = infield ? fcnt - 3'd1 : fcnt; // field this character is in
  wire  [4:0] hv  = hexval(uc);
  wire        match = !lbad && fcnt >= 3'd3 && lname == r_name &&
                      (load_any || lload == r_addr) && (fcnt < 3'd4 || lend == r_end);

  always_ff @(posedge clk) begin
    rdv <= 0;
    if (key != last_key) begin
      last_key <= key;
      busy <= a_valid; s_addr <= 0; found <= 0;
      lstate <= L_FIELDS; fcnt <= 0; ncnt <= 0; infield <= 0; lbad <= 0;
      load_any <= 0; start_keep <= 0; lname <= {6{8'h20}}; ncount <= 0; nlast <= 0; lnote <= {22{8'h20}};
    end else if (busy) begin
      if (s_addr < list_len) begin s_addr <= s_addr + 1'd1; rdv <= 1; end
      if (eof) busy <= 0;
      if (lgo) begin
        if (c == 8'h0A) begin
          if (lstate != L_SKIP && match && !found) begin
            found <= 1; f_keep <= start_keep; f_start <= lstart;
            f_note <= lnote; f_nlen <= nlast;
          end
          lstate <= L_FIELDS; fcnt <= 0; ncnt <= 0; infield <= 0; lbad <= 0;
          load_any <= 0; start_keep <= 0; lname <= {6{8'h20}}; ncount <= 0; nlast <= 0; lnote <= {22{8'h20}};
        end else case (lstate)
          L_FIELDS:
            if (ws) infield <= 0;
            else if (c == "|") lstate <= L_NOTE;
            else if ((c == "#" || c == ";") && fcnt == 3'd0 && !infield) lstate <= L_SKIP;
            else begin
              if (!infield) begin infield <= 1; fcnt <= fcnt + 3'd1; end
              case (fi)
                3'd0: if (ncnt < 3'd6) begin lname[47 - 8 * ncnt -: 8] <= uc; ncnt <= ncnt + 3'd1; end
                      else lbad <= 1;
                3'd1: if (c == "-") load_any <= 1; else if (hv[4]) lload <= {lload[11:0], hv[3:0]}; else lbad <= 1;
                3'd2: if (c == "-") start_keep <= 1; else if (hv[4]) lstart <= {lstart[11:0], hv[3:0]}; else lbad <= 1;
                3'd3: if (hv[4]) lend <= {lend[11:0], hv[3:0]}; else lbad <= 1;
                default: lbad <= 1;
              endcase
            end
          L_NOTE:
            // Printable ASCII only (the machine's ROM has no lower case or
            // UTF-8); leading blanks dropped, trailing ones not counted.
            if (c != 8'h0D && (ncount != 5'd0 || !ws) && ncount < 5'd22 &&
                c >= 8'h09 && c < 8'h7F && (c >= 8'h20 || c == 8'h09)) begin
              lnote[175 - 8 * ncount -: 8] <= c == 8'h09 ? 8'h20 : uc;
              ncount <= ncount + 5'd1;
              if (!ws) nlast <= ncount + 5'd1;
            end
          default: ;
        endcase
      end
    end
  end

  // Instructions a machine-code program commonly starts with: SEI, CLI, LDS,
  // JSR, JMP, LDX, PSHA/B, LDAA/B, CLRA/B, CLR. Every machine-code tape we
  // have that starts at its load address begins with one of these; the ones
  // that don't (3D Car Race, Crazy Fly, Alien Streets) begin with data.
  function automatic logic plausible(input logic [7:0] op);
    case (op)
      8'h0F, 8'h0E, 8'h8E, 8'hBE, 8'hBD, 8'h7E, 8'hCE, 8'hFE,
      8'h36, 8'h37, 8'h86, 8'hC6, 8'hB6, 8'hF6, 8'h4F, 8'h5F, 8'h7F: return 1;
      default: return 0;
    endcase
  endfunction

  wire        known   = found && !busy;
  wire [15:0] g_addr  = known && !f_keep ? f_start : r_addr;
  wire        unsure  = run_bin && !known && !plausible(r_first);
  wire [4:0]  note_n  = known ? f_nlen : 5'd0;

  // Which hint, if any.
  wire at_start = position == 25'd0;
  // An image may carry padding after its last block, so "played" means past
  // the last header rather than at the last byte.
  wire a_done   = a_eof_ok ? position > a_eof : position > a_last;
  wire at_end   = position >= length || position > z_last ||
                  (b_valid ? b_eof_ok && position > b_eof : a_done);
  wire between  = b_valid && a_done && position <= b_off;
  wire loaded   = length != 25'd0 && a_valid;
  wire load_a   = at_start;
  wire load_b   = !at_start && !at_end && between;
  wire run      = at_end && !at_start;

  // The start hint is dismissed by the key that ends it.
  logic old_strobe, dismissed, recorded;
  initial begin old_strobe = 0; dismissed = 0; recorded = 0; end
  always_ff @(posedge clk) begin
    old_strobe <= ps2_key[10];
    if (rec) recorded <= 1;
    else if (at_start) recorded <= 0;
    if (!run) dismissed <= 0;
    else if (ps2_key[10] != old_strobe && ps2_key[9] &&
             ps2_key[7:0] == (run_bin ? 8'h29 : 8'h5A))
      dismissed <= 1;
  end

  wire        want = loaded && !playing && (load_a || load_b || (run && !dismissed && !recorded));
  wire        t_bin  = load_b ? b_bin : a_bin;          // file being loaded
  wire [47:0] t_name = load_b ? b_name : a_name;
  wire        prev_bin = load_b ? a_bin : 1'b0;        // BASIC after power-on
  wire        ld = load_a || load_b;
  wire        call_step = ld && !t_bin && need_call;
  wire        line2 = !ld && (unsure || note_n != 5'd0);

  // Name length without trailing spaces.
  function automatic logic [2:0] name_len(input logic [47:0] n);
    name_len = 0;
    for (int i = 0; i < 6; i++) if (n[47 - 8 * i -: 8] != 8'h20) name_len = 3'(i + 1);
  endfunction
  function automatic logic [7:0] hex(input logic [3:0] n);
    return n < 4'd10 ? 8'h30 + {4'd0, n} : 8'h37 + {4'd0, n};
  endfunction
  wire [2:0] nlen = name_len(t_name);
  localparam logic [8*18-1:0] UNKNOWN = "START ADDR UNKNOWN";

  // Every possible piece in fixed slots, with an include flag each; a
  // sequencer copies the included ones into `text`, one slot per clock.
  logic [6:0]   sc_idx;
  logic [5:0]   w, w1;
  logic         nl;
  logic [351:0] build;
  logic [7:0]   sc;
  logic         si;
  always_comb begin
    sc = 8'h20; si = 0;
    case (sc_idx)
      0: begin sc = "T"; si = 1; end
      1: begin sc = "Y"; si = 1; end
      2: begin sc = "P"; si = 1; end
      3: begin sc = "E"; si = 1; end
      4: begin sc = " "; si = 1; end
      5: begin sc = "M"; si = ld && t_bin && !prev_bin; end
      6: begin sc = "O"; si = ld && t_bin && !prev_bin; end
      7: begin sc = "N"; si = ld && t_bin && !prev_bin; end
      8: begin sc = " "; si = ld && t_bin && !prev_bin; end
      9: begin sc = `TH_RETURN; si = ld && t_bin && !prev_bin; end
      10: begin sc = " "; si = ld && t_bin && !prev_bin; end
      11: begin sc = "E"; si = ld && !t_bin && prev_bin; end
      12: begin sc = " "; si = ld && !t_bin && prev_bin; end
      13: begin sc = `TH_RETURN; si = ld && !t_bin && prev_bin; end
      14: begin sc = " "; si = ld && !t_bin && prev_bin; end
      15: begin sc = "C"; si = call_step; end
      16: begin sc = "A"; si = call_step; end
      17: begin sc = "L"; si = call_step; end
      18: begin sc = "L"; si = call_step; end
      19: begin sc = " "; si = call_step; end
      20: begin sc = "$"; si = call_step; end
      21: begin sc = "E"; si = call_step; end
      22: begin sc = "3"; si = call_step; end
      23: begin sc = "7"; si = call_step; end
      24: begin sc = "E"; si = call_step; end
      25: begin sc = " "; si = call_step; end
      26: begin sc = `TH_RETURN; si = call_step; end
      27: begin sc = `TH_NEWLINE; si = call_step; end
      28: begin sc = "T"; si = call_step; end
      29: begin sc = "H"; si = call_step; end
      30: begin sc = "E"; si = call_step; end
      31: begin sc = "N"; si = call_step; end
      32: begin sc = " "; si = call_step; end
      33: begin sc = "L"; si = ld && t_bin; end
      34: begin sc = " "; si = ld && t_bin; end
      35: begin sc = "L"; si = ld && !t_bin; end
      36: begin sc = "O"; si = ld && !t_bin; end
      37: begin sc = "A"; si = ld && !t_bin; end
      38: begin sc = "D"; si = ld && !t_bin; end
      39: begin sc = " "; si = ld && !t_bin; end
      40, 41, 42, 43, 44, 45: begin
        sc = t_name[47 - 8 * (sc_idx - 40) -: 8];
        si = ld && (sc_idx - 40) < nlen;
      end
      46: begin sc = " "; si = ld; end
      47: begin sc = t_bin ? `TH_SPACE : `TH_RETURN; si = ld; end
      48: begin sc = "G"; si = !ld && run_bin; end
      49: begin sc = " "; si = !ld && run_bin; end
      50: begin sc = unsure ? "?" : hex(g_addr[15:12]); si = !ld && run_bin; end
      51: begin sc = unsure ? "?" : hex(g_addr[11:8]); si = !ld && run_bin; end
      52: begin sc = unsure ? "?" : hex(g_addr[7:4]); si = !ld && run_bin; end
      53: begin sc = unsure ? "?" : hex(g_addr[3:0]); si = !ld && run_bin; end
      54: begin sc = "R"; si = !ld && !run_bin; end
      55: begin sc = "U"; si = !ld && !run_bin; end
      56: begin sc = "N"; si = !ld && !run_bin; end
      57: begin sc = " "; si = !ld; end
      58: begin sc = run_bin ? `TH_SPACE : `TH_RETURN; si = !ld; end
      59: begin sc = `TH_NEWLINE; si = line2; end
      default:
        if (sc_idx >= 60 && sc_idx < 78) begin          // 18 slots
          sc = UNKNOWN[8*18-1 - 8 * (sc_idx - 60) -: 8];
          si = !ld && unsure;
        end else if (sc_idx >= 78 && sc_idx < 100) begin // 22 slots
          sc = f_note[175 - 8 * (sc_idx - 78) -: 8];
          si = !ld && (sc_idx - 78) < note_n;
        end
    endcase
  end

  initial begin sc_idx = 0; w = 0; w1 = 0; nl = 0; build = 0; show = 0; len = 0; two = 0; text = 0; end

  always_ff @(posedge clk) begin
    if (sc_idx == 7'(SLOTS - 1)) begin
      text <= build;
      len  <= !nl ? w[4:0] : w1 > w - 6'd22 ? w1[4:0] : 5'(w - 6'd22);
      two  <= nl;
      show <= want;
      sc_idx <= 0;
      w <= 0; w1 <= 0; nl <= 0;
      build <= {44{8'h20}};
    end else begin
      if (si && sc == `TH_NEWLINE) begin
        w1 <= w; nl <= 1; w <= 6'd22;
      end else if (si && w < (nl ? 6'd44 : 6'd22)) begin
        build[351 - 8 * w -: 8] <= sc;
        w <= w + 6'd1;
      end
      sc_idx <= sc_idx + 7'd1;
    end
  end
endmodule

module tape_status (
  input  logic         clk,
  input  logic         loaded,      // a tape is mounted
  input  logic         playing,     // deck running (or briefly stopped mid-load)
  input  logic         fast,        // turbo active
  input  logic  [24:0] position,    // bytes played (0 after mount/rewind)
  input  logic  [24:0] length,      // bytes on the tape
  input  logic         hint_show,   // from tape_hint
  input  logic   [4:0] hint_len,
  input  logic         hint_two,
  input  logic [351:0] hint_text,
  // to the video clock
  output logic [400:0] status,      // held while req != ack
  output logic         req,
  input  logic         ack          // asynchronous; synchronised here
);
  localparam logic [8:0] BITS_PER_BYTE = 9'd11;
  localparam logic [8:0] BAUD = 9'd300;

  logic [15:0] elapsed, total;     // BCD m1 m0 s1 s0
  logic [8:0]  frac;               // bit-times into the current second
  logic [24:0] last_pos, last_len, cell_count;
  logic [29:0] rem;                // bit-times left to count into `total`
  logic [6:0]  fill;
  logic        computing;
  logic [1:0]  ack_sync;

  function automatic logic [15:0] bcd_tick(input logic [15:0] t);
    logic [15:0] n;
    n = t;
    if (t == 16'h9959) return t;                 // saturate at 99:59
    if (t[3:0] != 4'd9) n[3:0] = t[3:0] + 4'd1;
    else begin
      n[3:0] = 0;
      if (t[7:4] != 4'd5) n[7:4] = t[7:4] + 4'd1;
      else begin
        n[7:4] = 0;
        if (t[11:8] != 4'd9) n[11:8] = t[11:8] + 4'd1;
        else begin n[11:8] = 0; n[15:12] = t[15:12] + 4'd1; end
      end
    end
    return n;
  endfunction

  wire [24:0] cell_bytes = length[24:6] == 0 ? 25'd1 : {6'd0, length[24:6]};
  wire [400:0] pack = {hint_two, hint_show, hint_len, hint_text, loaded, playing, fast, fill, elapsed, total};

  initial begin
    elapsed = 0; total = 0; frac = 0; last_pos = 0; last_len = 0;
    rem = 0; cell_count = 0; fill = 0; computing = 0; req = 0; status = 0; ack_sync = 0;
  end

  always_ff @(posedge clk) begin
    ack_sync <= {ack_sync[0], ack};
    last_pos <= position;
    // Elapsed time and fill follow the byte pointer; it only steps by one or
    // returns to zero (mount, rewind).
    if (position == 0 || position < last_pos) begin
      elapsed <= 0; frac <= 0; fill <= 0; cell_count <= 0;
    end else if (position != last_pos) begin
      if (frac + BITS_PER_BYTE >= BAUD) begin
        frac <= frac + BITS_PER_BYTE - BAUD;
        elapsed <= bcd_tick(elapsed);
      end else frac <= frac + BITS_PER_BYTE;
      if (cell_count + 25'd1 >= cell_bytes) begin
        cell_count <= 0;
        if (fill != 7'd64) fill <= fill + 7'd1;
      end else cell_count <= cell_count + 25'd1;
    end
    // Total time: subtract one second of bit-times per clock after a new tape.
    last_len <= length;
    if (length != last_len) begin
      rem <= length * BITS_PER_BYTE; total <= 0; computing <= 1;
    end else if (computing) begin
      if (rem >= {21'd0, BAUD}) begin rem <= rem - {21'd0, BAUD}; total <= bcd_tick(total); end
      else computing <= 0;
    end
    // Send a changed status once the previous one was taken.
    if (req == ack_sync[1] && pack != status) begin
      status <= pack;
      req <= !req;
    end
  end
endmodule

module tape_overlay #(
  parameter logic [7:0] FACTOR_BCD = 8'h32   // shown as "x32" while turbo is on
)(
  input  logic         clk,         // video clock
  input  logic         ce_pix,
  input  logic         hblank, vblank,
  input  logic         enable,      // OSD Tape overlay: On
  input  logic [400:0] status,      // from tape_status, stable while req != ack
  input  logic         req,
  output logic         ack,
  input  logic  [23:0] rgb_in,
  output logic  [23:0] rgb_out
);
  localparam int CHARS = 22;
  logic [1:0]   req_sync;
  logic [400:0] shown;
  logic [10:0]  x, width;
  logic [9:0]   y, height;
  logic         line_active, old_hblank, old_vblank;

  initial begin
    req_sync = 0; ack = 0; shown = 0; x = 0; y = 0; width = 0; height = 0;
    line_active = 0; old_hblank = 0; old_vblank = 0;
  end

  // Measure the active picture each frame (320x240 with the MP-1710 border,
  // 256x192 in the borderless sim build).
  wire line_end = ce_pix && hblank && !old_hblank;
  always_ff @(posedge clk) begin
    req_sync <= {req_sync[0], req};
    if (req_sync[1] != ack) begin shown <= status; ack <= req_sync[1]; end
    if (ce_pix) begin
      old_hblank <= hblank; old_vblank <= vblank;
      if (!hblank && !vblank) begin x <= x + 11'd1; line_active <= 1; end
      if (hblank && !old_hblank) begin
        if (line_active) begin width <= x; y <= y + 10'd1; end
        x <= 0; line_active <= 0;
      end
      if (vblank && !old_vblank) begin height <= y; y <= 0; end
    end
  end

  wire         hint_two = shown[400];
  wire         hint_show = shown[399];
  wire [4:0]   hint_len = shown[398:394];
  wire [351:0] hint_text = shown[393:42];
  wire         tape_bar = enable && shown[41] && shown[40];   // loaded, playing
  wire         hint = enable && hint_show && !tape_bar;
  wire         visible = tape_bar || hint;
  wire         fast = shown[39];
  wire [6:0]   fill = shown[38:32];
  wire [15:0]  elapsed = shown[31:16], total = shown[15:0];
  // Double the overlay on wide or tall pictures (never on this core's 320x240).
  wire         sx = width >= 11'd512, sy = height >= 10'd300;
  wire [4:0]   chars = tape_bar ? 5'(CHARS) : hint_len;
  wire [10:0]  box_w = {3'd0, chars, 3'd0} + 11'd4;
  wire [9:0]   box_h = tape_bar ? 10'd18 : hint_two ? 10'd22 : 10'd12;
  wire [10:0]  x0 = 11'd4;
  wire [9:0]   y0 = height - (sy ? {box_h[8:0], 1'b0} : box_h) - 10'd4;
  wire [10:0]  dx = x - x0;
  wire [9:0]   dy = y - y0;
  wire [10:0]  lx = sx ? {1'b0, dx[10:1]} : dx;
  wire [9:0]   ly = sy ? {1'b0, dy[9:1]} : dy;
  wire         in_box = x >= x0 && y >= y0 && lx < box_w && ly < box_h;

  // Text rows at ly 2..9 (and 12..19 for a two-line hint), x 2..: one
  // character per 8 pixels.
  wire [10:0] tx = lx - 11'd2;
  wire        line2 = hint && hint_two && ly >= 10'd12;
  wire [9:0]  ty = ly - (line2 ? 10'd12 : 10'd2);

  function automatic logic [7:0] digit(input logic [3:0] d, input logic blank_zero);
    return blank_zero && d == 0 ? 8'h20 : 8'h30 + {4'd0, d};
  endfunction
  function automatic logic [7:0] char_at(input logic [4:0] col);
    if (!tape_bar) return hint_text[351 - 8 * ({1'b0, col} + (line2 ? 6'd22 : 6'd0)) -: 8];
    case (col)
      5'd0: return "T";  5'd1: return "A";  5'd2: return "P";  5'd3: return "E";
      5'd5: return `TH_PLAY;
      5'd7: return digit(elapsed[15:12], 1'b1);  5'd8: return digit(elapsed[11:8], 1'b0);
      5'd9: return ":";
      5'd10: return digit(elapsed[7:4], 1'b0);  5'd11: return digit(elapsed[3:0], 1'b0);
      5'd12: return "/";
      5'd13: return digit(total[15:12], 1'b1);  5'd14: return digit(total[11:8], 1'b0);
      5'd15: return ":";
      5'd16: return digit(total[7:4], 1'b0);  5'd17: return digit(total[3:0], 1'b0);
      5'd19: return fast ? "x" : " ";
      5'd20: return fast ? digit(FACTOR_BCD[7:4], 1'b1) : " ";
      5'd21: return fast ? digit(FACTOR_BCD[3:0], 1'b0) : " ";
      default: return " ";
    endcase
  endfunction
  function automatic logic [7:0] special(input logic [7:0] c, input logic [2:0] r);
    logic [63:0] g;
    case (c)
      `TH_RETURN: g = 64'h0002022262FE6020;
      `TH_SPACE:  g = 64'h00000000008282FE;
      "$":        g = 64'h103C503814781000;   // the ROM's $ reads as #
      default:    g = 64'h4060707870604000;   // play
    endcase
    return g[63 - 8 * r -: 8];
  endfunction

  // Glyph rows for the coming line, fetched from the character ROM during
  // horizontal blanking (y has already stepped to the new line by then).
  logic [7:0] row [0:CHARS-1];
  logic [4:0] fi, fi_d;
  logic       fetching, fetch_d, start;
  logic [7:0] fc, fc_d;
  wire  [7:0] font_q;
  initial begin fi = 0; fi_d = 0; fetching = 0; fetch_d = 0; start = 0; fc_d = 0; end

  always_comb fc = char_at(fi);

  rom #(.MEMFILE("rom0.mem"), .DW(8), .AW(11)) font(
    .clk(clk),
    .addr({fc, ty[2:0]}),
    .dout(font_q),
    .ce(1'b1)
  );

  always_ff @(posedge clk) begin
    start <= line_end;
    if (start) begin fetching <= 1; fi <= 0; end
    else if (fetching) begin
      if (fi == 5'(CHARS - 1)) fetching <= 0;
      fi <= fi + 5'd1;
    end
    fetch_d <= fetching;
    fi_d <= fi;
    fc_d <= fc;
    if (fetch_d)
      row[fi_d] <= (fc_d >= `TH_RETURN && fc_d <= `TH_PLAY) || fc_d == "$" ? special(fc_d, ty[2:0]) : font_q;
  end

  wire [4:0] col = tx[7:3];
  wire [7:0] glyph_row = row[col];
  wire text_on = ty < 10'd8 && tx < {3'd0, chars, 3'd0} && glyph_row[3'd7 - tx[2:0]];
  // Progress bar at ly 12..15, 128 px for 64 steps.
  wire bar_area = tape_bar && ly >= 10'd12 && ly < 10'd16 && lx >= 11'd2 && lx < 11'd130;
  wire bar_on = bar_area && (lx - 11'd2) < {3'd0, fill, 1'b0};

  always_comb begin
    rgb_out = rgb_in;
    if (visible && in_box)
      rgb_out = text_on ? 24'hFFFFFF : bar_on ? 24'h44CC44 : bar_area ? 24'h333333 : 24'h000000;
  end
endmodule
