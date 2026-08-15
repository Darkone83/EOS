// ===========================================================================
//  eos_exp_pkg.vh  —  EOS expansion gateware: single source of truth
// ===========================================================================
//  Every width / offset / opcode / limit here is transcribed from the frozen
//  EOS Expansion System spec and MUST equal the IDE's eos_language.LIMITS.
//  Nothing downstream may hard-code a literal — include this instead.
//
//  Plain Verilog `define macros (guarded) for maximum Gowin-toolchain and
//  simulator portability; the existing EOS modules are Verilog-2001 style.
// ===========================================================================
`ifndef EOS_EXP_PKG_VH
`define EOS_EXP_PKG_VH

// ---- Flash region & validity frame (spec 4.4) -----------------------------
`define EOS_REGION_SIZE     32'h0002_0000   // 0x20000, 2 x 64 KB erase
`define EOS_FRAME_SIZE      32'h0000_0010   // 16 B; text body starts at +0x10
`define EOS_MAX_TEXT_LEN    32'h0001_FFF0   // 131056 B = REGION - FRAME
`define EOS_MAGIC0          8'h45            // 'E'
`define EOS_MAGIC1          8'h4F            // 'O'
`define EOS_MAGIC2          8'h53            // 'S'
`define EOS_MAGIC3          8'h58            // 'X'
`define EOS_FMT_VER         8'h01
`define EOS_ABI_VER         8'h01

// ---- Hard limits (spec 4.9) ----------------------------------------------
`define EOS_MAX_PINDEFS         8
`define EOS_MAX_INSTRUCTIONS    4096
`define EOS_MAX_PAYLOAD_BYTES   16384        // 16 KB decoded
`define EOS_MAX_DEF             64
`define EOS_MAX_DATA            32
`define EOS_MAX_NAME_LEN        16
`define EOS_VOLATILE_SIZE       256
`define EOS_VOLATILE_TOP        8'hF8         // 0x00..0xF7 usable; 0xF8..0xFF reserved
`define EOS_RESULT_SLOT         8'hFF
`define EOS_MAX_BANK            32            // 2 + sum(REG widths)
`define EOS_MAX_REGS_PINDEF     16
`define EOS_MAX_READ_SCRATCH    64
`define EOS_WS_MAX_COUNT        1365
`define EOS_WS_MAX_FRAME        4095
`define EOS_I2CW_DATA_MAX       256
`define EOS_I2CR_MAX            64
`define EOS_LOOP_NEST_MAX       4
`define EOS_NUM_REGISTERS       8

// ---- Timing (spec 4.10) ---------------------------------------------------
`define EOS_DELAY_MAX           16'd65535
`define EOS_PWM_FREQ_MIN        1
`define EOS_PWM_FREQ_MAX        100000
`define EOS_PWM_DUTY_MAX        8'd255
`define EOS_I2C_RATE_HZ         100000
`define EOS_I2C_TIMEOUT_MS      1
`define EOS_OP_WATCHDOG_MS      500

// ---- Pin type codes  (descriptor TYPE byte, spec 4.5) ---------------------
`define EOS_TYPE_GPIO_IN    8'h00
`define EOS_TYPE_GPIO_OUT   8'h01
`define EOS_TYPE_PWM        8'h02
`define EOS_TYPE_WS2812     8'h03
`define EOS_TYPE_I2C        8'h04
`define EOS_TYPE_1WIRE      8'h05   // reserved V1.1

// ---- Opcodes (spec 4.3) ---------------------------------------------------
`define EOS_OP_NOP      8'h00
`define EOS_OP_SET      8'h01
`define EOS_OP_GET      8'h02
`define EOS_OP_DELAY    8'h03
`define EOS_OP_PWM      8'h04
`define EOS_OP_WS       8'h10
`define EOS_OP_I2CW     8'h20
`define EOS_OP_I2CR     8'h21
`define EOS_OP_OW_RESET 8'h30   // reserved
`define EOS_OP_OW_WR    8'h31   // reserved
`define EOS_OP_OW_RD    8'h32   // reserved
`define EOS_OP_GETMAIL  8'h40
`define EOS_OP_SETMAIL  8'h41
`define EOS_OP_LOOP     8'h50
`define EOS_OP_ENDLOOP  8'h51
`define EOS_OP_IFMAIL   8'h52
`define EOS_OP_END      8'h5F

// ---- Directive ids (parser-internal; not on any wire) ---------------------
`define EOS_DIR_NONE    8'h00
`define EOS_DIR_TARGET  8'h01
`define EOS_DIR_USES    8'h02
`define EOS_DIR_REG     8'h03
`define EOS_DIR_I2CADDR 8'h04
`define EOS_DIR_DEF     8'h05
`define EOS_DIR_DATA    8'h06

// ---- First-token classification (lexer output) ----------------------------
`define EOS_KW_UNKNOWN   2'd0
`define EOS_KW_DIRECTIVE 2'd1
`define EOS_KW_COMMAND   2'd2

// ---- Fault codes (spec 4.7) ----------------------------------------------
`define EOS_FAULT_NONE       8'h00
`define EOS_FAULT_BAD_CMD    8'h01
`define EOS_FAULT_BAD_PIN    8'h02
`define EOS_FAULT_LOOP_STACK 8'h03
`define EOS_FAULT_ARG_RANGE  8'h04
`define EOS_FAULT_TIMEOUT    8'h05
`define EOS_FAULT_PERIPHERAL 8'h06

// ---- Peripheral result codes (spec 4.8; RESULT slot 0xFF) -----------------
`define EOS_RES_OK        8'h00
`define EOS_RES_NACK_ADDR 8'h01
`define EOS_RES_NACK_DATA 8'h02
`define EOS_RES_TIMEOUT   8'h03
`define EOS_RES_STUCK     8'h04

// ---- Doorbell state enum (spec 5.3) ---------------------------------------
`define EOS_DB_IDLE     2'd0
`define EOS_DB_PENDING  2'd1
`define EOS_DB_BUSY     2'd2
`define EOS_DB_READY    2'd3

// ---- Physical EXP -> FPGA pin map (spec 1) --------------------------------
//  EXP1..8 = 52,53,49,55,48,51,54,56 ; EXP1..3 reserved under TARGET HD.
//  (Board constraint values; listed for reference — applied in the .cst file.)

// ---- Lexer sizing ---------------------------------------------------------
`define EOS_KW_MAXLEN    8      // longest first-token keyword ('I2C_ADDR')
`define EOS_ADDR_W       18     // byte address width within a 0x20000 region

`endif // EOS_EXP_PKG_VH
