/* strsafe.h - STUB of the StringCch* family for gcc on this dev qube (see windows.h here). These are
   real, runnable implementations with strsafe's contract - the destination is always terminated and an
   oversize result is truncated - because deathevent_test.c RUNS the composer that uses them. */
#ifndef STUB_STRSAFE_H
#define STUB_STRSAFE_H
#include <windows.h>
#include <stdarg.h>
#include <stdio.h>
#include <wchar.h>
#define S_OK 0L
#define STRSAFE_E_INSUFFICIENT_BUFFER ((HRESULT)0x8007007AL)
static inline HRESULT StringCchCopyW(WCHAR *dst, size_t cch, const WCHAR *src)
{
    size_t n;
    if (!dst || cch == 0) return STRSAFE_E_INSUFFICIENT_BUFFER;
    n = wcslen(src);
    if (n >= cch) { wmemcpy(dst, src, cch - 1); dst[cch - 1] = 0; return STRSAFE_E_INSUFFICIENT_BUFFER; }
    wmemcpy(dst, src, n + 1);
    return S_OK;
}
/* MSVC's wide printf reads %s as a WIDE string (the codebase's idiom: LogError("%s", wideStr)); glibc's reads
   it as a narrow one and wants %ls. Rewrite the format here, so the shipped headers keep the Windows idiom. */
static inline HRESULT StringCchVPrintfW(WCHAR *dst, size_t cch, const WCHAR *fmt, va_list ap)
{
    WCHAR fixed[1024];
    size_t i, o = 0;
    int r;
    if (!dst || cch == 0) return STRSAFE_E_INSUFFICIENT_BUFFER;
    for (i = 0; fmt[i] && o < RTL_NUMBER_OF(fixed) - 3; i++)
    {
        if (fmt[i] == L'%' && fmt[i + 1] == L'%') { fixed[o++] = L'%'; fixed[o++] = L'%'; i++; continue; }
        if (fmt[i] == L'%' && fmt[i + 1] == L's') { fixed[o++] = L'%'; fixed[o++] = L'l'; fixed[o++] = L's'; i++; continue; }
        fixed[o++] = fmt[i];
    }
    fixed[o] = 0;
    r = vswprintf(dst, cch, fixed, ap);
    dst[cch - 1] = 0;
    return (r < 0) ? STRSAFE_E_INSUFFICIENT_BUFFER : S_OK;
}
static inline HRESULT StringCchPrintfW(WCHAR *dst, size_t cch, const WCHAR *fmt, ...)
{
    HRESULT hr;
    va_list ap;
    va_start(ap, fmt);
    hr = StringCchVPrintfW(dst, cch, fmt, ap);
    va_end(ap);
    return hr;
}
static inline HRESULT StringCbVPrintfW(WCHAR *dst, size_t cb, const WCHAR *fmt, va_list ap)
{
    return StringCchVPrintfW(dst, cb / sizeof(WCHAR), fmt, ap);
}
#define StringCchPrintf StringCchPrintfW
#define StringCchCopy StringCchCopyW
#endif
