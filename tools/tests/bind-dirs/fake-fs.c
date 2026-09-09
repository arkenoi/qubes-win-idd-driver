#include "fake-fs.h"
#include <stdio.h>
#include <stdlib.h>
#include <stdarg.h>
#include <wctype.h>
#include <string.h>

#define FAKE_FAIL_INJECTED (-0x1000L)
#define FAKE_FAIL_NOTFOUND (-0x0034L)   // mirrors STATUS_OBJECT_NAME_NOT_FOUND's role
#define FAKE_FAIL_EXISTS   (-0x0035L)
#define FAKE_FAIL_NOTEMPTY (-0x0101L)

static void Upkey(const wchar_t *in, wchar_t *out)
{
    size_t i;
    for (i = 0; in[i]; i++)
        out[i] = (wchar_t)towupper(in[i]);
    out[i] = 0;
}

static int Injected(const wchar_t *injected, const wchar_t *path)
{
    wchar_t a[BD_MAX_PATH], b[BD_MAX_PATH];
    if (!injected[0])
        return 0;
    if (wcscmp(injected, L"*") == 0)
        return 1;
    Upkey(injected, a);
    Upkey(path, b);
    return wcscmp(a, b) == 0;
}

FAKE_NODE *FakeFind(FAKE_FS *f, const wchar_t *path)
{
    wchar_t key[BD_MAX_PATH];
    unsigned long i;
    Upkey(path, key);
    // Tolerate a trailing backslash on the root spelling (Q:\ vs Q:).
    {
        size_t n = wcslen(key);
        if (n == 3 && key[2] == L'\\')
            key[2] = 0;
    }
    for (i = 0; i < FAKE_MAX_NODES; i++)
        if (f->nodes[i].used && wcscmp(f->nodes[i].key, key) == 0)
            return &f->nodes[i];
    return NULL;
}

static FAKE_NODE *NewNode(FAKE_FS *f, const wchar_t *path, FAKE_KIND kind)
{
    unsigned long i;
    for (i = 0; i < FAKE_MAX_NODES; i++)
    {
        if (!f->nodes[i].used)
        {
            FAKE_NODE *n = &f->nodes[i];
            memset(n, 0, sizeof(*n));
            n->used = 1;
            wcscpy(n->path, path);
            Upkey(path, n->key);
            {
                size_t len = wcslen(n->key);
                if (len == 3 && n->key[2] == L'\\')
                    n->key[2] = 0;
            }
            n->kind = kind;
            return n;
        }
    }
    fwprintf(stderr, L"fake fs full\n");
    exit(99);
}

void FakeAddDir(FAKE_FS *f, const wchar_t *path) { NewNode(f, path, FN_DIR); }

void FakeAddFile(FAKE_FS *f, const wchar_t *path, const char *content)
{
    FAKE_NODE *n = NewNode(f, path, FN_FILE);
    n->size = (unsigned long)strlen(content);
    n->content = malloc(n->size + 1);
    memcpy(n->content, content, n->size + 1);
}

void FakeAddJunction(FAKE_FS *f, const wchar_t *path, const wchar_t *target)
{
    FAKE_NODE *n = NewNode(f, path, FN_JUNCTION);
    wcscpy(n->target, target);
}

void FakeAddSymlink(FAKE_FS *f, const wchar_t *path, const wchar_t *target)
{
    FAKE_NODE *n = NewNode(f, path, FN_SYMLINK);
    wcscpy(n->target, target);
}

static int IsUnder(const wchar_t *key, const wchar_t *prefixKey)
{
    size_t p = wcslen(prefixKey);
    return wcsncmp(key, prefixKey, p) == 0 && key[p] == L'\\';
}

unsigned long FakeCountUnder(FAKE_FS *f, const wchar_t *prefix)
{
    wchar_t key[BD_MAX_PATH];
    unsigned long i, c = 0;
    Upkey(prefix, key);
    for (i = 0; i < FAKE_MAX_NODES; i++)
        if (f->nodes[i].used && IsUnder(f->nodes[i].key, key))
            c++;
    return c;
}

int FakeFileHas(FAKE_FS *f, const wchar_t *path, const char *content)
{
    FAKE_NODE *n = FakeFind(f, path);
    if (!n || n->kind != FN_FILE)
        return 0;
    return n->size == strlen(content) && memcmp(n->content, content, n->size) == 0;
}

static int ParentExists(FAKE_FS *f, const wchar_t *path)
{
    wchar_t parent[BD_MAX_PATH];
    size_t i = wcslen(path);
    wcscpy(parent, path);
    while (i > 0 && parent[i - 1] != L'\\')
        i--;
    if (i <= 1)
        return 0;
    parent[i - 1] = 0;
    if (wcslen(parent) == 2)   // "C:" -> root, always exists if the root node exists
        wcscat(parent, L"\\");
    {
        FAKE_NODE *n = FakeFind(f, parent);
        return n && (n->kind == FN_DIR);
    }
}

