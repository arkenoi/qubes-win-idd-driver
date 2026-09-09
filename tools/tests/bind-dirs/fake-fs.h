/*
 * In-memory BD_FS for the offline bind-dirs tests (gcc, Linux). Models just enough of NTFS:
 * directories, files with content, junctions/symlinks with a target, subtree rename/copy/
 * delete, plus failure injection per operation and per path, and a mutation counter so a
 * test can prove that a refusal touched nothing.
 */
#pragma once

#include "../../../core-agent/src/bind-dirs/bind-dirs.h"

typedef enum { FN_DIR, FN_FILE, FN_JUNCTION, FN_SYMLINK } FAKE_KIND;

typedef struct _FAKE_NODE
{
    wchar_t path[BD_MAX_PATH];     // as created, e.g. C:\ProgramData\Foo
    wchar_t key[BD_MAX_PATH];      // uppercased
    FAKE_KIND kind;
    wchar_t target[BD_MAX_PATH];   // reparse substitute name (\??\...)
    unsigned char *content;        // FN_FILE
    unsigned long size;
    int used;
} FAKE_NODE;

#define FAKE_MAX_NODES 4096

typedef struct _FAKE_FS
{
    FAKE_NODE nodes[FAKE_MAX_NODES];
    unsigned long mutations;       // count of successful mutating operations
    unsigned long copyBytes;       // bytes copied by CopyDirectory (to prove "no re-seed")

    // Failure injection: an op fails (status -0x1000-n) when its path equals the injected
    // path, or for any path when the injected path is "*".
    wchar_t failMkdir[BD_MAX_PATH];
    wchar_t failRenameFrom[BD_MAX_PATH];
    wchar_t failCopyTo[BD_MAX_PATH];
    int copyPartialNodes;          // when failing a copy, copy this many nodes first
    wchar_t failDelete[BD_MAX_PATH];
    wchar_t failJunction[BD_MAX_PATH];
    wchar_t failStat[BD_MAX_PATH];
    int junctionSilentNoop;        // SetJunction returns success but changes nothing (verify path)

    int quiet;                     // suppress Log output
} FAKE_FS;

void FakeInit(FAKE_FS *f, BD_FS *fs);
void FakeReset(FAKE_FS *f);
FAKE_NODE *FakeFind(FAKE_FS *f, const wchar_t *path);
void FakeAddDir(FAKE_FS *f, const wchar_t *path);
void FakeAddFile(FAKE_FS *f, const wchar_t *path, const char *content);
void FakeAddJunction(FAKE_FS *f, const wchar_t *path, const wchar_t *target);
void FakeAddSymlink(FAKE_FS *f, const wchar_t *path, const wchar_t *target);
unsigned long FakeCountUnder(FAKE_FS *f, const wchar_t *prefix);
int FakeFileHas(FAKE_FS *f, const wchar_t *path, const char *content);
