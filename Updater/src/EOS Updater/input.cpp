#include "input.h"
#include <string.h>

#define MAX_PORTS 4
#define ANALOG_THRESHOLD 30

static HANDLE g_padHandles[MAX_PORTS];
static WORD   g_padButtons[MAX_PORTS];

static void openPad(int port)
{
    if (port < 0 || port >= MAX_PORTS || g_padHandles[port]) return;
    g_padHandles[port] = XInputOpen(XDEVICE_TYPE_GAMEPAD, port, XDEVICE_NO_SLOT, NULL);
    g_padButtons[port] = 0;
}

static void closePad(int port)
{
    if (port < 0 || port >= MAX_PORTS) return;
    if (g_padHandles[port]) {
        XInputClose(g_padHandles[port]);
        g_padHandles[port] = NULL;
    }
    g_padButtons[port] = 0;
}

void InitInput()
{
    XDEVICE_PREALLOC_TYPE type;
    int i;

    ZeroMemory(&type, sizeof(type));
    type.DeviceType = XDEVICE_TYPE_GAMEPAD;
    type.dwPreallocCount = MAX_PORTS;
    XInitDevices(1, &type);

    memset(g_padHandles, 0, sizeof(g_padHandles));
    memset(g_padButtons, 0, sizeof(g_padButtons));

    // Probe every physical controller port immediately. XInputOpen returns NULL
    // for an empty port; hot-plug changes are handled by PumpInput afterward.
    for (i = 0; i < MAX_PORTS; ++i) openPad(i);
    PumpInput();
}

void PumpInput()
{
    DWORD ins = 0, rem = 0;
    int i;

    if (XGetDeviceChanges(XDEVICE_TYPE_GAMEPAD, &ins, &rem)) {
        for (i = 0; i < MAX_PORTS; ++i) {
            DWORD bit = (1u << i);
            if (rem & bit) closePad(i);
            if (ins & bit) openPad(i);
        }
    }

    for (i = 0; i < MAX_PORTS; ++i) {
        XINPUT_STATE st;
        WORD raw_w, mask;
        const BYTE* a;

        if (!g_padHandles[i]) {
            g_padButtons[i] = 0;
            continue;
        }

        ZeroMemory(&st, sizeof(st));
        if (XInputGetState(g_padHandles[i], &st) != ERROR_SUCCESS) {
            g_padButtons[i] = 0;
            continue;
        }

        // Genuine OG Xbox pads only use the low byte for digital controls.
        // Some third-party pads reuse upper wButtons bits, so exclude them from
        // the native mask and accept them only as explicit analog-button fallbacks.
        raw_w = st.Gamepad.wButtons;
        mask = raw_w & 0x00FF;
        a = st.Gamepad.bAnalogButtons;

        if (a[XINPUT_GAMEPAD_A] > ANALOG_THRESHOLD || (raw_w & 0x1000)) mask |= BTN_A;
        if (a[XINPUT_GAMEPAD_B] > ANALOG_THRESHOLD || (raw_w & 0x2000)) mask |= BTN_B;
        if (a[XINPUT_GAMEPAD_X] > ANALOG_THRESHOLD || (raw_w & 0x4000)) mask |= BTN_X;
        if (a[XINPUT_GAMEPAD_Y] > ANALOG_THRESHOLD || (raw_w & 0x8000)) mask |= BTN_Y;
        if (a[XINPUT_GAMEPAD_BLACK] > ANALOG_THRESHOLD || (raw_w & 0x0100)) mask |= BTN_BLACK;
        if (a[XINPUT_GAMEPAD_WHITE] > ANALOG_THRESHOLD || (raw_w & 0x0200)) mask |= BTN_WHITE;
        if (a[XINPUT_GAMEPAD_LEFT_TRIGGER] > ANALOG_THRESHOLD || (raw_w & 0x0400)) mask |= BTN_LTRIG;
        if (a[XINPUT_GAMEPAD_RIGHT_TRIGGER] > ANALOG_THRESHOLD || (raw_w & 0x0800)) mask |= BTN_RTRIG;

        g_padButtons[i] = mask;
    }
}

WORD GetButtons()
{
    WORD buttons = 0;
    int i;
    for (i = 0; i < MAX_PORTS; ++i) buttons |= g_padButtons[i];
    return buttons;
}
