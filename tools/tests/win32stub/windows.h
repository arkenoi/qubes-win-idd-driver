/* windows.h - minimal Win32 STUB so gcc on this dev qube can parse and, for the pure parts, RUN our Windows
   sources: agent/watchdog/watchdog.c (gcc -fsyntax-only), include/deathevent.h with gui-agent/deathevent_test.c
   (deathevent-selftest.sh), and windows-utils' src/service.c with svc-exitcode-test.c (svc-exitcode-selftest.sh).
   It is NOT a Windows compiler and proves nothing about linking: it gives the files the SDK's types, constants
   and function ARITIES, nothing more - CI compiles the real thing. Used together with the REAL windows-utils
   headers (log.h, config.h, qubes-io.h, service.h) from upstream/ro/qubes-windows-utils/include, which include
   only <windows.h>. Grown from the stub the 2026-10-03 watchdog change was checked with. */
#ifndef STUB_WINDOWS_H
#define STUB_WINDOWS_H
#include <stddef.h>
#include <stdlib.h>
#include <string.h>
#include <wchar.h>
#define IN
#define OUT
#define OPTIONAL
#define WINAPI
#define CALLBACK
#define __declspec(x)
#define TRUE 1
#define FALSE 0
#define UNREFERENCED_PARAMETER(p) (void)(p)
typedef int BOOL;
typedef unsigned short WORD;
typedef unsigned long DWORD;
typedef DWORD *LPDWORD;
typedef long LONG;
typedef long long LONG64;
typedef unsigned long long ULONGLONG;
typedef unsigned char BYTE;
typedef wchar_t WCHAR;
typedef WCHAR *LPWSTR;
typedef const WCHAR *LPCWSTR;
typedef char CHAR;
typedef void *HANDLE;
typedef void *PVOID;
typedef void *LPVOID;
typedef void *PSID;
typedef HANDLE SC_HANDLE;
typedef long HRESULT;
typedef HANDLE SERVICE_STATUS_HANDLE;
typedef union _LARGE_INTEGER { struct { DWORD LowPart; LONG HighPart; } u; LONG64 QuadPart; } LARGE_INTEGER;
typedef struct _SERVICE_STATUS { DWORD dwServiceType, dwCurrentState, dwControlsAccepted, dwWin32ExitCode, dwServiceSpecificExitCode, dwCheckPoint, dwWaitHint; } SERVICE_STATUS;
typedef void (WINAPI *LPSERVICE_MAIN_FUNCTIONW)(DWORD, WCHAR **);
typedef struct _SERVICE_TABLE_ENTRYW { LPWSTR lpServiceName; LPSERVICE_MAIN_FUNCTIONW lpServiceProc; } SERVICE_TABLE_ENTRY;
typedef DWORD (WINAPI *LPHANDLER_FUNCTION_EX)(DWORD, DWORD, void *, void *);
typedef DWORD (WINAPI *LPTHREAD_START_ROUTINE)(void *);
typedef struct _PROCESS_INFORMATION { HANDLE hProcess, hThread; DWORD dwProcessId, dwThreadId; } PROCESS_INFORMATION;
typedef struct _STARTUPINFOW { DWORD cb; LPWSTR lpReserved, lpDesktop, lpTitle; DWORD dwX, dwY, dwXSize, dwYSize, dwXCountChars, dwYCountChars, dwFillAttribute, dwFlags; unsigned short wShowWindow, cbReserved2; BYTE *lpReserved2; HANDLE hStdInput, hStdOutput, hStdError; } STARTUPINFO;
typedef struct _WTS_PROCESS_INFOW { DWORD SessionId, ProcessId; LPWSTR pProcessName; PVOID pUserSid; } WTS_PROCESS_INFO;
typedef struct _WTSSESSION_NOTIFICATION { DWORD cbSize, dwSessionId; } WTSSESSION_NOTIFICATION;
typedef enum _WTS_CONNECTSTATE_CLASS { WTSActive, WTSConnected, WTSConnectQuery, WTSShadow, WTSDisconnected, WTSIdle, WTSListen, WTSReset, WTSDown, WTSInit } WTS_CONNECTSTATE_CLASS;
typedef enum _WTS_INFO_CLASS { WTSInitialProgram, WTSApplicationName, WTSWorkingDirectory, WTSOEMId, WTSSessionId, WTSUserName, WTSWinStationName, WTSDomainName, WTSConnectState } WTS_INFO_CLASS;
typedef enum _TOKEN_INFORMATION_CLASS { TokenUser = 1, TokenSessionId = 12 } TOKEN_INFORMATION_CLASS;
typedef enum _SECURITY_IMPERSONATION_LEVEL { SecurityAnonymous, SecurityIdentification, SecurityImpersonation, SecurityDelegation } SECURITY_IMPERSONATION_LEVEL;
typedef enum _TOKEN_TYPE { TokenPrimary = 1, TokenImpersonation } TOKEN_TYPE;
#define NO_ERROR 0L
#define ERROR_SUCCESS 0L
#define ERROR_INVALID_PARAMETER 87L
#define ERROR_OUTOFMEMORY 14L
#define ERROR_GEN_FAILURE 31L
#define ERROR_ALREADY_EXISTS 183L
#define ERROR_ALREADY_INITIALIZED 1247L
#define ERROR_NO_SUCH_LOGON_SESSION 1312L
#define ERROR_TIMEOUT 1460L
#define ERROR_UNIDENTIFIED_ERROR 1287L
#define ERROR_SERVICE_SPECIFIC_ERROR 1066L
#define WAIT_OBJECT_0 0UL
#define WAIT_TIMEOUT 258UL
#define WAIT_FAILED 0xFFFFFFFFUL
#define INFINITE 0xFFFFFFFFUL
#define SYNCHRONIZE 0x00100000UL
#define DELETE 0x00010000UL
#define PROCESS_QUERY_LIMITED_INFORMATION 0x1000UL
#define EVENT_MODIFY_STATE 0x0002UL
#define TOKEN_ALL_ACCESS 0xF01FFUL
#define SM_SHUTTINGDOWN 0x2000
#define WTS_CURRENT_SERVER ((HANDLE)0)
#define WTS_CURRENT_SERVER_HANDLE ((HANDLE)0)
#define WTS_CONSOLE_CONNECT 0x1
#define WTS_SESSION_LOGON 0x5
#define SERVICE_WIN32 0x30UL
#define SERVICE_WIN32_OWN_PROCESS 0x10UL
#define SERVICE_STOPPED 1UL
#define SERVICE_START_PENDING 2UL
#define SERVICE_STOP_PENDING 3UL
#define SERVICE_RUNNING 4UL
#define SERVICE_ACCEPT_STOP 1UL
#define SERVICE_ACCEPT_SHUTDOWN 4UL
#define SERVICE_ACCEPT_SESSIONCHANGE 0x80UL
#define SERVICE_ACCEPT_PRESHUTDOWN 0x100UL
#define SERVICE_CONTROL_STOP 1UL
#define SERVICE_CONTROL_SHUTDOWN 5UL
#define SERVICE_CONTROL_SESSIONCHANGE 0xEUL
#define SERVICE_CONTROL_PRESHUTDOWN 0xFUL
#define SERVICE_AUTO_START 2UL
#define SERVICE_ERROR_NORMAL 1UL
#define SERVICE_STOP 0x20UL
#define SERVICE_QUERY_STATUS 0x4UL
#define SERVICE_ALL_ACCESS 0xF01FFUL
#define SC_MANAGER_ALL_ACCESS 0xF003FUL
#define EVENTLOG_ERROR_TYPE 0x0001
#define EVENTLOG_WARNING_TYPE 0x0002
#define EVENTLOG_INFORMATION_TYPE 0x0004
#define RTL_NUMBER_OF(a) (sizeof(a) / sizeof((a)[0]))
#define ARRAYSIZE(a) RTL_NUMBER_OF(a)
#define ZeroMemory(p, n) memset((p), 0, (n))
BOOL StartServiceCtrlDispatcher(const SERVICE_TABLE_ENTRY *);
SERVICE_STATUS_HANDLE RegisterServiceCtrlHandlerEx(LPCWSTR, LPHANDLER_FUNCTION_EX, void *);
BOOL SetServiceStatus(SERVICE_STATUS_HANDLE, SERVICE_STATUS *);
SC_HANDLE OpenSCManager(LPCWSTR, LPCWSTR, DWORD);
SC_HANDLE CreateService(SC_HANDLE, LPCWSTR, LPCWSTR, DWORD, DWORD, DWORD, DWORD, LPCWSTR, LPCWSTR, LPDWORD, LPCWSTR, LPCWSTR, LPCWSTR);
SC_HANDLE OpenService(SC_HANDLE, LPCWSTR, DWORD);
BOOL DeleteService(SC_HANDLE);
BOOL CloseServiceHandle(SC_HANDLE);
BOOL WTSEnumerateProcesses(HANDLE, DWORD, DWORD, WTS_PROCESS_INFO **, DWORD *);
BOOL WTSQuerySessionInformation(HANDLE, DWORD, WTS_INFO_CLASS, LPWSTR *, DWORD *);
void WTSFreeMemory(void *);
DWORD WTSGetActiveConsoleSessionId(void);
int _wcsnicmp(const wchar_t *, const wchar_t *, size_t);
wchar_t *_wcsdup(const wchar_t *);
HANDLE GetCurrentProcess(void);
DWORD GetCurrentProcessId(void);
DWORD GetProcessId(HANDLE);
BOOL OpenProcessToken(HANDLE, DWORD, HANDLE *);
BOOL GetTokenInformation(HANDLE, TOKEN_INFORMATION_CLASS, void *, DWORD, DWORD *);
BOOL SetTokenInformation(HANDLE, TOKEN_INFORMATION_CLASS, void *, DWORD);
BOOL DuplicateTokenEx(HANDLE, DWORD, void *, SECURITY_IMPERSONATION_LEVEL, TOKEN_TYPE, HANDLE *);
BOOL CreateProcessAsUser(HANDLE, LPCWSTR, LPWSTR, void *, void *, BOOL, DWORD, void *, LPCWSTR, STARTUPINFO *, PROCESS_INFORMATION *);
BOOL CloseHandle(HANDLE);
int GetSystemMetrics(int);
LONG InterlockedCompareExchange(volatile LONG *, LONG, LONG);
LONG InterlockedExchange(volatile LONG *, LONG);
HANDLE OpenEvent(DWORD, BOOL, LPCWSTR);
HANDLE CreateEvent(void *, BOOL, BOOL, LPCWSTR);
BOOL SetEvent(HANDLE);
DWORD WaitForSingleObject(HANDLE, DWORD);
DWORD WaitForMultipleObjects(DWORD, const HANDLE *, BOOL, DWORD);
BOOL TerminateProcess(HANDLE, unsigned);
BOOL GetExitCodeProcess(HANDLE, DWORD *);
BOOL GetExitCodeThread(HANDLE, DWORD *);
HANDLE OpenProcess(DWORD, BOOL, DWORD);
void Sleep(DWORD);
ULONGLONG GetTickCount64(void);
HANDLE CreateThread(void *, size_t, LPTHREAD_START_ROUTINE, void *, DWORD, DWORD *);
DWORD GetLastError(void);
HANDLE RegisterEventSourceW(LPCWSTR, LPCWSTR);
BOOL ReportEventW(HANDLE, WORD, WORD, DWORD, PSID, WORD, DWORD, LPCWSTR *, LPVOID);
BOOL DeregisterEventSource(HANDLE);
/* ---- grown 2026-10-07 for the lifecycle change (watchdog.c's per-pid channel, gui-agent/lifecycle.c's end-session
   window, include/qga-lifecycle.h): security attributes, a few more kernel32 calls, and the user32 surface a hidden
   window needs. Types + arities only, as above. */
