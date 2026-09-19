// eos_gfx.cpp -- D3D8 2D layer (NV2A-correct: swizzled A8R8G8B8 + XGSwizzleRect).
// Matches the proven XbTyrian/ScorchedXB/XbDiag pattern:
//   - swizzled D3DFMT_A8R8G8B8 textures (LIN_* does NOT render on NV2A)
//   - XGSwizzleRect to convert linear CPU pixels -> swizzled GPU texture
//   - FVF has NO DIFFUSE (NV2A locks on DrawPrimitiveUP w/ LIN+DIFFUSE); tint is
//     applied via D3DRS_TEXTUREFACTOR + D3DTA_TFACTOR instead.
#include "eos_gfx.h"

IDirect3DDevice8* g_dev = 0;
int         g_scrW = 640;   // DESIGN-space width  (layout authored here)
int         g_scrH = 480;   // DESIGN-space height (layout authored here)
BOOL        g_isWide = FALSE;
const char* g_videoMode = "480i";
// Backbuffer scale/offset: the 640x480 design space is scaled (pillarbox for HD)
// onto the real backbuffer, so 720p renders natively instead of a 480p upscale.
float       g_sx = 1.0f;
float       g_sy = 1.0f;
int         g_ox = 0;
int         g_oy = 0;
static IDirect3D8* s_d3d = 0;
static IDirect3DTexture8* s_white = 0;   // 1x1 white, for solid fills
static IDirect3DTexture8* s_glowTex = 0;   // 64x64 radial glow sprite
static IDirect3DTexture8* s_ballTex = 0;   // 64x64 lit sphere (3D orbs)
static DWORD              s_glowPix[64 * 64];
static DWORD              s_baseFilter = D3DTEXF_POINT;   // LINEAR when HD-scaled

// Pre-transformed, single-texture vertex. NO diffuse channel.
struct QVtx { float x, y, z, rhw; float u, v; };
#define QFVF (D3DFVF_XYZRHW | D3DFVF_TEX1)

static void SetState2D()
{
    g_dev->SetVertexShader(QFVF);
    g_dev->SetRenderState(D3DRS_ZENABLE, FALSE);
    g_dev->SetRenderState(D3DRS_LIGHTING, FALSE);
    g_dev->SetRenderState(D3DRS_CULLMODE, D3DCULL_NONE);
    g_dev->SetRenderState(D3DRS_ALPHABLENDENABLE, TRUE);
    g_dev->SetRenderState(D3DRS_SRCBLEND, D3DBLEND_SRCALPHA);
    g_dev->SetRenderState(D3DRS_DESTBLEND, D3DBLEND_INVSRCALPHA);
    // tint = texture * TFACTOR (TFACTOR set per-draw to the requested color)
    g_dev->SetTextureStageState(0, D3DTSS_COLOROP, D3DTOP_MODULATE);
    g_dev->SetTextureStageState(0, D3DTSS_COLORARG1, D3DTA_TEXTURE);
    g_dev->SetTextureStageState(0, D3DTSS_COLORARG2, D3DTA_TFACTOR);
    g_dev->SetTextureStageState(0, D3DTSS_ALPHAOP, D3DTOP_MODULATE);
    g_dev->SetTextureStageState(0, D3DTSS_ALPHAARG1, D3DTA_TEXTURE);
    g_dev->SetTextureStageState(0, D3DTSS_ALPHAARG2, D3DTA_TFACTOR);
    // Default filter: POINT at native 480 (pixel-exact), LINEAR when the design
    // space is scaled up to an HD backbuffer so glyphs/pills don't look blocky.
    g_dev->SetTextureStageState(0, D3DTSS_MINFILTER, s_baseFilter);
    g_dev->SetTextureStageState(0, D3DTSS_MAGFILTER, s_baseFilter);
}

// Per-draw filter override. linear=TRUE for the logo's smooth gradient; FALSE
// restores the base filter (POINT at 480, LINEAR when HD-scaled).
void Gfx_SetFilter(BOOL linear)
{
    DWORD m = linear ? D3DTEXF_LINEAR : s_baseFilter;
    g_dev->SetTextureStageState(0, D3DTSS_MINFILTER, m);
    g_dev->SetTextureStageState(0, D3DTSS_MAGFILTER, m);
}

