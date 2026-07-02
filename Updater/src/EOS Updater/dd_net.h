/*---------------------------------------------------------------------------
    dd_net.h -- Xbox network bringup + local IP, for the status scroller and
    (later) FTP / updater. Ported from XbDiag SysInfo: XNetStartup with
    BYPASS_SECURITY, then non-blocking XNetGetTitleXnAddr polling for DHCP.
---------------------------------------------------------------------------*/
#ifndef DD_NET_H
#define DD_NET_H

void        Net_Start(void);   /* XNetStartup + WSAStartup once; kicks DHCP   */
void        Net_Poll(void);    /* one non-blocking address check; updates IP  */
const char* Net_Ip(void);      /* cached "192.168.x.x", or "No Link"          */
const char* Net_Subnet(void);  /* subnet mask, or "--"                        */
const char* Net_Gateway(void); /* default gateway, or "--"                    */
const char* Net_Dns(void);     /* primary DNS, or "--"                        */
const char* Net_Dns2(void);    /* secondary DNS, or "--"                      */
int         Net_IsUp(void);    /* 1 once an address has resolved              */
int         Net_LinkUp(void);  /* 1 if the Ethernet link is active            */

/* network mode for the config panel */
enum { DD_NET_DHCP = 0, DD_NET_STATIC = 1, DD_NET_DHCP_DNS = 2 };

/* Read the saved config (mode + packed IPv4 values, network byte order). */
void Net_LoadConfig(int* mode, unsigned long* ip, unsigned long* mask,
    unsigned long* gw, unsigned long* dns1, unsigned long* dns2);
/* Write the config to the network-config region and restart the stack.
   Returns 1 on success, 0 if the save was refused. */
int  Net_ApplyConfig(int mode, unsigned long ip, unsigned long mask,
    unsigned long gw, unsigned long dns1, unsigned long dns2);
void Net_Restart(void);        /* tear down + bring the stack back up         */

#endif /* DD_NET_H */