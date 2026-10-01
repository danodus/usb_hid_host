// Usb_hid_host: A compact USB HID host core.
//
// nand2mario, 8/2023, based on work by hi631
// 
// This should support keyboard, mouse and gamepad input out of the box, over low-speed 
// USB (1.5Mbps). Just connect D+, D-, VBUS (5V) and GND, and two 15K resistors between 
// D+ and GND, D- and GND. Then provide a 12Mhz clock through usbclk.
//
// See https://github.com/nand2mario/usb_hid_host
// 

module usb_hid_host (
    input  usbclk,		            // 12MHz clock
    input  usbrst_n,	            // reset
    inout  usb_dm, usb_dp,          // USB D- and D+

    output reg [1:0] typ,           // device type. 0: no device, 1: keyboard, 2: mouse, 3: gamepad
    output reg report,              // pulse after report received from device. 
                                    // key_*, mouse_*, game_* valid depending on typ
    output conerr,                  // connection or protocol error

    // keyboard
    output reg [7:0] key_modifiers,
    output reg [7:0] key1, key2, key3, key4,

    // mouse
    output reg [7:0] mouse_btn,     // {5'bx, middle, right, left}
    output reg signed [7:0] mouse_dx,      // signed 8-bit, cleared after `report` pulse
    output reg signed [7:0] mouse_dy,      // signed 8-bit, cleared after `report` pulse

    // gamepad 
    output reg game_l, game_r, game_u, game_d,  // left right up down
    output reg game_a, game_b, game_x, game_y, game_sel, game_sta,  // buttons

    // debug
    output [63:0] dbg_hid_report	// last HID report
);

wire data_rdy;          // data ready
wire data_strobe;       // data strobe for each byte
wire [7:0] ukpdat;		// actual data
reg [7:0] regs [7];     // 0 (VID_L), 1 (VID_H), 2 (PID_L), 3 (PID_H), 4 (INTERFACE_CLASS), 5 (INTERFACE_SUBCLASS), 6 (INTERFACE_PROTOCOL)
wire save;			    // save dat[b] to output register r
wire [3:0] save_r;      // which register to save to
wire [3:0] save_b;      // dat[b]
wire connected;

reg rec_rst = 0;
wire ukp_rstn = usbrst_n & ~rec_rst;
ukp ukp(
    .usbrst_n(ukp_rstn), .usbclk(usbclk),
    .usb_dp(usb_dp), .usb_dm(usb_dm), .usb_oe(),
    .ukprdy(data_rdy), .ukpstb(data_strobe), .ukpdat(ukpdat), .save(save), .save_r(save_r), .save_b(save_b),
    .connected(connected), .conerr(conerr));

reg  [3:0] rcvct;		// counter for recv data
reg  data_strobe_r, data_rdy_r;	// delayed data_strobe and data_rdy
reg  [7:0] dat[8];		// data in last response
assign dbg_hid_report = {dat[7], dat[6], dat[5], dat[4], dat[3], dat[2], dat[1], dat[0]};
// assign dbg_regs = regs;

// Gamepad types, see response_recognition below
// localparam D_GENERIC = 0;
// localparam D_GAMEPAD = 1;			
// localparam D_DS2_ADAPTER = 2;
// reg [3:0] dev = D_GENERIC;			// device type recognized through VID/PID
// assign dbg_dev = dev;

reg valid = 0;		    // whether current gamepad report is valid
reg hat_mode = 0;       // set once a report shows a null hat (0x8 or 0xF)
// First sample of each axis byte is its rest position. A constant 0x00
// in front of the report never moves, so it is not Left. Whichever later
// byte actually moves (X in byte 3, or Y in byte 1 or 4) supplies the direction.
reg seen0 = 0, seen1 = 0, seen3 = 0, seen4 = 0;
reg [7:0] neutral0 = 0, neutral1 = 0, neutral3 = 0, neutral4 = 0;

