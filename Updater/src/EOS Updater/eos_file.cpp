// eos_file.cpp -- see eos_file.h. Standard RXDK file APIs (the same calls
// DarkDash's dd_fileops uses), trimmed to the read + enumerate subset and made
// heap-free (caller buffers, no malloc).
#include <xtl.h>
#include "eos_file.h"
#include "dd_mount.h"   // Mount_HddPartitions

static int  fLen(const char* s) { int n = 0; while (s[n]) n++; return n; }
static void fCopy(char* d, int cap, const char* s)
{
    int i = 0;
    if (cap <= 0) return;
    while (s[i] && i < cap - 1) { d[i] = s[i]; ++i; }
    d[i] = 0;
}

void File_MountDrives(void)
{
    Mount_HddPartitions();
}

int File_Exists(const char* path)
{
    return GetFileAttributesA(path) != 0xFFFFFFFF;
}

int File_IsDir(const char* path)
{
    DWORD a = GetFileAttributesA(path);
    return (a != 0xFFFFFFFF) && (a & FILE_ATTRIBUTE_DIRECTORY);
}

int File_ListDrives(EosFileEntry* out, int maxEntries)
{
    static const char k_letters[7] = { 'C', 'E', 'F', 'G', 'X', 'Y', 'Z' };
    char root[4];
    int  i, n = 0;

    for (i = 0; i < 7 && n < maxEntries; ++i) {
        root[0] = k_letters[i]; root[1] = ':'; root[2] = '\\'; root[3] = 0;
        if (GetFileAttributesA(root) != 0xFFFFFFFF) {
            out[n].name[0] = k_letters[i]; out[n].name[1] = ':'; out[n].name[2] = 0;
            out[n].is_dir = 1;
            ++n;
        }
    }
    return n;
}

int File_ListDir(const char* path, EosFileEntry* out, int maxEntries)
{
    char            pat[EOS_FILE_PATH_MAX + 4];
    WIN32_FIND_DATA fd;
    HANDLE          h;
    int             n = 0, p;

    fCopy(pat, sizeof(pat), path);
    p = fLen(pat);
    if (p > 0 && pat[p - 1] != '\\' && p < (int)sizeof(pat) - 2) pat[p++] = '\\';
    pat[p++] = '*'; pat[p] = 0;

    h = FindFirstFile(pat, &fd);
    if (h == INVALID_HANDLE_VALUE) return 0;
    do {
        if (fd.cFileName[0] == '.' &&
            (fd.cFileName[1] == 0 || fd.cFileName[1] == '.')) continue;
        if (n >= maxEntries) break;
        fCopy(out[n].name, EOS_FILE_NAME_MAX, fd.cFileName);
        out[n].is_dir = (fd.dwFileAttributes & FILE_ATTRIBUTE_DIRECTORY) ? 1 : 0;
        ++n;
    } while (FindNextFile(h, &fd));
    FindClose(h);
    return n;
}

int File_ReadInto(const char* path, unsigned char* buf, int cap)
{
    HANDLE h;
    DWORD  sz, got = 0;

    h = CreateFileA(path, GENERIC_READ, FILE_SHARE_READ, NULL,
        OPEN_EXISTING, FILE_ATTRIBUTE_NORMAL, NULL);
    if (h == INVALID_HANDLE_VALUE) return -1;

    sz = GetFileSize(h, NULL);
    if (sz == 0xFFFFFFFF || (int)sz > cap) { CloseHandle(h); return -1; }
    if (sz && (!ReadFile(h, buf, sz, &got, NULL) || got != sz)) {
        CloseHandle(h); return -1;
    }
    CloseHandle(h);
    return (int)sz;
}

/* Write `len` bytes from `buf` to `path`, creating/overwriting it. Returns the
   number of bytes written, or -1 on error. Used for local bank-image backups. */
int File_WriteFrom(const char* path, const unsigned char* buf, int len)
{
    HANDLE h;
    DWORD  put = 0;
    if (!path || !buf || len < 0) return -1;
    h = CreateFileA(path, GENERIC_WRITE, 0, NULL,
        CREATE_ALWAYS, FILE_ATTRIBUTE_NORMAL, NULL);
    if (h == INVALID_HANDLE_VALUE) return -1;
    if (len && (!WriteFile(h, buf, (DWORD)len, &put, NULL) || put != (DWORD)len)) {
        CloseHandle(h); return -1;
    }
    CloseHandle(h);
    return (int)put;
}