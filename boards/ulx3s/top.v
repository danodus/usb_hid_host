//
// Example using the usb_hid_host core, for the ULX3S board
// devietti, 11/2024
//

module top (
    input	 clk_25mhz,

    // PWR button (BTN_PWRn). Active low; a short press resets the design.
    // Holding it for about a second still powers the board off.
    input	 btn_pwr_n,

    // UART output over US1 USB port
    output	 ftdi_rxd,

    // LEDs
    output [7:0] led,

    // US2 USB port. The bidirectional pair is the one the core drives.
    // usb_fpga_dp/dn are bonded to the same D+/D- nets; they must be
    // inputs with pull-ups off or the default weak pull-ups fight the
    // host 15k pulldowns.
    inout	 usb_fpga_bd_dn,
    inout	 usb_fpga_bd_dp,
    output   usb_fpga_pu_dp,
    output   usb_fpga_pu_dn
);

wire pll_locked;
wire clk_usb;
wire [1:0] usb_type;
wire [7:0] key_modifiers, key1, key2, key3, key4;
wire [7:0] mouse_btn;
wire signed [7:0] mouse_dx, mouse_dy;
wire [63:0] hid_report;
wire usb_report, usb_conerr, game_l, game_r, game_u, game_d, game_a, game_b, game_x, game_y;
wire game_sel, game_sta;
wire [13:0] dbg_pc;
wire [3:0] dbg_inst;

// Drive both pull pins low: 15k host pulldowns on, 1.1k device pull-ups off.
assign usb_fpga_pu_dp = 1'b0;
assign usb_fpga_pu_dn = 1'b0;

clock clock(
    .clkin(clk_25mhz),
    .clk12(clk_usb),       // 12Mhz usb clock
    .clk100(),
    .locked(pll_locked)
);

// Assert reset as soon as PWR is pressed. Release it 10 ms after the
// button has been stable high, so contact bounce does not restart USB.
reg [1:0] pwr_sync = 2'b11;
reg [16:0] pwr_cnt = 0;
reg pwr_released = 0;

always @(posedge clk_usb) begin
    pwr_sync <= {pwr_sync[0], btn_pwr_n};
    if (!pwr_sync[1]) begin
        pwr_cnt <= 0;
        pwr_released <= 0;
    end else if (!pwr_released) begin
        if (pwr_cnt == 17'd119999)
            pwr_released <= 1;
        else
            pwr_cnt <= pwr_cnt + 1'b1;
    end
end

wire sys_resetn = pll_locked & pwr_released;

usb_hid_host usb (
    .usbclk(clk_usb), .usbrst_n(sys_resetn),
    .usb_dm(usb_fpga_bd_dn), .usb_dp(usb_fpga_bd_dp),
    .typ(usb_type), .report(usb_report),
    .key_modifiers(key_modifiers), .key1(key1), .key2(key2), .key3(key3), .key4(key4),
    .mouse_btn(mouse_btn), .mouse_dx(mouse_dx), .mouse_dy(mouse_dy),
    .game_l(game_l), .game_r(game_r), .game_u(game_u), .game_d(game_d),
    .game_a(game_a), .game_b(game_b), .game_x(game_x), .game_y(game_y), 
    .game_sel(game_sel), .game_sta(game_sta),
    .conerr(usb_conerr), .dbg_hid_report(hid_report)
);

hid_printer prt (
    .clk(clk_usb), .resetn(sys_resetn),
    .uart_tx(ftdi_rxd), .usb_type(usb_type), .usb_report(usb_report),
    .key_modifiers(key_modifiers), .key1(key1), .key2(key2), .key3(key3), .key4(key4),
    .mouse_btn(mouse_btn), .mouse_dx(mouse_dx), .mouse_dy(mouse_dy),
    .game_l(game_l), .game_r(game_r), .game_u(game_u), .game_d(game_d),
    .game_a(game_a), .game_b(game_b), .game_x(game_x), .game_y(game_y), 
    .game_sel(game_sel), .game_sta(game_sta)
);

reg report_toggle;      // blinks whenever there's a report
always @(posedge clk_usb) if (usb_report) report_toggle <= ~report_toggle;

//    assign led[0] = report_toggle;
//    assign led[1] = usb_type;
//    assign led[2] = |usb_report;
//    assign led[3] = mouse_btn;
//    assign led[4] = |mouse_dx;
//    assign led[5] = |mouse_dy;
//    assign led[6] = |key_modifiers;
//    assign led[7] = |key1;

assign led[0] = (usb_type == 2'b11);
assign led[4:1] = {game_l, game_r, game_u, game_d};

endmodule