bool Gfx_Init()
{
    s_d3d = Direct3DCreate8(D3D_SDK_VERSION);
    if (!s_d3d) return false;

    // --- Detect the console's AV configuration (DarkDash/XbDiag pattern). ---
    // Honor the encoder's flags for signal type + aspect, but keep a fixed
    // 640-wide design-space backbuffer; the NV2A scales it to the real output.
    // Priority: 720p > 1080i > 480p > 576i (PAL-I 50Hz) > 480i (NTSC/PAL-M/PAL60).
    DWORD vidStd = XGetVideoStandard();
    DWORD vidFlags = XGetVideoFlags();

    BOOL  isPAL_I = (vidStd == XC_VIDEO_STANDARD_PAL_I);
    BOOL  hasPAL60 = (vidFlags & XC_VIDEO_FLAGS_PAL_60Hz) != 0;
    BOOL  truePAL50 = (isPAL_I && !hasPAL60);

    DWORD ppFlags = 0;
    int   bbW = 640;
    int   bbH = 480;

    if (vidFlags & XC_VIDEO_FLAGS_HDTV_720p) {
        ppFlags = D3DPRESENTFLAG_PROGRESSIVE | D3DPRESENTFLAG_WIDESCREEN;
        bbW = 1280; bbH = 720; g_videoMode = "720p";
    }
    else if (vidFlags & XC_VIDEO_FLAGS_HDTV_1080i) {
        ppFlags = D3DPRESENTFLAG_INTERLACED | D3DPRESENTFLAG_WIDESCREEN;
        bbW = 1920; bbH = 1080; g_videoMode = "1080i";
    }
    else if (vidFlags & XC_VIDEO_FLAGS_HDTV_480p) {
        ppFlags = D3DPRESENTFLAG_PROGRESSIVE;
        g_videoMode = "480p";
    }
    else if (truePAL50) {
        // True PAL-I 576i 50Hz: 4:3 backbuffer is 640x576, interlaced.
        ppFlags = D3DPRESENTFLAG_INTERLACED;
        bbH = 576; g_videoMode = "576i";
    }
    else {
        // NTSC 480i / PAL-M / PAL-60: interlaced default, no flag.
        g_videoMode = "480i";
    }
    // g_isWide reflects the console's EEPROM aspect (16:9 vs 4:3). The HD signal
    // flag above is separate -- a 720p signal is physically 16:9, but the console
    // may still be set to 4:3, in which case we pillarbox the 4:3 content.
    if (vidFlags & XC_VIDEO_FLAGS_WIDESCREEN) {
        ppFlags |= D3DPRESENTFLAG_WIDESCREEN; g_isWide = TRUE;
    }

    // Design space is ALWAYS 640x480; the backbuffer is the native mode size.
    // SD (<=640 wide) fills the frame; HD pillarboxes the 4:3 design so the logo
    // stays round. All draws are scaled by (g_sx,g_sy) + offset (g_ox,g_oy).
    g_scrW = 640; g_scrH = 480;

    D3DPRESENT_PARAMETERS pp;
    ZeroMemory(&pp, sizeof(pp));
    pp.BackBufferWidth = bbW;
    pp.BackBufferHeight = bbH;
    pp.BackBufferFormat = D3DFMT_A8R8G8B8;
    pp.BackBufferCount = 1;
    pp.SwapEffect = D3DSWAPEFFECT_DISCARD;
    pp.EnableAutoDepthStencil = TRUE;              // Darkone83 model needs depth
    pp.AutoDepthStencilFormat = D3DFMT_D24S8;
    pp.Flags = ppFlags;
    pp.FullScreen_PresentationInterval = D3DPRESENT_INTERVAL_ONE;

    HRESULT hr = s_d3d->CreateDevice(0, D3DDEVTYPE_HAL, NULL,
        D3DCREATE_HARDWARE_VERTEXPROCESSING, &pp, &g_dev);
    if (FAILED(hr) || !g_dev) {
        // HD mode rejected (e.g. VRAM) -> fall back to 640x480 480p/480i.
        bbW = 640; bbH = 480; g_videoMode = "480p";
        pp.BackBufferWidth = 640; pp.BackBufferHeight = 480;
        pp.Flags = D3DPRESENTFLAG_PROGRESSIVE;
        hr = s_d3d->CreateDevice(0, D3DDEVTYPE_HAL, NULL,
            D3DCREATE_HARDWARE_VERTEXPROCESSING, &pp, &g_dev);
        if (FAILED(hr) || !g_dev) return false;
    }

    // Compute design->backbuffer scale, honoring the EEPROM aspect.
    // Integer offsets only -- no float->int casts (this project has no __ftol2_sse).
    //   SD               : render 1:1 to the buffer; the WIDESCREEN present flag
    //                      lets the TV stretch a 4:3 buffer for anamorphic 16:9.
    //   HD + widescreen  : fill the 16:9 frame (content uses the full width).
    //   HD + 4:3         : pillarbox the 4:3 design (bars on the sides).
    if (bbW <= 640) {
        g_sx = (float)bbW / 640.0f; g_sy = (float)bbH / 480.0f; g_ox = 0; g_oy = 0;
    }
    else if (g_isWide) {
        g_sx = (float)bbW / 640.0f; g_sy = (float)bbH / 480.0f; g_ox = 0; g_oy = 0;
    }
    else {
        int scaledW, scaledH;
        if (bbW * 480 < bbH * 640) {              // width-limited
            scaledW = bbW;                  scaledH = bbW * 480 / 640;
            g_sx = g_sy = (float)bbW / 640.0f;
        }
        else {                                  // height-limited (typical 16:9)
            scaledH = bbH;                  scaledW = bbH * 640 / 480;
            g_sx = g_sy = (float)bbH / 480.0f;
        }
        g_ox = (bbW - scaledW) / 2;               // integer math, no ftol
        g_oy = (bbH - scaledH) / 2;
    }
    s_baseFilter = (g_sx > 1.01f || g_sy > 1.01f) ? D3DTEXF_LINEAR : D3DTEXF_POINT;

    DWORD wpx = 0xFFFFFFFF;
    s_white = Gfx_CreateTexARGB(1, 1, &wpx);

    // Radial glow sprite: white RGB, smooth quadratic alpha falloff to 0 at the
    // edge. Drawn additive + LINEAR-scaled, it gives a smooth ambient light blob
    // (no concentric banding). Integer math only -- no __ftol2_sse.
    {
        int gx, gy, r2 = 32 * 32;
        for (gy = 0; gy < 64; ++gy)
            for (gx = 0; gx < 64; ++gx) {
                int dx = gx - 32, dy = gy - 32, d2 = dx * dx + dy * dy, a;
                if (d2 >= r2) a = 0;
                else { int lin = (r2 - d2) * 255 / r2; a = lin * lin / 255; }
                s_glowPix[gy * 64 + gx] = ((DWORD)a << 24) | 0x00FFFFFF;
            }
        s_glowTex = Gfx_CreateTexARGB(64, 64, s_glowPix);
    }

    // 3D pill end-caps are geometry now (see Gfx_PillX3D), so there is no
    // filtered half-disc texture or cap/body sampling seam to initialize.

    // Lit-sphere impostor for the 3D orbs: per-pixel surface normal of a sphere,
    // shaded by a fixed upper-left/front light (N.L diffuse + ambient), with a
    // soft rim alpha. RGB carries the shading (grayscale); the orb's color tints
    // it at draw time. This is what makes the background balls read as round 3D
    // objects instead of flat glow sprites. Newton sqrt (init-time, no libm).
    {
        int bx, by;
        for (by = 0; by < 64; ++by)
            for (bx = 0; bx < 64; ++bx) {
                float fx = ((float)bx - 31.5f) / 30.0f;   // -1..1 across the disc
                float fy = ((float)by - 31.5f) / 30.0f;
                float r2 = fx * fx + fy * fy, z, d, lum;
                int a, L;
                if (r2 >= 1.0f) { s_glowPix[by * 64 + bx] = 0; continue; }
                z = 1.0f - r2;                            // z = sqrt(1 - r2)
                { float gx = z + 0.001f; int it; for (it = 0; it < 6; ++it) gx = 0.5f * (gx + z / gx); z = gx; }
                d = fx * (-0.5f) + fy * (-0.5f) + z * 0.70711f;   // N.L, L unit upper-left/front
                if (d < 0.0f) d = 0.0f;
                lum = 0.20f + 0.80f * d;                  // ambient + diffuse
                if (lum > 1.0f) lum = 1.0f;
                L = (int)(lum * 255.0f);
                a = 255;
                if (r2 > 0.80f) a = (int)((1.0f - (r2 - 0.80f) * 5.0f) * 255.0f);   // soft rim
                if (a < 0) a = 0;
                s_glowPix[by * 64 + bx] = ((DWORD)a << 24) | ((DWORD)L << 16) | ((DWORD)L << 8) | (DWORD)L;
            }
        s_ballTex = Gfx_CreateTexARGB(64, 64, s_glowPix);
    }
    return (s_white != 0);
}