// ------------------------------------------------------------------ BD_FS ops

static BD_STATUS FStat(void *ctx, const wchar_t *path, BD_STAT *info)
{
    FAKE_FS *f = ctx;
    FAKE_NODE *n;
    memset(info, 0, sizeof(*info));
    if (Injected(f->failStat, path))
        return FAKE_FAIL_INJECTED;
    n = FakeFind(f, path);
    if (!n)
        return BD_OK;
    info->exists = 1;
    info->isDirectory = (n->kind != FN_FILE);
    if (n->kind == FN_JUNCTION || n->kind == FN_SYMLINK)
    {
        info->isReparsePoint = 1;
        info->reparseTag = (n->kind == FN_JUNCTION) ? BD_IO_REPARSE_TAG_MOUNT_POINT : BD_IO_REPARSE_TAG_SYMLINK;
        wcscpy(info->reparseTarget, n->target);
    }
    return BD_OK;
}

static BD_STATUS FCreateDirectory(void *ctx, const wchar_t *path)
{
    FAKE_FS *f = ctx;
    if (Injected(f->failMkdir, path))
        return FAKE_FAIL_INJECTED;
    if (FakeFind(f, path))
        return FAKE_FAIL_EXISTS;
    if (!ParentExists(f, path))
        return FAKE_FAIL_NOTFOUND;
    NewNode(f, path, FN_DIR);
    f->mutations++;
    return BD_OK;
}

static BD_STATUS FRename(void *ctx, const wchar_t *oldPath, const wchar_t *newPath)
{
    FAKE_FS *f = ctx;
    wchar_t oldKey[BD_MAX_PATH], newKey[BD_MAX_PATH];
    unsigned long i;
    if (Injected(f->failRenameFrom, oldPath))
        return FAKE_FAIL_INJECTED;
    if (!FakeFind(f, oldPath))
        return FAKE_FAIL_NOTFOUND;
    if (FakeFind(f, newPath))
        return FAKE_FAIL_EXISTS;
    if (!ParentExists(f, newPath))
        return FAKE_FAIL_NOTFOUND;
    Upkey(oldPath, oldKey);
    Upkey(newPath, newKey);
    for (i = 0; i < FAKE_MAX_NODES; i++)
    {
        FAKE_NODE *n = &f->nodes[i];
        if (!n->used)
            continue;
        if (wcscmp(n->key, oldKey) == 0 || IsUnder(n->key, oldKey))
        {
            wchar_t rest[BD_MAX_PATH];
            wcscpy(rest, n->path + wcslen(oldPath));
            wcscpy(n->path, newPath);
            wcscat(n->path, rest);
            Upkey(n->path, n->key);
        }
    }
    f->mutations++;
    return BD_OK;
}

static BD_STATUS FCopyDirectory(void *ctx, const wchar_t *src, const wchar_t *dst)
{
    FAKE_FS *f = ctx;
    wchar_t srcKey[BD_MAX_PATH];
    unsigned long i, copied = 0;
    int failing = Injected(f->failCopyTo, dst);
    FAKE_NODE *s = FakeFind(f, src);

    if (!s || s->kind != FN_DIR)
        return FAKE_FAIL_NOTFOUND;
    if (FakeFind(f, dst))
        return FAKE_FAIL_EXISTS;
    if (!ParentExists(f, dst))
        return FAKE_FAIL_NOTFOUND;
    NewNode(f, dst, FN_DIR);
    f->mutations++;
    Upkey(src, srcKey);
    for (i = 0; i < FAKE_MAX_NODES; i++)
    {
        FAKE_NODE *n = &f->nodes[i];
        FAKE_NODE *c;
        wchar_t newPath[BD_MAX_PATH];
        if (!n->used || !IsUnder(n->key, srcKey))
            continue;
        if (failing && (int)copied >= f->copyPartialNodes)
            return FAKE_FAIL_INJECTED;   // partial copy left behind, like a real failure
        wcscpy(newPath, dst);
        wcscat(newPath, n->path + wcslen(src));
        c = NewNode(f, newPath, n->kind);
        wcscpy(c->target, n->target);
        if (n->kind == FN_FILE)
        {
            c->size = n->size;
            c->content = malloc(n->size + 1);
            memcpy(c->content, n->content, n->size + 1);
            f->copyBytes += n->size;
        }
        copied++;
    }
    if (failing)
        return FAKE_FAIL_INJECTED;
    return BD_OK;
}

