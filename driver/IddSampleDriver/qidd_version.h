// Build-stamped FILEVERSION for IddSampleDriver.dll. CI OVERWRITES this file before msbuild
// (workflow step "Stamp DLL version"). The stamp exists to make every CI build byte-unique:
// two driver-store generations carrying BYTE-IDENTICAL DLLs leave the
// C:\Windows\System32\drivers\UMDF\ copy hardlinked to the OLDER generation (the copy engine
// skips identical content), the UMDF device then fails to start cleanly under the newer
// binding, and arbitrary resolutions die (0xC0000476 on the QIDD ioctl, registry modes never
// offered - FINDINGS 2026-08-27, the withdrawn 4.3.8). Local builds keep these defaults.
#pragma once
#ifndef QIDD_VER_MAJOR
#define QIDD_VER_MAJOR 4
#define QIDD_VER_MINOR 3
#define QIDD_VER_BUILD 0
#define QIDD_VER_REV   0
#define QIDD_VER_STR   "4.3.0.0-local"
#endif