// 2'b10 = below rest (left/up), 2'b01 = above rest (right/down).
function [1:0] rel_axis;
    input [7:0] v;
    input [7:0] n;
    begin
        if (v < n && (n - v) > 8'h30)
            rel_axis = 2'b10;
        else if (v > n && (v - n) > 8'h30)
            rel_axis = 2'b01;
        else
            rel_axis = 2'b00;
    end
endfunction

always @(posedge usbclk) begin : process_in_data
    data_rdy_r <= data_rdy; data_strobe_r <= data_strobe;
    report <= 0;                    // ensure pulse
    if (report == 1) begin
        // clear mouse movement for later
        mouse_dx <= 0; mouse_dy <= 0;
    end
    if(~data_rdy) rcvct <= 0;
    else begin
        if(data_strobe && ~data_strobe_r) begin  // rising edge of ukp data strobe
            dat[rcvct] <= ukpdat;

            if (typ == 1) begin     // keyboard
                case (rcvct)
                0: key_modifiers <= ukpdat;
                2: key1 <= ukpdat;
                3: key2 <= ukpdat;
                4: key3 <= ukpdat;
                5: key4 <= ukpdat;
                endcase
            end else if (typ == 2) begin    // mouse
                case (rcvct)
                0: mouse_btn <= ukpdat;
                1: mouse_dx <= ukpdat;
                2: mouse_dy <= ukpdat;
                endcase
            end else if (typ == 3) begin    // gamepad
                // A typical report layout:
                // - d[3] is X axis (0: left, 255: right)
                // - d[4] is Y axis
                // - d[5][7:4] is buttons YBAX
                // - d[6][5:4] is buttons START,SELECT
                // Directions are resolved after the whole report, below.
                // Bytes 0-2 are constants on the common 0079:0011 layout;
                // X and Y are bytes 3 and 4. Other pads put X/Y in bytes 0/1.
                // A DualShock2 adapter marks an irrelevant record with d[0]==0x02.
                // A hat, when present, is d[5][3:0] (0 N .. 7 NW, 8 or 15 idle).
                case (rcvct)
                0: valid <= (ukpdat != 8'h02);
                5: if (valid) begin
                    game_x <= ukpdat[4];
                    game_a <= ukpdat[5];
                    game_b <= ukpdat[6];
                    game_y <= ukpdat[7];
                    // Latch on the idle value so a low nibble of unused zeros
                    // is not stuck reporting Up.
                    if (ukpdat[3:0] == 4'h8 || ukpdat[3:0] == 4'hF)
                        hat_mode <= 1;
                end
                6: if (valid) begin
                    game_sel <= ukpdat[4];
                    game_sta <= ukpdat[5];
                end
                endcase
                // TODO: add any special handling if needed 
                // (using the detected controller type in 'dev')                
            end
            rcvct <= rcvct + 1;
        end
    end
    if (~connected) begin
        hat_mode <= 0;
        seen0 <= 0; seen1 <= 0; seen3 <= 0; seen4 <= 0;
        {game_l, game_r, game_u, game_d} <= 4'b0;
    end else if (~data_rdy && data_rdy_r && typ == 3 && valid) begin
        // Only a centered sample is rest. A press (or a constant 0x00 prefix)
        // must not become the neutral, or Up/Left never shows afterward.
        if (rcvct > 0 && !seen0 && dat[0] >= 8'h40 && dat[0] <= 8'hC0) begin seen0 <= 1; neutral0 <= dat[0]; end
        if (rcvct > 1 && !seen1 && dat[1] >= 8'h40 && dat[1] <= 8'hC0) begin seen1 <= 1; neutral1 <= dat[1]; end
        if (rcvct > 3 && !seen3 && dat[3] >= 8'h40 && dat[3] <= 8'hC0) begin seen3 <= 1; neutral3 <= dat[3]; end
        if (rcvct > 4 && !seen4 && dat[4] >= 8'h40 && dat[4] <= 8'hC0) begin seen4 <= 1; neutral4 <= dat[4]; end
        // Bytes 3 and 4 are X/Y. A value on the rail is a direction even
        // before a rest sample has been seen, so the first press shows.
        // Bytes 0/1 are used only after a centered sample, so a constant
        // 0x00 prefix is not Left.
        if (hat_mode && rcvct > 5 && dat[5][3:0] <= 4'h7) begin
            case (dat[5][3:0])
            4'h0: {game_l, game_r, game_u, game_d} <= 4'b0010;
            4'h1: {game_l, game_r, game_u, game_d} <= 4'b0110;
            4'h2: {game_l, game_r, game_u, game_d} <= 4'b0100;
            4'h3: {game_l, game_r, game_u, game_d} <= 4'b0101;
            4'h4: {game_l, game_r, game_u, game_d} <= 4'b0001;
            4'h5: {game_l, game_r, game_u, game_d} <= 4'b1001;
            4'h6: {game_l, game_r, game_u, game_d} <= 4'b1000;
            4'h7: {game_l, game_r, game_u, game_d} <= 4'b1010;
            endcase
        end else begin
            if (rcvct > 3 && dat[3] < 8'h40)
                {game_l, game_r} <= 2'b10;
            else if (rcvct > 3 && dat[3] > 8'hC0)
                {game_l, game_r} <= 2'b01;
            else if (seen3 && rcvct > 3 && rel_axis(dat[3], neutral3) != 2'b00)
                {game_l, game_r} <= rel_axis(dat[3], neutral3);
            else if (seen0 && rcvct > 0)
                {game_l, game_r} <= rel_axis(dat[0], neutral0);
            else
                {game_l, game_r} <= 2'b00;

            if (rcvct > 4 && dat[4] < 8'h40)
                {game_u, game_d} <= 2'b10;
            else if (rcvct > 4 && dat[4] > 8'hC0)
                {game_u, game_d} <= 2'b01;
            else if (seen4 && rcvct > 4 && rel_axis(dat[4], neutral4) != 2'b00)
                {game_u, game_d} <= rel_axis(dat[4], neutral4);
            else if (seen1 && rcvct > 1)
                {game_u, game_d} <= rel_axis(dat[1], neutral1);
            else
                {game_u, game_d} <= 2'b00;
        end
    end
    if(~data_rdy && data_rdy_r && typ != 0)    // falling edge of ukp data ready
        report <= 1;
end

reg save_delayed;
reg connected_r;
reg [1:0] dev_typ = 0;
always @(posedge usbclk) begin : response_recognition
    save_delayed <= save;
    if (save) begin
        regs[save_r] <= dat[save_b];
    end else if (save_delayed && ~save && save_r == 6) begin
        // falling edge of save for bInterfaceProtocol
        if (regs[4] == 3) begin  // bInterfaceClass. 3: HID, other: non-HID
            if (regs[5] == 1)    // bInterfaceSubClass. 1: Boot device
                dev_typ <= regs[6] == 1 ? 2'd1 : 2'd2; // 1 keyboard, 2 mouse
            else
                dev_typ <= 2'd3; // gamepad
        end else
            dev_typ <= 2'd0;
    end
    // The class is saved before SET_ADDRESS. "Detected" means we finished
    // enumeration and are polling; otherwise the LED lights with no buttons.
    connected_r <= connected;
    if (~connected) begin
        typ <= 2'd0;
        if (connected_r) dev_typ <= 2'd0;
    end     else
        typ <= dev_typ;
end

// Finished enumeration without recognizing a HID device. The poll loop
// would otherwise run forever with the LED off. Hold SE0, then try again.
reg [17:0] rec_cnt = 0;
always @(posedge usbclk) begin
    if (!usbrst_n) begin
        rec_rst <= 0;
        rec_cnt <= 0;
    end else if (rec_rst) begin
        if (rec_cnt == 18'd239999) begin
            rec_rst <= 0;
            rec_cnt <= 0;
        end else
            rec_cnt <= rec_cnt + 1;
    end else if (connected && dev_typ == 2'd0)
        rec_rst <= 1;
end

endmodule

module ukp(
    input usbrst_n,
    input usbclk,				// 12MHz clock
    inout usb_dp, usb_dm,		// D+, D-
    output usb_oe,
    output reg ukprdy, 			// data frame is outputing
    output ukpstb,				// strobe for a byte within the frame
    output reg [7:0] ukpdat,	// output data when ukpstb=1
    output reg save,			// save: regs[save_r] <= dat[save_b]
    output reg [3:0] save_r, save_b,
    output reg connected,
    output conerr
);

    parameter S_OPCODE = 0;
    parameter S_LDI0 = 1;
    parameter S_LDI1 = 2;
    parameter S_B0 = 3;
    parameter S_B1 = 4;
    parameter S_B2 = 5;
    parameter S_S0 = 6;
    parameter S_S1 = 7;
    parameter S_S2 = 8;
    parameter S_TOGGLE0 = 9;
    parameter S_TOGGLE1 = 10;

    wire [3:0] inst;
    reg  [3:0] insth;
    wire sample;						// 1: an IN sample is available
    // reg connected = 0;
    reg inst_ready = 0, up = 0, um = 0, cond = 0, nak = 0, dmis = 0;
    reg ug, ugw, nrzon;					// ug=1: output enabled, 0: hi-Z
    reg bank = 0, record1 = 0;
    reg [1:0] mbit = 0;					// 1: out4/outb is transmitting
    reg [3:0] state = 0, stated;
    reg [7:0] wk = 0;					// W register
    reg [7:0] sb = 0;					// out value
    reg [3:0] sadr;						// out4/outb write ptr
    reg [13:0] pc = 0, wpc;				// program counter, wpc = next pc
    reg [2:0] timing = 0;				// T register (0~7)
    reg [3:0] lb4 = 0, lb4w;
    reg [13:0] interval = 0;
    reg [6:0] bitadr = 0;				// 0~127
    reg [7:0] data = 0;					// received data
    reg [2:0] nrztxct, nrzrxct;			// NRZI trans/recv count for bit stuffing
    reg dpi, dmi;
    wire interval_cy = interval == 12001;
    wire next = ~(state == S_OPCODE & (
        inst ==2 & dmi |								// start
        (inst==4 || inst==5) & timing != 0 |			// out0/hiz
        inst ==13 & (~sample | (dpi | dmi) & wk != 1) |	// in 
        inst ==14 & ~interval_cy						// wait
    ));
    wire branch = state == S_B1 & cond;
    wire retpc  = state == S_OPCODE && inst==7  ? 1 : 0;
    wire jmppc  = state == S_OPCODE && inst==15 ? 1 : 0;
    wire dbit   = sb[7-sadr[2:0]];
    wire record;
    reg  dmid;
    reg  sync_first = 0;
    reg  ukprdyd;
    reg  nakd;
    reg  enum_active = 0;
    reg [21:0] enum_wait = 0;          // clocks spent in a NAKed control transfer
    reg [23:0] conct;
    reg  rst_seen = 0;
    assign conerr = conct[23] || ~usbrst_n;
    // ~200ms. A control transfer that never gets DATA is retried from the top.
    wire enum_stuck = enum_active && (enum_wait == 22'd2_400_000);

    usb_hid_host_rom ukprom(.clk(usbclk), .adr(pc), .data(inst));

    always @(posedge usbclk) begin
        rst_seen <= usbrst_n;
        if(~usbrst_n) begin 
            pc <= 0; connected <= 0; cond <= 0; inst_ready <= 0; state <= S_OPCODE; timing <= 0; 
            mbit <= 0; bitadr <= 0; nak <= 1; conct <= 0;
            up <= 0; um <= 0; ug <= 1;          // SE0 for as long as reset is held
            enum_active <= 0; enum_wait <= 0;
        end else begin
            dpi <= usb_dp; dmi <= usb_dm;
            save <= 0;		// ensure pulse
            if (inst_ready) begin
                // Instruction decoding
                case(state)
                    S_OPCODE: begin
                        insth <= inst;
                        if(inst==1) state <= S_LDI0;						// op=ldi
                        if(inst==3) begin sadr <= 3; state <= S_S0; end		// op=out4
                        if(inst==4) begin ug <= 9; up <= 0; um <= 0; end
                        if(inst==5) begin ug <= 0; end
                        if(inst==6) begin sadr <= 7; state <= S_S0; end		// op=outb
                        if (inst[3:2]==2'b10) begin							// op=10xx(BZ,BC,BNAK,DJNZ)
                            state <= S_B0;
                            case (inst[1:0])
                                2'b00: cond <= ~dmi;
                                2'b01: cond <= connected;
                                2'b10: cond <= nak;
                                2'b11: cond <= wk != 1;
                            endcase
                        end
                        if(inst==11 | inst==13 & sample) wk <= wk - 8'd1;	// op=DJNZ,IN
                        if(inst==15) begin state <= S_B2; cond <= 1; end	// op=jmp
                        if(inst==12) state <= S_TOGGLE0;
                    end
                    // Instructions with operands
                    // ldi
                    S_LDI0: begin	wk[3:0] <= inst; state <= S_LDI1;	end
                    S_LDI1: begin	wk[7:4] <= inst; state <= S_OPCODE; end
                    // branch/jmp
                    S_B2: begin lb4w <= inst; state <= S_B0; end
                    S_B0: begin lb4  <= inst; state <= S_B1; end
                    S_B1: state <= S_OPCODE;
                    // out
                    S_S0: begin sb[3:0] <= inst; state <= S_S1; end
                    S_S1: begin sb[7:4] <= inst; state <= S_S2; mbit <= 1; end
                    // toggle and save
                    S_TOGGLE0: begin 
                        if (inst == 15) connected <= ~connected;// toggle
                        else save_r <= inst;                    // save
                        state <= S_TOGGLE1;
                      end
                    S_TOGGLE1: begin
                        if (inst != 15) begin
                            save_b <= inst;
                            save <= 1;
                        end
                        state <= S_OPCODE;
                    end
                endcase
                // pc control
                if (mbit==0) begin 
                    if(jmppc) wpc <= pc + 4;
                    if (next | branch | retpc) begin
                        if(retpc) pc <= wpc;					// ret
                        else if(branch)
                            if(insth==15)						// jmp
                                pc <= { inst, lb4, lb4w, 2'b00 };
                            else								// branch
                                pc <= { 4'b0000, inst, lb4, 2'b00 };
                        else	pc <= pc + 1;					// next
                        inst_ready <= 0;
                    end
                end
            end
            else inst_ready <= 1;
            // bit transmission (out4/outb)
            if (mbit==1 && timing == 0) begin
                if(ug==0) nrztxct <= 0;
                else
                    if(dbit) nrztxct <= nrztxct + 1;
                    else     nrztxct <= 0;
                if(insth == 4'd6) begin
                    if(nrztxct!=6) begin up <= dbit ?  up : ~up; um <= dbit ? ~up :  up; end
                    else           begin up <= ~up; um <= up; nrztxct <= 0; end
                end else begin
                    up <=  sb[{1'b1,sadr[1:0]}]; um <= sb[sadr[2:0]];
                end
                ug <= 1'b1; 
                if(nrztxct!=6) sadr <= sadr - 4'd1;
                if(sadr==0) begin mbit <= 0; state <= S_OPCODE; end
            end
            // start instruction
            dmid <= dmi;
            if (inst_ready & state == S_OPCODE & inst == 4'b0010) begin // op=start 
                bitadr <= 0; nak <= 1; nrzrxct <= 0; sync_first <= 1;
            end else 
                if(ug==0 && dmi!=dmid) timing <= 1;
                else                   timing <= timing + 1;
            // IN instruction
            if (sample) begin
                if (bitadr == 8) nak <= dmi;
                // PID is complete on this sample. STALL's first bit looks
                // like NAK to the test above, which would retry SET_IDLE
                // forever on devices that reject it.
                if (nrzrxct != 6 && bitadr == 15 && {(dmis ~^ dmi), data[7:1]} == 8'h1E)
                    nak <= 0;
                if(nrzrxct!=6) begin
                    data[6:0] <= data[7:1]; 
                    data[7] <= dmis ~^ dmi;		    // ~^/^~ is XNOR, testing bit equality
                    bitadr <= bitadr + 1; nrzon <= 0;
                end else nrzon <= 1;
                // A device may answer 2 bit times after our EOP, before
                // START/IN are running, so the first SYNC bits can be missed.
                // SYNC ends with K,K: realign on it so the PID is at bitadr 8.
                if (~sync_first && bitadr < 8 && ~dmis && ~dmi && dpi)
                    bitadr <= 8;
                sync_first <= 0;
                dmis <= dmi;
                if(dmis ~^ dmi) nrzrxct <= nrzrxct + 1;
                else           nrzrxct <= 0;
                if (~dmi && ~dpi) ukprdy <= 0;      // SE0: packet is finished. Mouses send length 4 reports.
            end
            if (ug==0) begin
                if(bitadr==24) ukprdy <= 1;			// ignore first 3 bytes
                if(bitadr==88) ukprdy <= 0;			// output next 8 bytes
            end
            if ((bitadr>11 & bitadr[2:0] == 3'b000) & (timing == 2)) ukpdat <= data;
            // Timing
            interval <= interval_cy ? 0 : interval + 1;
            record1 <= record;
            if (~record & record1) bank <= ~bank;
            // Connection status & WDT
            ukprdyd <= ukprdy;
            nakd <= nak;
            // Pet the watchdog when a reply actually starts. A START that is
            // still waiting must not pet it, or a missed ACK hangs forever.
            // NAK loops do pet it, so a control transfer that only NAKs is
            // caught by enum_stuck instead.
            if ((ukprdy && ~ukprdyd || inst_ready && state == S_OPCODE && inst == 4'b0010 && !dmi) && !enum_stuck)
                conct <= 0;
            else if (conct[23:22] != 2'b11 && !enum_stuck)
                conct <= conct + 1;
            else
                conct <= 0;
            if ((conct[23:22] == 2'b11 && !(ukprdy && ~ukprdyd || inst_ready && state == S_OPCODE && inst == 4'b0010 && !dmi)) || enum_stuck) begin
                pc <= 0; connected <= 0; state <= S_OPCODE; inst_ready <= 0;
                ug <= 0; mbit <= 0; bitadr <= 0; nak <= 1; timing <= 0;
                enum_active <= 0; enum_wait <= 0;
            end else if (connected || ~nak) begin
                enum_active <= 0; enum_wait <= 0;
            end else if (enum_active)
                enum_wait <= enum_wait + 1;
            else if (inst_ready && state == S_OPCODE && inst == 4'd2)
                enum_active <= 1;
            // Drop SE0 on the cycle reset releases. The attach loop treats
            // D- low as "not idle" and would spin if reset kept driving it.
            if (!rst_seen) begin ug <= 0; up <= 0; um <= 0; end
        end
    end

    assign usb_dp = ug ? up : 1'bZ;
    assign usb_dm = ug ? um : 1'bZ;
    assign usb_oe = ug;
    assign sample = inst_ready & state == S_OPCODE & inst == 4'b1101 & timing == 4; // IN
    assign record = connected & ~nak;
    assign ukpstb = ~nrzon & ukprdy & (bitadr[2:0] == 3'b100) & (timing == 2);
endmodule

