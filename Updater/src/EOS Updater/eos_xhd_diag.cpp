// eos_xhd_diag.cpp -- X-HD/ADV7511 raw-register mode sweep.
//
// Sequence is intentionally simple and deterministic:
//   480p  -> solid black for 10 seconds -> dump ADV 00..FF
//   720p  -> solid black for 10 seconds -> dump ADV 00..FF
//   1080i -> solid black for 10 seconds -> dump ADV 00..FF
//
// The ADV reads go through EOS native SMBus address 0x6E.  X-HD compatibility
// address 0x69 is never touched by this diagnostic, so CerBIOS takeover remains
// free to operate normally while we observe the resulting ADV register state.
#include <xtl.h>
#include "eos_xhd_diag.h"
#include "eos_smbus.h"

#define DIAG_SETTLE_MS 10000

static const char kHex[] = "0123456789ABCDEF";

static BOOL wr_all(HANDLE h, const char* s, DWORD n)
{
    DWORD put = 0;
    if (h == INVALID_HANDLE_VALUE) return FALSE;
    if (!n) return TRUE;
    return WriteFile(h, s, n, &put, NULL) && put == n;
}

static BOOL wr_str(HANDLE h, const char* s)
{
    DWORD n = 0;
    while (s[n]) ++n;
    return wr_all(h, s, n);
}

static int append_hex8(char* d, int p, BYTE v)
{
    d[p++] = kHex[(v >> 4) & 0x0F];
    d[p++] = kHex[v & 0x0F];
    return p;
}

static int append_hex32(char* d, int p, DWORD v)
{
    int sh;
    for (sh = 28; sh >= 0; sh -= 4) d[p++] = kHex[(v >> sh) & 0x0F];
    return p;
}

static BOOL write_mode_header(HANDLE h, const char* name, HRESULT hr)
{
    char line[80];
    int p = 0, i = 0;
    line[p++] = '[';
    while (name[i] && p < 60) line[p++] = name[i++];
    line[p++] = ']'; line[p++] = '\r'; line[p++] = '\n';
    line[p++] = 'C'; line[p++] = 'R'; line[p++] = 'E'; line[p++] = 'A';
    line[p++] = 'T'; line[p++] = 'E'; line[p++] = '=';
    line[p++] = '0'; line[p++] = 'x';
    p = append_hex32(line, p, (DWORD)hr);
    line[p++] = '\r'; line[p++] = '\n';
    return wr_all(h, line, (DWORD)p);
}

static BOOL dump_adv_registers(HANDLE h, IDirect3DDevice8* dev)
{
    BYTE vals[256];
    BYTE ok[256];
    int r, row, col;

    for (r = 0; r < 256; ++r) {
        vals[r] = 0;
        ok[r] = Smb_AdvReadReg((BYTE)r, &vals[r]) ? 1 : 0;

        // Keep presenting the already-cleared black frame during the register
        // sweep so the requested video mode remains actively exercised.
        if (dev && ((r & 0x0F) == 0x0F)) dev->Present(NULL, NULL, NULL, NULL);
    }

    for (row = 0; row < 16; ++row) {
        char line[80];
        int p = 0;
        p = append_hex8(line, p, (BYTE)(row << 4));
        line[p++] = ':';
        for (col = 0; col < 16; ++col) {
            int idx = (row << 4) | col;
            line[p++] = ' ';
            if (ok[idx]) p = append_hex8(line, p, vals[idx]);
            else { line[p++] = '?'; line[p++] = '?'; }
        }
        line[p++] = '\r'; line[p++] = '\n';
        if (!wr_all(h, line, (DWORD)p)) return FALSE;
    }
    return wr_str(h, "\r\n");
}

static HRESULT create_mode(IDirect3D8* d3d, int w, int h, DWORD flags,
    IDirect3DDevice8** outDev)
{
    D3DPRESENT_PARAMETERS pp;
    ZeroMemory(&pp, sizeof(pp));
    pp.BackBufferWidth = w;
    pp.BackBufferHeight = h;
    pp.BackBufferFormat = D3DFMT_A8R8G8B8;
    pp.BackBufferCount = 1;
    pp.SwapEffect = D3DSWAPEFFECT_DISCARD;
    pp.EnableAutoDepthStencil = FALSE;
    pp.Flags = flags;
    pp.FullScreen_PresentationInterval = D3DPRESENT_INTERVAL_ONE;

    *outDev = NULL;
    return d3d->CreateDevice(0, D3DDEVTYPE_HAL, NULL,
        D3DCREATE_HARDWARE_VERTEXPROCESSING, &pp, outDev);
}

static void hold_black(IDirect3DDevice8* dev, DWORD ms)
{
    DWORD start = GetTickCount();
    if (!dev) return;
    while ((DWORD)(GetTickCount() - start) < ms) {
        dev->Clear(0, NULL, D3DCLEAR_TARGET, 0xFF000000, 1.0f, 0);
        dev->Present(NULL, NULL, NULL, NULL);
        Sleep(16);
    }
}