void Gfx_Shutdown()
{
    if (s_ballTex) { s_ballTex->Release(); s_ballTex = 0; }
    if (s_glowTex) { s_glowTex->Release(); s_glowTex = 0; }
    if (s_white) { s_white->Release(); s_white = 0; }
    if (g_dev) { g_dev->Release();   g_dev = 0; }
    if (s_d3d) { s_d3d->Release();   s_d3d = 0; }
}

void Gfx_Begin(DWORD clear_argb)
{
    g_dev->Clear(0, NULL, D3DCLEAR_TARGET | D3DCLEAR_ZBUFFER, clear_argb, 1.0f, 0);
    g_dev->BeginScene();
    SetState2D();
}

void Gfx_End()
{
    g_dev->EndScene();
    g_dev->Present(NULL, NULL, NULL, NULL);
}

// Swizzled A8R8G8B8 texture from a linear CPU ARGB buffer (XGSwizzleRect).
IDirect3DTexture8* Gfx_CreateTexARGB(int w, int h, const DWORD* pixels)
{
    IDirect3DTexture8* tex = 0;
    HRESULT hr = g_dev->CreateTexture(w, h, 1, 0, D3DFMT_A8R8G8B8, 0, &tex);
    if (FAILED(hr) || !tex) return 0;

    D3DLOCKED_RECT lr;
    if (FAILED(tex->LockRect(0, &lr, NULL, 0))) { tex->Release(); return 0; }
    // linear src (w*4 pitch) -> swizzled dst expected by NV2A
    XGSwizzleRect(pixels, w * 4, NULL, lr.pBits, w, h, NULL, 4);
    tex->UnlockRect(0);
    return tex;
}

