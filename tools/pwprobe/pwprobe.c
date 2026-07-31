/*
 * pwprobe - Gate 0 of SESSION-PLAN-per-window-capture.md.
 *
 * Question: does PrintWindow(hwnd, dc, PW_RENDERFULLCONTENT) return a window's own,
 * correct content while the window is fully occluded by another?
 *
 * Three arms, verdict computed IN-GUEST by byte comparison against the exact pattern
 * the window painted (no cross-VM capture, no screenshot judgement):
 *   baseline  - window A visible, flags=0            (proves the instrument works at all)
 *   full      - A fully covered by B, PW_RENDERFULLCONTENT
 *   plain     - A fully covered by B, flags=0        (negative-control arm: expected to
 *               fail; a probe never seen failing is not evidence, CLAUDE.md rule 5)
 *
 * Output: pwprobe-result.txt next to the exe, one summary line + detail lines, plus
 * pw_baseline.bmp / pw_full.bmp / pw_plain.bmp for eyeball verification.
 *
 * Windows subsystem on purpose (no console window entering the scene). Both test windows
 * are WS_POPUP so client area == window area and the comparison is exact.
 */

#include <windows.h>
#include <stdio.h>
#include <string.h>

#ifndef PW_RENDERFULLCONTENT
#define PW_RENDERFULLCONTENT 0x00000002
#endif

#define AW 400
#define AH 300
#define AX 200
#define AY 200
/* B strictly covers A on every side */
#define BX (AX - 60)
#define BY (AY - 60)
#define BW (AW + 120)
#define BH (AH + 120)

static DWORD g_patA[AW * AH]; /* 0x00BBGGRR-ish: raw 32bpp DIB bytes, exact expected content */
static HWND g_hA, g_hB;

static void build_pattern(void)
{
    for (int y = 0; y < AH; y++)
        for (int x = 0; x < AW; x++) {
            BYTE r = (BYTE)(x & 0xFF), g = (BYTE)(y & 0xFF), b = (BYTE)((x ^ y) & 0xFF);
            g_patA[y * AW + x] = ((DWORD)r << 16) | ((DWORD)g << 8) | b; /* DIB is BGRX */
        }
}

static void paint_pattern(HDC dc)
{
    BITMAPINFO bi;
    ZeroMemory(&bi, sizeof(bi));
    bi.bmiHeader.biSize = sizeof(bi.bmiHeader);
    bi.bmiHeader.biWidth = AW;
    bi.bmiHeader.biHeight = -AH; /* top-down */
    bi.bmiHeader.biPlanes = 1;
    bi.bmiHeader.biBitCount = 32;
    bi.bmiHeader.biCompression = BI_RGB;
    SetDIBitsToDevice(dc, 0, 0, AW, AH, 0, 0, 0, AH, g_patA, &bi, DIB_RGB_COLORS);
}

static LRESULT CALLBACK WndProcA(HWND h, UINT m, WPARAM w, LPARAM l)
{
    if (m == WM_PAINT) {
        PAINTSTRUCT ps;
        HDC dc = BeginPaint(h, &ps);
        paint_pattern(dc);
        EndPaint(h, &ps);
        return 0;
    }
    /* Deliberately NO WM_PRINTCLIENT handler: the plain arm must exercise what a normal
     * unaware window gives PrintWindow(flags=0), not a cooperative repaint. */
    return DefWindowProc(h, m, w, l);
}

static LRESULT CALLBACK WndProcB(HWND h, UINT m, WPARAM w, LPARAM l)
{
    if (m == WM_PAINT) {
        PAINTSTRUCT ps;
        HDC dc = BeginPaint(h, &ps);
        RECT rc;
        GetClientRect(h, &rc);
        HBRUSH br = CreateSolidBrush(RGB(32, 96, 32));
        FillRect(dc, &rc, br);
        DeleteObject(br);
        EndPaint(h, &ps);
        return 0;
    }
    return DefWindowProc(h, m, w, l);
}

static void pump(DWORD ms)
{
    DWORD end = GetTickCount() + ms;
    MSG msg;
    for (;;) {
        while (PeekMessage(&msg, NULL, 0, 0, PM_REMOVE)) {
            TranslateMessage(&msg);
            DispatchMessage(&msg);
        }
        if ((LONG)(GetTickCount() - end) >= 0)
            break;
        Sleep(20);
    }
}

/* capture A via PrintWindow into a 32bpp DIB pre-filled with sentinel 0xAA;
 * returns %pixels whose BGR bytes equal the expected pattern, plus sentinel count. */
