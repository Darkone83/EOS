#pragma once
#pragma once
// eos_net.h -- tiny HTTP/1.0 GET client for pulling update images off the Eos
// server. The loader's eos_http is a *server*; this is the missing client half.
//
// Base URL is fixed to the Eos server; callers pass the leaf name:
//   Net_HttpGet("loader.bin",  buf, cap, &len)  -> GET .../EOS/loader.bin
//   Net_HttpGet("xbdlite.ver", buf, cap, &len)  -> GET .../EOS/xbdlite.ver
//
// Requires the network stack to be up (dd_net's Net_Start + resolved address).
// DNS is resolved with XNetDnsLookup (DDNS host), so a live link is required.
#include <xtl.h>

#define EOS_NET_HOST   "darkone83.myddns.me"
#define EOS_NET_PORT   8008
#define EOS_NET_BASE   "/EOS"        /* path prefix on the server */

/* result codes */
enum {
    NET_OK = 0,
    NET_ERR_DNS,          /* host would not resolve */
    NET_ERR_CONNECT,      /* TCP connect failed */
    NET_ERR_SEND,         /* request write failed */
    NET_ERR_HTTP,         /* non-200 status */
    NET_ERR_TRUNCATED,    /* fewer bytes than Content-Length */
    NET_ERR_TOOBIG,       /* body exceeds caller cap */
    NET_ERR_TIMEOUT       /* stalled */
};

/* GET EOS_NET_BASE/leaf into buf (up to cap). On NET_OK, *outlen = body bytes.
   leaf is just the filename ("loader.bin"); no leading slash needed. */
int Net_HttpGet(const char* leaf, unsigned char* buf, int cap, int* outlen);

const char* Net_ErrStr(int code);
int         Net_LastStatus(void);   /* last HTTP status seen (0 if none) */