static void DrawQuadUV(IDirect3DTexture8* tex, float x, float y, float w, float h,
    float u0, float v0, float u1, float v1, DWORD c)
{
    QVtx v[4];
    v[0].x = g_ox + x * g_sx;       v[0].y = g_oy + y * g_sy;       v[0].u = u0; v[0].v = v0;
    v[1].x = g_ox + (x + w) * g_sx;   v[1].y = g_oy + y * g_sy;       v[1].u = u1; v[1].v = v0;
    v[2].x = g_ox + x * g_sx;       v[2].y = g_oy + (y + h) * g_sy;   v[2].u = u0; v[2].v = v1;
    v[3].x = g_ox + (x + w) * g_sx;   v[3].y = g_oy + (y + h) * g_sy;   v[3].u = u1; v[3].v = v1;
    for (int i = 0; i < 4; ++i) { v[i].z = 0.0f; v[i].rhw = 1.0f; }
    g_dev->SetRenderState(D3DRS_TEXTUREFACTOR, c);   // tint
    g_dev->SetTexture(0, tex);
    g_dev->DrawPrimitiveUP(D3DPT_TRIANGLESTRIP, 2, v, sizeof(QVtx));
}

void Gfx_DrawTex(IDirect3DTexture8* tex, float x, float y, float w, float h,
    float u0, float v0, float u1, float v1, DWORD color)
{
    DrawQuadUV(tex, x, y, w, h, u0, v0, u1, v1, color);
}

void Gfx_Fill(float x, float y, float w, float h, DWORD color)
{
    DrawQuadUV(s_white, x, y, w, h, 0, 0, 1, 1, color);
}

// --- rounded pill ----------------------------------------------------------
// Corners are drawn as solid triangle fans (pure geometry) rather than a
// scaled/mirrored mask texture: UV-mirroring a corner mask with bilinear
// filtering leaves a half-texel offset that shows up as faint seams. Fans share
// exact integer edges with the body fills, so there are no seams at all.

// Unit quarter-arc, cos/sin * 1024 over 0..90 deg (17 samples = 16 facets).
// The denser fan smooths large title/pill radii without another texture.
static const int k_arc[17][2] = {
    {1024,0},{1019,100},{1004,200},{980,298},{946,392},{904,482},{851,569},{789,650},{724,724},
    {650,789},{569,851},{482,904},{392,946},{298,980},{200,1004},{100,1019},{0,1024}
};

static void cornerFan(int cx, int cy, int r, int sx, int sy, DWORD color)
{
    QVtx v[18];
    int i;
    v[0].x = g_ox + (float)cx * g_sx; v[0].y = g_oy + (float)cy * g_sy;
    for (i = 0; i < 17; ++i) {
        v[i + 1].x = g_ox + (float)(cx + sx * (r * k_arc[i][0]) / 1024) * g_sx;
        v[i + 1].y = g_oy + (float)(cy + sy * (r * k_arc[i][1]) / 1024) * g_sy;
    }
    for (i = 0; i < 18; ++i) {
        v[i].z = 0.0f; v[i].rhw = 1.0f; v[i].u = 0.0f; v[i].v = 0.0f;
    }
    g_dev->SetRenderState(D3DRS_TEXTUREFACTOR, color);
    g_dev->SetTexture(0, s_white);
    g_dev->DrawPrimitiveUP(D3DPT_TRIANGLEFAN, 16, v, sizeof(QVtx));
}