typedef void *PSECURITY_DESCRIPTOR;
typedef struct _SECURITY_ATTRIBUTES { DWORD nLength; LPVOID lpSecurityDescriptor; BOOL bInheritHandle; } SECURITY_ATTRIBUTES, *LPSECURITY_ATTRIBUTES;
typedef void *HLOCAL;
typedef void *HWND;
typedef void *HINSTANCE;
typedef void *HICON;
typedef void *HCURSOR;
typedef void *HBRUSH;
typedef void *HMENU;
typedef void *HMODULE;
typedef unsigned int UINT;
typedef unsigned long long ULONG_PTR;
typedef ULONG_PTR WPARAM;
typedef long long LPARAM;
typedef long long LRESULT;
typedef struct tagPOINT { LONG x, y; } POINT;
typedef struct tagMSG { HWND hwnd; UINT message; WPARAM wParam; LPARAM lParam; DWORD time; POINT pt; } MSG;
typedef LRESULT (CALLBACK *WNDPROC)(HWND, UINT, WPARAM, LPARAM);
typedef struct tagWNDCLASSEXW { UINT cbSize, style; WNDPROC lpfnWndProc; int cbClsExtra, cbWndExtra; HINSTANCE hInstance; HICON hIcon; HCURSOR hCursor; HBRUSH hbrBackground; LPCWSTR lpszMenuName, lpszClassName; HICON hIconSm; } WNDCLASSEX;
typedef unsigned short ATOM;
#define CREATE_SUSPENDED 0x00000004UL
#define WTS_SESSION_LOGOFF 0x6
#define ERROR_CLASS_ALREADY_EXISTS 1410L
#define WM_QUERYENDSESSION 0x0011
#define WM_ENDSESSION 0x0016
#define ENDSESSION_LOGOFF 0x80000000UL
#define WS_POPUP 0x80000000UL
#define WS_EX_TOOLWINDOW 0x00000080UL
#define WS_EX_NOACTIVATE 0x08000000UL
#define SUCCEEDED(hr) ((HRESULT)(hr) >= 0)
#define FAILED(hr) ((HRESULT)(hr) < 0)
HLOCAL LocalFree(HLOCAL);
BOOL ResetEvent(HANDLE);
DWORD ResumeThread(HANDLE);
void ExitProcess(unsigned);
HMODULE GetModuleHandle(LPCWSTR);
ATOM RegisterClassEx(const WNDCLASSEX *);
HWND CreateWindowEx(DWORD, LPCWSTR, LPCWSTR, DWORD, int, int, int, int, HWND, HMENU, HINSTANCE, LPVOID);
BOOL GetMessage(MSG *, HWND, UINT, UINT);
BOOL TranslateMessage(const MSG *);
LRESULT DispatchMessage(const MSG *);
LRESULT DefWindowProc(HWND, UINT, WPARAM, LPARAM);
BOOL QueryFullProcessImageNameW(HANDLE, DWORD, LPWSTR, DWORD *);
#endif