static BOOL run_one_mode(HANDLE h, IDirect3D8* d3d, const char* name,
    int w, int ht, DWORD flags)
{
    IDirect3DDevice8* dev = NULL;
    HRESULT hr = create_mode(d3d, w, ht, flags, &dev);
    BOOL ok = TRUE;

    if (!write_mode_header(h, name, hr)) ok = FALSE;

    if (SUCCEEDED(hr) && dev) {
        hold_black(dev, DIAG_SETTLE_MS);
        if (!dump_adv_registers(h, dev)) ok = FALSE;
        dev->Release();
    }
    else {
        if (!wr_str(h, "MODE CREATE FAILED - NO REGISTER DUMP\r\n\r\n")) ok = FALSE;
    }
    return ok;
}


static const char* trace_type_name(BYTE t)
{
    switch (t) {
    case 0x1: return "ADV-W";
    case 0x2: return "ADV-R";
    case 0x3: return "ADV-W-ERR";
    case 0x4: return "ADV-R-ERR";
    case 0x5: return "HD-CMD";
    case 0x6: return "HD-DATA";
    case 0x7: return "HD-DONE";
    case 0x8: return "HD-ABORT";
    case 0x9: return "XHD-RESET";
    case 0xA: return "BIOS-OWNER";
    default:  return "UNKNOWN";
    }
}

static BOOL dump_xhd_trace(HANDLE h)
{
    BYTE count = 0, head = 0, status = 0, version = 0;
    BYTE curBr = 0, curBios = 0, curVic = 0, curEnc = 0;
    BYTE i, type, br, bios, reg, data;
    char line[128];
    int p, k;
    const char* name;

    if (!Smb_AdvTraceRead(0xFF, 0, &count)) return FALSE;
    if (!Smb_AdvTraceRead(0xFF, 1, &head)) return FALSE;
    if (!Smb_AdvTraceRead(0xFF, 2, &status)) return FALSE;
    if (!Smb_AdvTraceRead(0xFF, 3, &version)) return FALSE;
    Smb_AdvTraceRead(0xFF, 4, &curBr);
    Smb_AdvTraceRead(0xFF, 5, &curBios);
    Smb_AdvTraceRead(0xFF, 6, &curVic);
    Smb_AdvTraceRead(0xFF, 7, &curEnc);

    if (!wr_str(h, "X-HD TRANSACTION TRACE\r\n")) return FALSE;
    p = 0;
    line[p++] = 'V'; line[p++] = 'E'; line[p++] = 'R'; line[p++] = '='; p = append_hex8(line, p, version);
    line[p++] = ' '; line[p++] = 'C'; line[p++] = 'O'; line[p++] = 'U'; line[p++] = 'N'; line[p++] = 'T'; line[p++] = '='; p = append_hex8(line, p, count);
    line[p++] = ' '; line[p++] = 'H'; line[p++] = 'E'; line[p++] = 'A'; line[p++] = 'D'; line[p++] = '='; p = append_hex8(line, p, head);
    line[p++] = ' '; line[p++] = 'S'; line[p++] = 'T'; line[p++] = 'A'; line[p++] = 'T'; line[p++] = 'U'; line[p++] = 'S'; line[p++] = '='; p = append_hex8(line, p, status);
    line[p++] = ' '; line[p++] = 'B'; line[p++] = 'R'; line[p++] = '='; p = append_hex8(line, p, curBr);
    line[p++] = ' '; line[p++] = 'B'; line[p++] = 'I'; line[p++] = 'O'; line[p++] = 'S'; line[p++] = '='; p = append_hex8(line, p, curBios);
    line[p++] = ' '; line[p++] = 'V'; line[p++] = 'I'; line[p++] = 'C'; line[p++] = '='; p = append_hex8(line, p, curVic);
    line[p++] = ' '; line[p++] = 'E'; line[p++] = 'N'; line[p++] = 'C'; line[p++] = '='; p = append_hex8(line, p, curEnc);
    line[p++] = '\r'; line[p++] = '\n';
    if (!wr_all(h, line, (DWORD)p)) return FALSE;
    if (!wr_str(h, "IDX TYPE       BR BIOS REG DATA\r\n")) return FALSE;

    for (i = 0; i < count && i < 64; ++i) {
        if (!Smb_AdvTraceRead(i, 0, &type) ||
            !Smb_AdvTraceRead(i, 1, &br) ||
            !Smb_AdvTraceRead(i, 2, &bios) ||
            !Smb_AdvTraceRead(i, 3, &reg) ||
            !Smb_AdvTraceRead(i, 4, &data)) return FALSE;

        p = 0;
        p = append_hex8(line, p, i); line[p++] = ' ';
        name = trace_type_name(type);
        for (k = 0; name[k] && k < 11; ++k) line[p++] = name[k];
        while (k++ < 11) line[p++] = ' ';
        p = append_hex8(line, p, br); line[p++] = ' ';
        p = append_hex8(line, p, bios); line[p++] = ' ';
        p = append_hex8(line, p, reg); line[p++] = ' ';
        p = append_hex8(line, p, data); line[p++] = '\r'; line[p++] = '\n';
        if (!wr_all(h, line, (DWORD)p)) return FALSE;
    }
    return wr_str(h, "\r\n");
}