void Gfx_FillRounded(int x, int y, int w, int h, int r, DWORD color)
{
    int maxr = (w < h ? w : h) / 2;
    if (r > maxr) r = maxr;
    if (r < 1) { Gfx_Fill((float)x, (float)y, (float)w, (float)h, color); return; }

    // Body: middle full-height band + the two side bands between the corners.
    Gfx_Fill((float)(x + r), (float)y, (float)(w - 2 * r), (float)h, color);
    Gfx_Fill((float)x, (float)(y + r), (float)r, (float)(h - 2 * r), color);
    Gfx_Fill((float)(x + w - r), (float)(y + r), (float)r, (float)(h - 2 * r), color);

    // Four rounded corners.
    cornerFan(x + r, y + r, r, -1, -1, color);   // TL
    cornerFan(x + w - r, y + r, r, +1, -1, color);   // TR
    cornerFan(x + r, y + h - r, r, -1, +1, color);   // BL
    cornerFan(x + w - r, y + h - r, r, +1, +1, color);   // BR
}

// Seam-free 2D capsule. Unlike Gfx_FillRounded(), this is one convex polygon
// and therefore has no internal body/corner boundaries for alpha/MSAA to expose.
void Gfx_FillCapsule(int x, int y, int w, int h, DWORD color)
{
    QVtx v[68];
    float cx, cy, hw, hh, mid, lx, ly;
    int n, i;

    if (w <= 0 || h <= 0) return;
    if (w < h) { Gfx_FillRounded(x, y, w, h, w / 2, color); return; }

    cx = (float)x + (float)w * 0.5f;
    cy = (float)y + (float)h * 0.5f;
    hw = (float)w * 0.5f;
    hh = (float)h * 0.5f;
    mid = hw - hh;

    n = 0;
    v[n].x = g_ox + cx * g_sx;
    v[n].y = g_oy + cy * g_sy;
    v[n].z = 0.0f; v[n].rhw = 1.0f; v[n].u = 0.0f; v[n].v = 0.0f; ++n;

    // Left semicircle: top seam -> leftmost -> bottom seam.
    for (i = 16; i >= 0; --i) {
        lx = -mid - hh * (float)k_arc[i][0] / 1024.0f;
        ly = hh * (float)k_arc[i][1] / 1024.0f;
        v[n].x = g_ox + (cx + lx) * g_sx;
        v[n].y = g_oy + (cy + ly) * g_sy;
        v[n].z = 0.0f; v[n].rhw = 1.0f; v[n].u = 0.0f; v[n].v = 0.0f; ++n;
    }
    for (i = 1; i <= 16; ++i) {
        lx = -mid - hh * (float)k_arc[i][0] / 1024.0f;
        ly = -hh * (float)k_arc[i][1] / 1024.0f;
        v[n].x = g_ox + (cx + lx) * g_sx;
        v[n].y = g_oy + (cy + ly) * g_sy;
        v[n].z = 0.0f; v[n].rhw = 1.0f; v[n].u = 0.0f; v[n].v = 0.0f; ++n;
    }

    // Right semicircle: bottom seam -> rightmost -> top seam.
    for (i = 16; i >= 0; --i) {
        lx = mid + hh * (float)k_arc[i][0] / 1024.0f;
        ly = -hh * (float)k_arc[i][1] / 1024.0f;
        v[n].x = g_ox + (cx + lx) * g_sx;
        v[n].y = g_oy + (cy + ly) * g_sy;
        v[n].z = 0.0f; v[n].rhw = 1.0f; v[n].u = 0.0f; v[n].v = 0.0f; ++n;
    }
    for (i = 1; i <= 16; ++i) {
        lx = mid + hh * (float)k_arc[i][0] / 1024.0f;
        ly = hh * (float)k_arc[i][1] / 1024.0f;
        v[n].x = g_ox + (cx + lx) * g_sx;
        v[n].y = g_oy + (cy + ly) * g_sy;
        v[n].z = 0.0f; v[n].rhw = 1.0f; v[n].u = 0.0f; v[n].v = 0.0f; ++n;
    }

    // Close the fan by repeating the first perimeter vertex. Without this, the
    // final top edge is one triangle short and the capsule renders malformed.
    v[n] = v[1]; ++n;
    g_dev->SetRenderState(D3DRS_TEXTUREFACTOR, color);
    g_dev->SetTexture(0, s_white);
    g_dev->DrawPrimitiveUP(D3DPT_TRIANGLEFAN, n - 2, v, sizeof(QVtx));
}

