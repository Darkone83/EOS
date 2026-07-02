// eos_net.cpp -- see eos_net.h. HTTP/1.0 GET on winsock; DNS via XNetDnsLookup.
#include <xtl.h>
#include "eos_net.h"

#define RECV_TIMEOUT_MS   15000
#define DNS_TIMEOUT_MS    5000

/* ---- tiny string helpers (no CRT) ----------------------------------------- */
static int s_len(const char* s) { int n = 0; while (s[n]) ++n; return n; }

static int s_lastStatus = 0;   /* last HTTP status line code, for diagnostics */

static int s_cat(char* d, int cap, int at, const char* s)
{
    int i = 0;
    while (s[i] && at < cap - 1) { d[at++] = s[i++]; }
    d[at] = 0;
    return at;
}

/* case-insensitive find of needle in [p,end); returns ptr or 0 */
static const char* find_ci(const char* p, const char* end, const char* needle)
{
    int nlen = s_len(needle), i;
    while (p + nlen <= end) {
        for (i = 0; i < nlen; ++i) {
            char a = p[i], b = needle[i];
            if (a >= 'A' && a <= 'Z') a = (char)(a + 32);
            if (b >= 'A' && b <= 'Z') b = (char)(b + 32);
            if (a != b) break;
        }
        if (i == nlen) return p;
        ++p;
    }
    return 0;
}

static int parse_int(const char* p, const char* end)
{
    int v = 0;
    while (p < end && *p >= '0' && *p <= '9') { v = v * 10 + (*p - '0'); ++p; }
    return v;
}

/* ---- DNS (XNetDnsLookup) --------------------------------------------------- */
static BOOL resolve_host(const char* host, DWORD* ip_out)
{
    XNDNS* pdns = 0;
    int    waited;
    INT    r = XNetDnsLookup(host, NULL, &pdns);
    if (r != 0 || !pdns) return FALSE;

    for (waited = 0; waited < DNS_TIMEOUT_MS; waited += 10) {
        if (pdns->iStatus != WSAEINPROGRESS) break;
        Sleep(10);
    }
    if (pdns->iStatus == 0 && pdns->cina > 0) {
        *ip_out = pdns->aina[0].S_un.S_addr;
        XNetDnsRelease(pdns);
        return TRUE;
    }
    XNetDnsRelease(pdns);
    return FALSE;
}

/* recv one chunk with a wall-clock bound; returns bytes (>0), 0 on close/timeout. */
static int recv_chunk(SOCKET s, char* dst, int want, DWORD deadline)
{
    for (;;) {
        int r = recv(s, dst, want, 0);
        if (r > 0) return r;
        if (r == 0) return 0;                       /* peer closed */
        if (GetTickCount() > deadline) return 0;    /* stalled */
        Sleep(2);
    }
}

