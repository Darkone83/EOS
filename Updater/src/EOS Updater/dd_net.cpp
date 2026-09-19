/*---------------------------------------------------------------------------
    dd_net.cpp -- minimal updater network bringup.

    The updater only needs link/address-ready state for its HTTP client. Keep
    the stack bringup and cable-reconnect DHCP behavior, but omit the Loader's
    IP formatting and network-configuration editor surface.
---------------------------------------------------------------------------*/
#include <xtl.h>
#include <winsockx.h>
#include "dd_net.h"

static int s_up = 0;
static int s_link = 0;
static int s_lastLink = -1;
static int s_started = 0;

void Net_Start(void)
{
    XNetStartupParams xnsp;
    WSADATA wsa;
    if (s_started) return;

    ZeroMemory(&xnsp, sizeof(xnsp));
    xnsp.cfgSizeOfStruct = sizeof(xnsp);
    xnsp.cfgFlags = XNET_STARTUP_BYPASS_SECURITY;
    XNetStartup(&xnsp);
    WSAStartup(MAKEWORD(2, 2), &wsa);
    s_started = 1;
}

static void Net_Restart(void)
{
    if (s_started) {
        WSACleanup();
        XNetCleanup();
        s_started = 0;
    }
    s_up = 0;
    Net_Start();
}

void Net_Poll(void)
{
    XNADDR xna;
    DWORD st;

    if (!s_started) return;
    s_link = (XNetGetEthernetLinkStatus() & XNET_ETHERNET_LINK_ACTIVE) ? 1 : 0;

    if (s_lastLink != -1 && s_link != s_lastLink) {
        if (!s_link) {
            s_up = 0;
        }
        else {
            s_up = 0;
            Net_Restart();
            s_lastLink = s_link;
            return;
        }
    }
    s_lastLink = s_link;

    if (!s_link) { s_up = 0; return; }

    ZeroMemory(&xna, sizeof(xna));
    st = XNetGetTitleXnAddr(&xna);
    if (st == XNET_GET_XNADDR_PENDING) return;
    s_up = (!(st & XNET_GET_XNADDR_NONE) && xna.ina.s_addr != 0) ? 1 : 0;
}

int Net_IsUp(void) { return s_up; }