// Soft ambient glow blob: one additive, LINEAR-scaled draw of the radial glow
// sprite -- perfectly smooth (no concentric banding). color tints it, peak sets
// overall intensity (the sprite's alpha falloff does the shaping).
void Gfx_GlowSoft(int cx, int cy, int w, int h, DWORD color, int peak)
{
    DWORD tint = (color & 0x00FFFFFF) | ((DWORD)(peak & 0xFF) << 24);
    if (!s_glowTex) return;
    g_dev->SetRenderState(D3DRS_DESTBLEND, D3DBLEND_ONE);   // additive
    Gfx_SetFilter(TRUE);                                    // smooth upscale
    Gfx_DrawTex(s_glowTex, (float)(cx - w / 2), (float)(cy - h / 2),
        (float)w, (float)h, 0.0f, 0.0f, 1.0f, 1.0f, tint);
    Gfx_SetFilter(FALSE);
    g_dev->SetRenderState(D3DRS_DESTBLEND, D3DBLEND_INVSRCALPHA);
}
// ===================== Real 3D pass (perspective) =======================
// The layer above is XYZRHW (screen-space). For genuine depth we set a
// perspective projection + identity view and feed untransformed XYZ geometry,
// letting the NV2A's fixed-function T&L do the perspective divide. The 3D
// viewport is clamped to the 4:3 design area so it aligns with the 2D chrome.

struct V3 { float x, y, z; DWORD c; float u, v; };
#define FVF3 (D3DFVF_XYZ | D3DFVF_DIFFUSE | D3DFVF_TEX1)

static D3DVIEWPORT8 s_vpSaved;
static int          s_vpHave = 0;

static void mat_zero_id(D3DMATRIX* m)
{
    int i; float* f = &m->_11;
    for (i = 0; i < 16; ++i) f[i] = 0.0f;
    m->_11 = m->_22 = m->_33 = m->_44 = 1.0f;
}

void Gfx_Begin3D(void)
{
    D3DMATRIX proj, idn;
    D3DVIEWPORT8 vp;

    // 60deg vertical FOV, 4:3, near 1 / far 50, left-handed.
    mat_zero_id(&proj);
    proj._11 = 1.29904f;    // xScale = yScale / (4/3)
    proj._22 = 1.73205f;    // yScale = 1 / tan(fovY/2)
    proj._33 = 1.020408f;   // zf / (zf - zn)
    proj._34 = 1.0f;
    proj._43 = -1.020408f;  // -zn * zf / (zf - zn)
    proj._44 = 0.0f;
    mat_zero_id(&idn);

    g_dev->SetTransform(D3DTS_PROJECTION, &proj);
    g_dev->SetTransform(D3DTS_VIEW, &idn);
    g_dev->SetTransform(D3DTS_WORLD, &idn);

    if (SUCCEEDED(g_dev->GetViewport(&s_vpSaved))) s_vpHave = 1;
    vp.X = (DWORD)g_ox;
    vp.Y = (DWORD)g_oy;
    vp.Width = (DWORD)(640.0f * g_sx);
    vp.Height = (DWORD)(480.0f * g_sy);
    vp.MinZ = 0.0f; vp.MaxZ = 1.0f;
    g_dev->SetViewport(&vp);

    g_dev->SetVertexShader(FVF3);
    g_dev->SetTextureStageState(0, D3DTSS_COLORARG2, D3DTA_DIFFUSE);
    g_dev->SetTextureStageState(0, D3DTSS_ALPHAARG2, D3DTA_DIFFUSE);

    // Linear depth fog toward the background colour: blends far pills and the
    // back of the orb field into the scene so nothing reads as a hard cut-out.
    {
        float fs = 2.55f, fe = 11.0f;                  // start just behind the selected pill
        g_dev->SetRenderState(D3DRS_FOGENABLE, TRUE);
        g_dev->SetRenderState(D3DRS_FOGCOLOR, EOS_BG & 0x00FFFFFF);
        g_dev->SetRenderState(D3DRS_FOGTABLEMODE, D3DFOG_LINEAR);
        g_dev->SetRenderState(D3DRS_FOGSTART, *(DWORD*)&fs);
        g_dev->SetRenderState(D3DRS_FOGEND, *(DWORD*)&fe);
    }
}

