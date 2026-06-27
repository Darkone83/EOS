//Copyright (C)2014-2026 Gowin Semiconductor Corporation.
//All rights reserved.
//File Title: Template file for instantiation
//Tool Version: V1.9.12.03 (64-bit)
//IP Version: 1.0
//Part Number: GW2AR-LV18QN88PC7/I6
//Device: GW2AR-18
//Device Version: C
//Created Time: Wed Jun 24 17:30:57 2026

//Change the instance name and port connections to the signal names
//--------Copy here to design--------

    sdram_pll your_instance_name(
        .clkout(clkout), //output clkout
        .lock(lock), //output lock
        .clkoutp(clkoutp), //output clkoutp
        .clkin(clkin), //input clkin
        .fbdsel(fbdsel), //input [5:0] fbdsel
        .idsel(idsel), //input [5:0] idsel
        .odsel(odsel) //input [5:0] odsel
    );

//--------Copy end-------------------