static double capture_and_compare(HWND hwnd, UINT flags, const char *tag,
                                  const char *dir, int *untouched_out, BOOL *pw_ok_out)
{
    BITMAPINFO bi;
    ZeroMemory(&bi, sizeof(bi));
    bi.bmiHeader.biSize = sizeof(bi.bmiHeader);
    bi.bmiHeader.biWidth = AW;
    bi.bmiHeader.biHeight = -AH;
    bi.bmiHeader.biPlanes = 1;
    bi.bmiHeader.biBitCount = 32;
    bi.bmiHeader.biCompression = BI_RGB;

    VOID *bits = NULL;
    HDC memdc = CreateCompatibleDC(NULL);
    HBITMAP bmp = CreateDIBSection(NULL, &bi, DIB_RGB_COLORS, &bits, NULL, 0);
    HGDIOBJ old = SelectObject(memdc, bmp);
    memset(bits, 0xAA, (size_t)AW * AH * 4);

    BOOL ok = PrintWindow(hwnd, memdc, flags);
    GdiFlush();
    *pw_ok_out = ok;

    DWORD *px = (DWORD *)bits;
    int match = 0, untouched = 0;
    for (int i = 0; i < AW * AH; i++) {
        if ((px[i] & 0x00FFFFFF) == (g_patA[i] & 0x00FFFFFF))
            match++;
        if (px[i] == 0xAAAAAAAA)
            untouched++;
    }
    *untouched_out = untouched;

    /* dump BMP for eyeball verification */
    char path[MAX_PATH];
    _snprintf(path, sizeof(path), "%s\\pw_%s.bmp", dir, tag);
    FILE *f = fopen(path, "wb");
    if (f) {
        BITMAPFILEHEADER fh;
        ZeroMemory(&fh, sizeof(fh));
        fh.bfType = 0x4D42;
        fh.bfOffBits = sizeof(fh) + sizeof(bi.bmiHeader);
        fh.bfSize = fh.bfOffBits + AW * AH * 4;
        BITMAPINFOHEADER ih = bi.bmiHeader; /* keep top-down */
        fwrite(&fh, sizeof(fh), 1, f);
        fwrite(&ih, sizeof(ih), 1, f);
        fwrite(bits, 1, (size_t)AW * AH * 4, f);
        fclose(f);
    }

    SelectObject(memdc, old);
    DeleteObject(bmp);
    DeleteDC(memdc);
    return 100.0 * match / (AW * AH);
}

static int cmp_dbl(const void *a, const void *b)
{
    double d = *(const double *)a - *(const double *)b;
    return d < 0 ? -1 : d > 0 ? 1 : 0;
}

/* bench mode: PrintWindow(PW_RENDERFULLCONTENT) latency on an OCCLUDED window,
 * N iterations, content verified every frame. This prices the no-session-limit
 * fallback path per frame (WGC allows only ~10 concurrent sessions). */
static int RunBench(HINSTANCE hi, int iters, const char *dir)
{
    g_hA = CreateWindowExW(0, L"pwprobeA", L"pwprobe-A", WS_POPUP | WS_VISIBLE,
                           AX, AY, AW, AH, NULL, NULL, hi, NULL);
    UpdateWindow(g_hA);
    pump(800);
    g_hB = CreateWindowExW(0, L"pwprobeB", L"pwprobe-B", WS_POPUP | WS_VISIBLE,
                           BX, BY, BW, BH, NULL, NULL, hi, NULL);
    UpdateWindow(g_hB);
    pump(800);

    BITMAPINFO bi;
    ZeroMemory(&bi, sizeof(bi));
    bi.bmiHeader.biSize = sizeof(bi.bmiHeader);
    bi.bmiHeader.biWidth = AW;
    bi.bmiHeader.biHeight = -AH;
    bi.bmiHeader.biPlanes = 1;
    bi.bmiHeader.biBitCount = 32;
    bi.bmiHeader.biCompression = BI_RGB;
    VOID *bits = NULL;
    HDC memdc = CreateCompatibleDC(NULL);
    HBITMAP bmp = CreateDIBSection(NULL, &bi, DIB_RGB_COLORS, &bits, NULL, 0);
    HGDIOBJ old = SelectObject(memdc, bmp);

    double *lat = (double *)malloc(sizeof(double) * iters);
    int mismatches = 0, fails = 0;
    LARGE_INTEGER f, t0, t1;
    QueryPerformanceFrequency(&f);
    for (int i = 0; i < iters; i++) {
        QueryPerformanceCounter(&t0);
        BOOL ok = PrintWindow(g_hA, memdc, PW_RENDERFULLCONTENT);
        GdiFlush();
        QueryPerformanceCounter(&t1);
        lat[i] = 1e6 * (t1.QuadPart - t0.QuadPart) / f.QuadPart;
        if (!ok) fails++;
        DWORD *px = (DWORD *)bits;
        int match = 0;
        for (int p = 0; p < AW * AH; p++)
            if ((px[p] & 0x00FFFFFF) == (g_patA[p] & 0x00FFFFFF))
                match++;
        if (100.0 * match / (AW * AH) < 99.0) mismatches++;
        pump(1); /* let the system breathe like a real agent loop would */
    }
    qsort(lat, iters, sizeof(double), cmp_dbl);
    double p50 = lat[iters / 2], p95 = lat[(int)(iters * 0.95)];

    char report[512], rpath[MAX_PATH];
    int len = _snprintf(report, sizeof(report),
        "PWPROBE-BENCH: iters=%d size=%dx%d p50=%.0fus p95=%.0fus min=%.0fus "
        "max=%.0fus pw_fails=%d content_mismatches=%d occluded=YES\r\n",
        iters, AW, AH, p50, p95, lat[0], lat[iters - 1], fails, mismatches);
    _snprintf(rpath, sizeof(rpath), "%s\\pwprobe-result.txt", dir);
    FILE *fp = fopen(rpath, "wb");
    if (fp) { fwrite(report, 1, len, fp); fclose(fp); }
    free(lat);
    SelectObject(memdc, old);
    DeleteObject(bmp);
    DeleteDC(memdc);
    DestroyWindow(g_hB);
    DestroyWindow(g_hA);
    return (fails == 0 && mismatches == 0) ? 0 : 1;
}