void Gfx_End3D(void)
{
    g_dev->SetRenderState(D3DRS_FOGENABLE, FALSE);
    if (s_vpHave) { g_dev->SetViewport(&s_vpSaved); s_vpHave = 0; }
    g_dev->SetVertexShader(QFVF);
    g_dev->SetTextureStageState(0, D3DTSS_COLORARG2, D3DTA_TFACTOR);
    g_dev->SetTextureStageState(0, D3DTSS_ALPHAARG2, D3DTA_TFACTOR);
}

// CRT-free sine/cosine (parabola + one refinement, ~0.1% error). Range-reduced
// to [-PI,PI]. Good enough for menu-wheel rotation; no libm dependency.
static float s_sinf(float x)
{
    const float PI = 3.14159265f, TWO_PI = 6.28318531f, INV2PI = 0.15915494f;
    const float B = 1.27323954f, C = 0.40528473f, P = 0.225f;
    int k; float ax, y, ay;
    k = (int)(x * INV2PI); x -= (float)k * TWO_PI;     // |x| < 2PI
    if (x > PI) x -= TWO_PI; else if (x < -PI) x += TWO_PI;
    ax = (x < 0.0f) ? -x : x;
    y = B * x - C * x * ax;
    ay = (y < 0.0f) ? -y : y;
    return P * (y * ay - y) + y;
}
void Gfx_SinCos(float a, float* s, float* c)
{
    if (s) *s = s_sinf(a);
    if (c) *c = s_sinf(a + 1.57079633f);
}

// Flat (screen-parallel) quad -- used by the orb field.
static void quad3(float cx, float cy, float cz, float hw, float hh, DWORD c,
    IDirect3DTexture8* tex, float u0, float v0, float u1, float v1)
{
    V3 v[4];
    v[0].x = cx - hw; v[0].y = cy + hh; v[0].z = cz; v[0].c = c; v[0].u = u0; v[0].v = v0;
    v[1].x = cx + hw; v[1].y = cy + hh; v[1].z = cz; v[1].c = c; v[1].u = u1; v[1].v = v0;
    v[2].x = cx - hw; v[2].y = cy - hh; v[2].z = cz; v[2].c = c; v[2].u = u0; v[2].v = v1;
    v[3].x = cx + hw; v[3].y = cy - hh; v[3].z = cz; v[3].c = c; v[3].u = u1; v[3].v = v1;
    g_dev->SetTexture(0, tex ? tex : s_white);
    g_dev->DrawPrimitiveUP(D3DPT_TRIANGLESTRIP, 2, v, sizeof(V3));
}

void Gfx_Orb3D(float cx, float cy, float cz, float size, DWORD color, int peak)
{
    // Lit sphere, alpha-blended (NOT additive) so the dark limb occludes the
    // background and the ball reads as a solid 3D object. Tint = orb color,
    // overall opacity = peak. LINEAR filtering keeps the sphere smooth.
    DWORD c = (color & 0x00FFFFFF) | ((DWORD)(peak & 0xFF) << 24);
    if (!s_ballTex) return;
    Gfx_SetFilter(TRUE);
    quad3(cx, cy, cz, size * 0.5f, size * 0.5f, c, s_ballTex, 0.0f, 0.0f, 1.0f, 1.0f);
    Gfx_SetFilter(FALSE);
}

void Gfx_GlowX3D(float cx, float cy, float cz, float ca, float sa,
    float hw, float hh, DWORD color, int peak)
{
    DWORD c = (color & 0x00FFFFFF) | ((DWORD)(peak & 0xFF) << 24);
    if (!s_glowTex) return;
    g_dev->SetRenderState(D3DRS_DESTBLEND, D3DBLEND_ONE);
    Gfx_SetFilter(TRUE);
    Gfx_Quad3DP(cx, cy, cz, ca, sa, 0.0f, 0.0f, hw, hh, c,
        s_glowTex, 0.0f, 0.0f, 1.0f, 1.0f);
    Gfx_SetFilter(FALSE);
    g_dev->SetRenderState(D3DRS_DESTBLEND, D3DBLEND_INVSRCALPHA);
}