BOOL XhdDiag_DumpCurrent(const char* outPath)
{
    HANDLE h;
    BOOL ok = TRUE;
    DWORD vflags = XGetVideoFlags();
    DWORD vstd = XGetVideoStandard();
    char line[64];
    int p = 0;

    if (!outPath) outPath = "D:\\adv7511_current.txt";

    h = CreateFileA(outPath, GENERIC_WRITE, 0, NULL,
        CREATE_ALWAYS, FILE_ATTRIBUTE_NORMAL, NULL);
    if (h == INVALID_HANDLE_VALUE) return FALSE;

    if (!wr_str(h,
        "EOS ADV7511 current-state register dump\r\n"
        "Video mode is NOT changed by this operation.\r\n"
        "Registers: 00-FF, raw live read values\r\n")) ok = FALSE;

    p = 0;
    line[p++] = 'X'; line[p++] = 'G'; line[p++] = 'e'; line[p++] = 't';
    line[p++] = 'V'; line[p++] = 'i'; line[p++] = 'd'; line[p++] = 'e';
    line[p++] = 'o'; line[p++] = 'F'; line[p++] = 'l'; line[p++] = 'a';
    line[p++] = 'g'; line[p++] = 's'; line[p++] = '='; line[p++] = '0'; line[p++] = 'x';
    p = append_hex32(line, p, vflags);
    line[p++] = '\r'; line[p++] = '\n';
    if (!wr_all(h, line, (DWORD)p)) ok = FALSE;

    p = 0;
    line[p++] = 'X'; line[p++] = 'G'; line[p++] = 'e'; line[p++] = 't';
    line[p++] = 'V'; line[p++] = 'i'; line[p++] = 'd'; line[p++] = 'e';
    line[p++] = 'o'; line[p++] = 'S'; line[p++] = 't'; line[p++] = 'a';
    line[p++] = 'n'; line[p++] = 'd'; line[p++] = 'a'; line[p++] = 'r';
    line[p++] = 'd'; line[p++] = '='; line[p++] = '0'; line[p++] = 'x';
    p = append_hex32(line, p, vstd);
    line[p++] = '\r'; line[p++] = '\n'; line[p++] = '\r'; line[p++] = '\n';
    if (!wr_all(h, line, (DWORD)p)) ok = FALSE;

    if (!dump_adv_registers(h, NULL)) ok = FALSE;
    if (!dump_xhd_trace(h)) ok = FALSE;
    if (!wr_str(h, "END\r\n")) ok = FALSE;

    CloseHandle(h);
    return ok;
}

BOOL XhdDiag_Run(const char* outPath)
{
    HANDLE h;
    IDirect3D8* d3d;
    BOOL ok = TRUE;
    DWORD vflags = XGetVideoFlags();
    DWORD f480 = D3DPRESENTFLAG_PROGRESSIVE;

    if (!outPath) outPath = "D:\\regs.txt";
    if (vflags & XC_VIDEO_FLAGS_WIDESCREEN) f480 |= D3DPRESENTFLAG_WIDESCREEN;

    h = CreateFileA(outPath, GENERIC_WRITE, 0, NULL,
        CREATE_ALWAYS, FILE_ATTRIBUTE_NORMAL, NULL);
    if (h == INVALID_HANDLE_VALUE) return FALSE;

    if (!wr_str(h,
        "EOS X-HD ADV7511 raw register sweep\r\n"
        "Settle before each dump: 10000 ms\r\n"
        "Registers: 00-FF, raw read values\r\n\r\n")) ok = FALSE;

    d3d = Direct3DCreate8(D3D_SDK_VERSION);
    if (!d3d) {
        wr_str(h, "Direct3DCreate8 failed\r\n");
        CloseHandle(h);
        return FALSE;
    }

    if (!run_one_mode(h, d3d, "480p", 640, 480, f480)) ok = FALSE;
    Sleep(250);
    if (!run_one_mode(h, d3d, "720p", 1280, 720,
        D3DPRESENTFLAG_PROGRESSIVE | D3DPRESENTFLAG_WIDESCREEN)) ok = FALSE;
    Sleep(250);
    if (!run_one_mode(h, d3d, "1080i", 1920, 1080,
        D3DPRESENTFLAG_INTERLACED | D3DPRESENTFLAG_WIDESCREEN)) ok = FALSE;

    d3d->Release();
    wr_str(h, "END\r\n");
    CloseHandle(h);
    return ok;
}