int WINAPI wWinMain(HINSTANCE hi, HINSTANCE hp, PWSTR cmd, int show)
{
    (void)hp; (void)show;
    SetProcessDPIAware();
    build_pattern();

    /* result file next to the exe */
    char dir[MAX_PATH];
    GetModuleFileNameA(NULL, dir, MAX_PATH);
    char *slash = strrchr(dir, '\\');
    if (slash) *slash = 0;

    /* result file next to the exe (needed by both modes) */
    char dir2[MAX_PATH];
    GetModuleFileNameA(NULL, dir2, MAX_PATH);
    {
        char *s2 = strrchr(dir2, '\\');
        if (s2) *s2 = 0;
    }

    WNDCLASSW wcA = {0}, wcB = {0};
    wcA.lpfnWndProc = WndProcA; wcA.hInstance = hi; wcA.lpszClassName = L"pwprobeA";
    wcA.hbrBackground = NULL; wcA.hCursor = LoadCursor(NULL, IDC_ARROW);
    wcB.lpfnWndProc = WndProcB; wcB.hInstance = hi; wcB.lpszClassName = L"pwprobeB";
    wcB.hbrBackground = NULL; wcB.hCursor = LoadCursor(NULL, IDC_ARROW);
    RegisterClassW(&wcA);
    RegisterClassW(&wcB);

    if (cmd && wcsstr(cmd, L"bench")) {
        int iters = 100;
        PWSTR sp = wcschr(cmd, L' ');
        if (sp && _wtoi(sp + 1) > 0) iters = _wtoi(sp + 1);
        return RunBench(hi, iters, dir2);
    }

    g_hA = CreateWindowExW(0, L"pwprobeA", L"pwprobe-A", WS_POPUP | WS_VISIBLE,
                           AX, AY, AW, AH, NULL, NULL, hi, NULL);
    UpdateWindow(g_hA);
    pump(1500); /* let DWM compose it */

    char report[2048];
    int len = 0;
    int unt; BOOL pwok;

    /* arm 1: baseline, visible, flags=0 */
    double base = capture_and_compare(g_hA, 0, "baseline", dir, &unt, &pwok);
    len += _snprintf(report + len, sizeof(report) - len,
        "baseline: pct=%.1f untouched=%d pw_ok=%d\r\n", base, unt, pwok);

    /* create B fully covering A */
    g_hB = CreateWindowExW(0, L"pwprobeB", L"pwprobe-B", WS_POPUP | WS_VISIBLE,
                           BX, BY, BW, BH, NULL, NULL, hi, NULL);
    UpdateWindow(g_hB);
    SetWindowPos(g_hB, HWND_TOP, 0, 0, 0, 0, SWP_NOMOVE | SWP_NOSIZE);
    pump(1500);

    /* prove occlusion: the point at A's center must belong to B */
    POINT ptc = { AX + AW / 2, AY + AH / 2 };
    HWND at = WindowFromPoint(ptc);
    BOOL occluded = (at == g_hB || GetAncestor(at, GA_ROOT) == g_hB);
    len += _snprintf(report + len, sizeof(report) - len,
        "occluded=%s (WindowFromPoint=%p A=%p B=%p)\r\n",
        occluded ? "YES" : "NO", (void *)at, (void *)g_hA, (void *)g_hB);

    /* arm 2: occluded + PW_RENDERFULLCONTENT */
    double full = capture_and_compare(g_hA, PW_RENDERFULLCONTENT, "full", dir, &unt, &pwok);
    len += _snprintf(report + len, sizeof(report) - len,
        "full: pct=%.1f untouched=%d pw_ok=%d\r\n", full, unt, pwok);

    /* arm 3: occluded + flags=0 (candidate negative control; on DWM systems this may
     * still MATCH because every top-level window keeps a redirection surface) */
    double plain = capture_and_compare(g_hA, 0, "plain", dir, &unt, &pwok);
    len += _snprintf(report + len, sizeof(report) - len,
        "plain: pct=%.1f untouched=%d pw_ok=%d\r\n", plain, unt, pwok);

    /* arm 4: guaranteed negative control — BitBlt from the SCREEN DC at A's rect while
     * occluded. That region of the screen contains B's pixels (occluded=YES asserted
     * above), so the comparator MUST report MISMATCH here or it cannot fail at all. */
    double screen = -1.0;
    {
        BITMAPINFO bi2;
        ZeroMemory(&bi2, sizeof(bi2));
        bi2.bmiHeader.biSize = sizeof(bi2.bmiHeader);
        bi2.bmiHeader.biWidth = AW;
        bi2.bmiHeader.biHeight = -AH;
        bi2.bmiHeader.biPlanes = 1;
        bi2.bmiHeader.biBitCount = 32;
        bi2.bmiHeader.biCompression = BI_RGB;
        VOID *bits2 = NULL;
        HDC sdc = GetDC(NULL);
        HDC mdc = CreateCompatibleDC(sdc);
        HBITMAP bmp2 = CreateDIBSection(NULL, &bi2, DIB_RGB_COLORS, &bits2, NULL, 0);
        HGDIOBJ old2 = SelectObject(mdc, bmp2);
        memset(bits2, 0xAA, (size_t)AW * AH * 4);
        BitBlt(mdc, 0, 0, AW, AH, sdc, AX, AY, SRCCOPY);
        GdiFlush();
        DWORD *px2 = (DWORD *)bits2;
        int match2 = 0;
        for (int i = 0; i < AW * AH; i++)
            if ((px2[i] & 0x00FFFFFF) == (g_patA[i] & 0x00FFFFFF))
                match2++;
        screen = 100.0 * match2 / (AW * AH);
        char spath[MAX_PATH];
        _snprintf(spath, sizeof(spath), "%s\\pw_screen.bmp", dir);
        FILE *sf = fopen(spath, "wb");
        if (sf) {
            BITMAPFILEHEADER fh2;
            ZeroMemory(&fh2, sizeof(fh2));
            fh2.bfType = 0x4D42;
            fh2.bfOffBits = sizeof(fh2) + sizeof(bi2.bmiHeader);
            fh2.bfSize = fh2.bfOffBits + AW * AH * 4;
            fwrite(&fh2, sizeof(fh2), 1, sf);
            fwrite(&bi2.bmiHeader, sizeof(bi2.bmiHeader), 1, sf);
            fwrite(bits2, 1, (size_t)AW * AH * 4, sf);
            fclose(sf);
        }
        SelectObject(mdc, old2);
        DeleteObject(bmp2);
        DeleteDC(mdc);
        ReleaseDC(NULL, sdc);
    }
    len += _snprintf(report + len, sizeof(report) - len,
        "screen: pct=%.1f (negative control, must MISMATCH)\r\n", screen);

    const char *v_full  = (full  >= 99.0) ? "MATCH" : "MISMATCH";
    const char *v_plain = (plain >= 99.0) ? "MATCH" : "MISMATCH";
    const char *v_base  = (base  >= 99.0) ? "MATCH" : "MISMATCH";
    const char *v_scr   = (screen >= 99.0) ? "MATCH" : "MISMATCH";
    len += _snprintf(report + len, sizeof(report) - len,
        "PWPROBE: baseline=%s fullcontent=%s plain=%s screen=%s occluded=%s\r\n",
        v_base, v_full, v_plain, v_scr, occluded ? "YES" : "NO");

    char rpath[MAX_PATH];
    _snprintf(rpath, sizeof(rpath), "%s\\pwprobe-result.txt", dir);
    FILE *f = fopen(rpath, "wb");
    if (f) { fwrite(report, 1, len, f); fclose(f); }

    DestroyWindow(g_hB);
    DestroyWindow(g_hA);
    return (base >= 99.0 && occluded) ? 0 : 1;
}