// Tilted quad. A local-space rect (centered at lcx,lcy within the item's face)
// rotated about the world X axis by (ca=cos,sa=sin), then placed at the item
// center (cx,cy,cz). X is unaffected by the rotation; local Y maps into world
// Y/Z, so the surface turns in space -- this is what reads as real 3D. Pass
// ca=1,sa=0 for a screen-parallel quad.
void Gfx_Quad3DP(float cx, float cy, float cz, float ca, float sa,
    float lcx, float lcy, float hw, float hh, DWORD c,
    IDirect3DTexture8* tex, float u0, float v0, float u1, float v1)
{
    float lx0 = lcx - hw, lx1 = lcx + hw, ly0 = lcy + hh, ly1 = lcy - hh;
    V3 v[4];
    v[0].x = cx + lx0; v[0].y = cy + ly0 * ca; v[0].z = cz + ly0 * sa; v[0].c = c; v[0].u = u0; v[0].v = v0;
    v[1].x = cx + lx1; v[1].y = cy + ly0 * ca; v[1].z = cz + ly0 * sa; v[1].c = c; v[1].u = u1; v[1].v = v0;
    v[2].x = cx + lx0; v[2].y = cy + ly1 * ca; v[2].z = cz + ly1 * sa; v[2].c = c; v[2].u = u0; v[2].v = v1;
    v[3].x = cx + lx1; v[3].y = cy + ly1 * ca; v[3].z = cz + ly1 * sa; v[3].c = c; v[3].u = u1; v[3].v = v1;
    g_dev->SetTexture(0, tex ? tex : s_white);
    g_dev->DrawPrimitiveUP(D3DPT_TRIANGLESTRIP, 2, v, sizeof(V3));
}

// Rounded, translucent 3D pill rendered as ONE convex polygon. Earlier
// versions used a center rectangle plus two separate semicircle draw calls;
// with translucent blending/MSAA, the shared raster edges could show as faint
// vertical seams. This single triangle fan has no internal cap/body boundary.
void Gfx_PillX3D(float cx, float cy, float cz, float ca, float sa,
    float hw, float hh, DWORD c)
{
    V3 v[68];
    float mid, lx, ly;
    int n, i;

    mid = hw - hh;
    if (mid < 0.0f) {
        hw = hh;
        mid = 0.0f;
    }

    n = 0;

    // Fan hub at the capsule center.
    v[n].x = cx; v[n].y = cy; v[n].z = cz;
    v[n].c = c; v[n].u = 0.5f; v[n].v = 0.5f; ++n;

    // Left semicircle: top seam -> leftmost -> bottom seam.
    for (i = 16; i >= 0; --i) {
        lx = -mid - hh * (float)k_arc[i][0] / 1024.0f;
        ly = hh * (float)k_arc[i][1] / 1024.0f;
        v[n].x = cx + lx;
        v[n].y = cy + ly * ca;
        v[n].z = cz + ly * sa;
        v[n].c = c; v[n].u = 0.0f; v[n].v = 0.0f; ++n;
    }
    for (i = 1; i <= 16; ++i) {
        lx = -mid - hh * (float)k_arc[i][0] / 1024.0f;
        ly = -hh * (float)k_arc[i][1] / 1024.0f;
        v[n].x = cx + lx;
        v[n].y = cy + ly * ca;
        v[n].z = cz + ly * sa;
        v[n].c = c; v[n].u = 0.0f; v[n].v = 0.0f; ++n;
    }

    // Right semicircle: bottom seam -> rightmost -> top seam. The straight
    // bottom/top edges are formed naturally between the two cap endpoints.
    for (i = 16; i >= 0; --i) {
        lx = mid + hh * (float)k_arc[i][0] / 1024.0f;
        ly = -hh * (float)k_arc[i][1] / 1024.0f;
        v[n].x = cx + lx;
        v[n].y = cy + ly * ca;
        v[n].z = cz + ly * sa;
        v[n].c = c; v[n].u = 0.0f; v[n].v = 0.0f; ++n;
    }
    for (i = 1; i <= 16; ++i) {
        lx = mid + hh * (float)k_arc[i][0] / 1024.0f;
        ly = hh * (float)k_arc[i][1] / 1024.0f;
        v[n].x = cx + lx;
        v[n].y = cy + ly * ca;
        v[n].z = cz + ly * sa;
        v[n].c = c; v[n].u = 0.0f; v[n].v = 0.0f; ++n;
    }

    // Close the perimeter back to the first (top-left seam) point.
    v[n] = v[1]; ++n;

    g_dev->SetTexture(0, s_white);
    g_dev->DrawPrimitiveUP(D3DPT_TRIANGLEFAN, n - 2, v, sizeof(V3));
}