/* ---- public --------------------------------------------------------------- */
int Net_HttpGet(const char* leaf, unsigned char* buf, int cap, int* outlen)
{
    DWORD          ip;
    SOCKET         s;
    struct sockaddr_in sa;
    unsigned long  nb = 1;
    char           req[256];
    char           hbuf[2048];       /* headers only; small and bounded */
    int            at, sent, hlen, hdr_end, status, clen, binit, bodylen;
    const char* hend;
    const char* p;
    DWORD          deadline;

    if (outlen) *outlen = 0;
    if (!leaf || !buf || cap <= 0) return NET_ERR_HTTP;

    if (!resolve_host(EOS_NET_HOST, &ip)) return NET_ERR_DNS;

    s = socket(AF_INET, SOCK_STREAM, IPPROTO_TCP);
    if (s == INVALID_SOCKET) return NET_ERR_CONNECT;

    sa.sin_family = AF_INET;
    sa.sin_port = htons((unsigned short)EOS_NET_PORT);
    sa.sin_addr.S_un.S_addr = ip;
    if (connect(s, (struct sockaddr*)&sa, sizeof(sa)) != 0) {
        closesocket(s);
        return NET_ERR_CONNECT;
    }
    ioctlsocket(s, FIONBIO, &nb);                    /* non-blocking + poll */

    /* build "GET /EOS/<leaf> HTTP/1.0\r\nHost: ..\r\nConnection: close\r\n\r\n" */
    at = 0;
    at = s_cat(req, sizeof(req), at, "GET ");
    at = s_cat(req, sizeof(req), at, EOS_NET_BASE);
    at = s_cat(req, sizeof(req), at, "/");
    at = s_cat(req, sizeof(req), at, leaf);
    at = s_cat(req, sizeof(req), at, " HTTP/1.0\r\nHost: ");
    at = s_cat(req, sizeof(req), at, EOS_NET_HOST);
    at = s_cat(req, sizeof(req), at, "\r\nConnection: close\r\n\r\n");

    sent = send(s, req, at, 0);
    if (sent != at) { closesocket(s); return NET_ERR_SEND; }

    deadline = GetTickCount() + RECV_TIMEOUT_MS;

    /* --- phase 1: accumulate headers into hbuf until the blank line --- */
    hlen = 0; hdr_end = -1;
    while (hlen < (int)sizeof(hbuf) - 1) {
        int r = recv_chunk(s, hbuf + hlen, (int)sizeof(hbuf) - 1 - hlen, deadline);
        if (r <= 0) break;
        hlen += r;
        hend = find_ci(hbuf, hbuf + hlen, "\r\n\r\n");
        if (hend) { hdr_end = (int)((hend + 4) - hbuf); break; }
    }
    if (hdr_end < 0) { closesocket(s); return NET_ERR_HTTP; }

    /* status line "HTTP/1.x NNN" */
    p = find_ci(hbuf, hbuf + hdr_end, "HTTP/");
    if (!p) { closesocket(s); return NET_ERR_HTTP; }
    while (p < hbuf + hdr_end && *p != ' ') ++p;
    status = parse_int(p + 1, hbuf + hdr_end);
    s_lastStatus = status;
    if (status != 200) { closesocket(s); return NET_ERR_HTTP; }

    /* optional Content-Length */
    clen = -1;
    {
        const char* cl = find_ci(hbuf, hbuf + hdr_end, "Content-Length:");
        if (cl) { cl += s_len("Content-Length:"); while (*cl == ' ') ++cl; clen = parse_int(cl, hbuf + hdr_end); }
    }
    if (clen > cap) { closesocket(s); return NET_ERR_TOOBIG; }

    /* --- phase 2: body. bytes already read past the header go first --- */
    binit = hlen - hdr_end;
    if (binit > cap) { closesocket(s); return NET_ERR_TOOBIG; }
    {
        int i;
        for (i = 0; i < binit; ++i) buf[i] = (unsigned char)hbuf[hdr_end + i];
    }
    bodylen = binit;
    while (bodylen < cap) {
        int r = recv_chunk(s, (char*)buf + bodylen, cap - bodylen, deadline);
        if (r <= 0) break;
        bodylen += r;
    }
    closesocket(s);

    if (clen >= 0 && bodylen < clen) return NET_ERR_TRUNCATED;
    if (clen >= 0) bodylen = clen;
    if (outlen) *outlen = bodylen;
    return NET_OK;
}

int Net_LastStatus(void) { return s_lastStatus; }

const char* Net_ErrStr(int code)
{
    switch (code) {
    case NET_OK:            return "OK";
    case NET_ERR_DNS:       return "Server name would not resolve.";
    case NET_ERR_CONNECT:   return "Could not connect to server.";
    case NET_ERR_SEND:      return "Request failed to send.";
    case NET_ERR_HTTP: {
        static char m[40];
        if (s_lastStatus > 0) {
            int v = s_lastStatus, at = 0; char d[8]; int n = 0;
            const char* pre = "Server error (HTTP ";
            while (pre[at]) { m[at] = pre[at]; ++at; }
            if (v == 0) d[n++] = '0';
            else { char t[8]; int k = 0; while (v > 0) { t[k++] = (char)('0' + v % 10); v /= 10; } while (k > 0) d[n++] = t[--k]; }
            { int i; for (i = 0; i < n && at < 38; ++i) m[at++] = d[i]; }
            if (at < 38) m[at++] = ')';
            m[at] = 0;
            return m;
        }
        return "Server returned an error.";
    }
    case NET_ERR_TRUNCATED: return "Download was incomplete.";
    case NET_ERR_TOOBIG:    return "File too large for buffer.";
    case NET_ERR_TIMEOUT:   return "Download timed out.";
    default:                return "Unknown network error.";
    }
}