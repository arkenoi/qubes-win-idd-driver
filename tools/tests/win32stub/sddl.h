/* sddl.h - STUB (see windows.h here): the two SDDL calls the watchdog's lifecycle channel uses. */
#ifndef STUB_SDDL_H
#define STUB_SDDL_H
#include <windows.h>
#define SDDL_REVISION_1 1
BOOL ConvertStringSecurityDescriptorToSecurityDescriptorW(LPCWSTR, DWORD, PSECURITY_DESCRIPTOR *, DWORD *);
#define ConvertStringSecurityDescriptorToSecurityDescriptor ConvertStringSecurityDescriptorToSecurityDescriptorW
BOOL ConvertSidToStringSidW(PSID, LPWSTR *);
#endif
