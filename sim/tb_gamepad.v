`timescale 1ns/1ps
// Low-speed gamepad against the usb_hid_host core.
//
//   make -C sim basic      fast replies, D-pad and a face button
//   make -C sim retry      first SET_ADDRESS is ignored; the host must retry
//   make -C sim nopull     pull-up stays off until the host drives a bus reset
//   make -C sim badclass   first descriptor is not HID; the host must reset again
//
// TA is the device turnaround in 12 MHz clocks (spec minimum is 16).
module tb_gamepad;
reg clk = 0;
always #41.667 clk = ~clk;
reg rstn = 0;

reg dev_oe = 0, dev_dp = 0, dev_dm = 1;
reg dmpull = 1;
wire dp, dm;
// Host drive wins. Otherwise the pad drives, or D- sits at the pull-up.
assign dp = u.ukp.ug ? 1'bz : (dev_oe ? dev_dp : 1'b0);
assign dm = u.ukp.ug ? 1'bz : (dev_oe ? dev_dm : (dmpull ? 1'b1 : 1'b0));

wire [1:0] typ;
wire report;
wire game_l, game_r, game_u, game_d;
wire game_a, game_b, game_x, game_y, game_sel, game_sta;
wire [63:0] dbg;
usb_hid_host u(
    .usbclk(clk), .usbrst_n(rstn), .usb_dm(dm), .usb_dp(dp),
    .typ(typ), .report(report), .conerr(),
    .key_modifiers(), .key1(), .key2(), .key3(), .key4(),
    .mouse_btn(), .mouse_dx(), .mouse_dy(),
    .game_l(game_l), .game_r(game_r), .game_u(game_u), .game_d(game_d),
    .game_a(game_a), .game_b(game_b), .game_x(game_x), .game_y(game_y),
    .game_sel(game_sel), .game_sta(game_sta), .dbg_hid_report(dbg));

integer TA;
reg [1:0] phase;          // 0 idle, 1 left, 2 up, 3 button A
reg fail_addr;            // ignore the first SET_ADDRESS
reg badclass;
reg class_ok;
integer errors;

// ---------------------------------------------------------------- host RX
reg [0:255] bits;
integer nb, ones, inpkt;
reg prev;
event pkt_done;
initial begin inpkt = 0; nb = 0; ones = 0; end
always @(posedge clk) if (rstn && u.ukp.ug && u.ukp.timing == 4) begin
    if (!dp && !dm) begin
        if (inpkt) begin inpkt = 0; -> pkt_done; end
    end else if (!inpkt) begin
        if (!dm) begin inpkt = 1; prev = 0; nb = 1; bits[0] = 0; ones = 0; end
    end else begin
        if (ones == 6) begin ones = 0; prev = dm; end
        else begin
            bits[nb] = (dm == prev); prev = dm;
            ones = bits[nb] ? ones + 1 : 0;
            nb = nb + 1;
        end
    end
end
function [7:0] rbyte; input integer i; integer k; begin
    for (k = 0; k < 8; k = k + 1) rbyte[k] = bits[8 + i*8 + k];
end endfunction

// ---------------------------------------------------------------- device TX
reg lvl;
integer txones;
task txbit; input b; begin
    if (!b) lvl = ~lvl;
    dev_dm = lvl; dev_dp = ~lvl;
    repeat (8) @(posedge clk);
    if (b) begin
        txones = txones + 1;
        if (txones == 6) begin
            txones = 0; lvl = ~lvl;
            dev_dm = lvl; dev_dp = ~lvl;
            repeat (8) @(posedge clk);
        end
    end else txones = 0;
end endtask
task txbyte; input [7:0] v; integer k; begin
    for (k = 0; k < 8; k = k + 1) txbit(v[k]);
end endtask
reg [7:0] pl [0:7];
task txpkt; input [7:0] pid; input integer n; integer k; begin
    lvl = 1; txones = 0; dev_oe = 1;
    txbyte(8'h80); txbyte(pid);
    for (k = 0; k < n; k = k + 1) txbyte(pl[k]);
    if (pid == 8'hC3 || pid == 8'h4B) begin txbyte(8'h00); txbyte(8'h00); end
    dev_dp = 0; dev_dm = 0; repeat (16) @(posedge clk);
    dev_dm = 1; dev_dp = 0; repeat (8) @(posedge clk);
    dev_oe = 0;
end endtask

// ---------------------------------------------------------------- bus reset length
integer se0_len, se0_max, resets;
initial begin se0_len = 0; se0_max = 0; resets = 0; end
always @(posedge clk) if (u.ukp.ug && !u.ukp.up && !u.ukp.um)
    se0_len <= se0_len + 1;
else if (se0_len != 0) begin
    if (se0_len > se0_max) se0_max <= se0_len;
    if (se0_len >= 12000*10) resets <= resets + 1;
    se0_len <= 0;
end

// ---------------------------------------------------------------- device
reg [7:0] cfg [0:23];
initial begin
    {cfg[0],cfg[1],cfg[2],cfg[3],cfg[4],cfg[5],cfg[6],cfg[7],cfg[8]} =
        {8'h09,8'h02,8'h22,8'h00,8'h01,8'h01,8'h00,8'h80,8'hFA};
    {cfg[9],cfg[10],cfg[11],cfg[12],cfg[13],cfg[14],cfg[15],cfg[16],cfg[17]} =
        {8'h09,8'h04,8'h00,8'h00,8'h01,8'h03,8'h00,8'h00,8'h00};
    {cfg[18],cfg[19],cfg[20],cfg[21],cfg[22],cfg[23]} =
        {8'h09,8'h21,8'h10,8'h01,8'h21,8'h01};
end
reg [7:0] last_tok, breq, tog;
integer dptr, polls;
reg ignored_addr;
initial begin
    last_tok = 0; breq = 0; dptr = 0; tog = 8'h4B; polls = 0; ignored_addr = 0;
    forever begin : resp
        reg [7:0] pid, ad;
        integer k;
        @(pkt_done);
        pid = rbyte(0); ad = rbyte(1);
        while (!(dp | dm)) @(posedge clk);
        case (pid)
        8'h2D: last_tok = pid;
        8'hC3, 8'h4B: if (last_tok == 8'h2D) begin
                breq = rbyte(2);
                if (breq == 8'h05 && fail_addr) begin
                    ignored_addr = 1;           // no ACK: host must time out
                end else begin
                    dptr = 0; tog = 8'h4B;
                    repeat (TA) @(posedge clk); txpkt(8'hD2, 0);
                end
            end
        8'h69: begin
                repeat (TA) @(posedge clk);
                if (ad[7]) begin
                    polls = polls + 1;
                    pl[0]=8'h00; pl[1]=8'h00; pl[2]=8'h00;
                    pl[3] = (phase == 2'd1) ? 8'h00 : 8'h80;
                    pl[4] = (phase == 2'd2) ? 8'h00 : 8'h80;
                    pl[5] = (phase == 2'd3) ? 8'h2F : 8'h0F;
                    pl[6]=8'h00; pl[7]=8'h00;
                    txpkt(tog, 8); tog = tog ^ 8'h88;
                end else if (breq == 8'h06) begin
                    for (k = 0; k < 8; k = k + 1) begin
                        pl[k] = cfg[dptr + k];
                        if (badclass && !class_ok && dptr + k == 14) pl[k] = 8'h00;
                    end
                    dptr = dptr + 8;
                    txpkt(tog, 8); tog = tog ^ 8'h88;
                end else
                    txpkt(8'h4B, 0);            // status DATA1
            end
        default: ;
        endcase
    end
end

// A bus reset after the ignored SET_ADDRESS arms the next attempt.
// A non-HID class is corrected once the host has reset again.
always @(posedge clk) begin
    if (ignored_addr && resets >= 3) fail_addr <= 0;
    if (resets >= 3) class_ok <= 1;
    if (rstn && !dmpull && resets >= 1) dmpull <= 1;
end

initial begin
    errors = 0; phase = 0; fail_addr = 0; badclass = 0; class_ok = 0;
    if (!$value$plusargs("TA=%d", TA)) TA = 16;
    if ($test$plusargs("RETRY")) fail_addr = 1;
    if ($test$plusargs("NOPULL")) dmpull = 0;
    if ($test$plusargs("BADCLASS")) badclass = 1;
    repeat (20) @(posedge clk);
    rstn = 1;

    if (fail_addr || badclass || !dmpull)
        repeat (12000 * 1600) @(posedge clk);
    else
        repeat (12000 * 900) @(posedge clk);
    if (fail_addr) begin
        if (resets < 3) begin $display("FAIL: no retry"); errors = errors + 1; end
        if (!(typ == 2'd3 && u.connected)) begin $display("FAIL: not polling after retry"); errors = errors + 1; end
        if (se0_max < 12000*20) begin $display("FAIL: short reset %0d", se0_max); errors = errors + 1; end
    end else begin
        if (!(typ == 2'd3 && u.connected)) begin $display("FAIL: not polling typ=%0d con=%0d pull=%0d resets=%0d", typ, u.connected, dmpull, resets); errors = errors + 1; end
        if (se0_max < 12000*20) begin $display("FAIL: short reset %0d", se0_max); errors = errors + 1; end
        if (game_l || game_u || game_a) begin $display("FAIL: idle looks pressed %h", dbg); errors = errors + 1; end
        phase = 1;
        repeat (12000 * 40) @(posedge clk);
        if (!(game_l && !game_r && !game_u)) begin $display("FAIL: left %h l=%0d u=%0d", dbg, game_l, game_u); errors = errors + 1; end
        phase = 2;
        repeat (12000 * 40) @(posedge clk);
        if (!(game_u && !game_d && !game_l)) begin $display("FAIL: up %h", dbg); errors = errors + 1; end
        phase = 3;
        repeat (12000 * 40) @(posedge clk);
        if (!(game_a && !game_u && !game_l)) begin $display("FAIL: button %h a=%0d", dbg, game_a); errors = errors + 1; end
        if (polls <= 5) begin $display("FAIL: polls %0d", polls); errors = errors + 1; end
    end
    if (errors == 0) $display("PASS TA=%0d se0_max_ms=%0d polls=%0d resets=%0d",
        TA, se0_max/12000, polls, resets);
    else $display("FAILED %0d", errors);
    $finish;
end
endmodule