static BD_STATUS FDeleteDirectory(void *ctx, const wchar_t *path)
{
    FAKE_FS *f = ctx;
    wchar_t key[BD_MAX_PATH];
    unsigned long i;
    FAKE_NODE *n = FakeFind(f, path);
    if (Injected(f->failDelete, path))
        return FAKE_FAIL_INJECTED;
    if (!n)
        return FAKE_FAIL_NOTFOUND;
    Upkey(path, key);
    if (n->kind == FN_DIR)
    {
        for (i = 0; i < FAKE_MAX_NODES; i++)
            if (f->nodes[i].used && IsUnder(f->nodes[i].key, key))
            {
                free(f->nodes[i].content);
                f->nodes[i].content = NULL;
                f->nodes[i].used = 0;
            }
    }
    // A junction: only the reparse point itself goes; its target is never entered.
    free(n->content);
    n->content = NULL;
    n->used = 0;
    f->mutations++;
    return BD_OK;
}

static BD_STATUS FSetJunction(void *ctx, const wchar_t *path, const wchar_t *target)
{
    FAKE_FS *f = ctx;
    FAKE_NODE *n = FakeFind(f, path);
    if (Injected(f->failJunction, path))
        return FAKE_FAIL_INJECTED;
    if (!n || n->kind != FN_DIR)
        return FAKE_FAIL_NOTFOUND;
    if (FakeCountUnder(f, path) != 0)
        return FAKE_FAIL_NOTEMPTY;   // FSCTL_SET_REPARSE_POINT on a non-empty directory
    if (f->junctionSilentNoop)
        return BD_OK;                // "success" with no effect
    n->kind = FN_JUNCTION;
    wcscpy(n->target, L"\\??\\");
    wcscat(n->target, target);
    f->mutations++;
    return BD_OK;
}

static BD_STATUS FListDirectory(void *ctx, const wchar_t *path, BD_LIST_CALLBACK cb, void *cookie)
{
    FAKE_FS *f = ctx;
    wchar_t key[BD_MAX_PATH];
    unsigned long i;
    FAKE_NODE *d = FakeFind(f, path);
    if (!d || d->kind != FN_DIR)
        return FAKE_FAIL_NOTFOUND;
    Upkey(path, key);
    for (i = 0; i < FAKE_MAX_NODES; i++)
    {
        FAKE_NODE *n = &f->nodes[i];
        if (!n->used || !IsUnder(n->key, key))
            continue;
        if (wcschr(n->key + wcslen(key) + 1, L'\\'))
            continue;   // not an immediate child
        cb(cookie, n->path + wcslen(path) + 1, n->kind != FN_FILE);
    }
    return BD_OK;
}

static BD_STATUS FReadFile(void *ctx, const wchar_t *path, unsigned char **data, unsigned long *size, unsigned long maxBytes)
{
    FAKE_FS *f = ctx;
    FAKE_NODE *n = FakeFind(f, path);
    if (!n || n->kind != FN_FILE)
        return FAKE_FAIL_NOTFOUND;
    if (n->size > maxBytes)
        return -0x0023L;
    *data = malloc(n->size + 1);
    memcpy(*data, n->content, n->size + 1);
    *size = n->size;
    return BD_OK;
}

static void *FAlloc(void *ctx, size_t size) { (void)ctx; return calloc(1, size); }
static void FFree(void *ctx, void *p) { (void)ctx; free(p); }
static wchar_t FUpcase(void *ctx, wchar_t c) { (void)ctx; return (wchar_t)towupper(c); }

static void FLog(void *ctx, const wchar_t *format, ...)
{
    FAKE_FS *f = ctx;
    va_list args;
    if (f->quiet)
        return;
    va_start(args, format);
    fputws(L"      | ", stdout);
    vwprintf(format, args);
    va_end(args);
}

void FakeReset(FAKE_FS *f)
{
    unsigned long i;
    for (i = 0; i < FAKE_MAX_NODES; i++)
        free(f->nodes[i].content);
    memset(f, 0, sizeof(*f));
}

void FakeInit(FAKE_FS *f, BD_FS *fs)
{
    memset(f, 0, sizeof(*f));
    memset(fs, 0, sizeof(*fs));
    fs->context = f;
    fs->Stat = FStat;
    fs->CreateDirectory = FCreateDirectory;
    fs->Rename = FRename;
    fs->CopyDirectory = FCopyDirectory;
    fs->DeleteDirectory = FDeleteDirectory;
    fs->SetJunction = FSetJunction;
    fs->ListDirectory = FListDirectory;
    fs->ReadFile = FReadFile;
    fs->Alloc = FAlloc;
    fs->Free = FFree;
    fs->Upcase = FUpcase;
    fs->Log = FLog;
}
