#include "CUnrar.h"
#include "rar.hpp"
#include <mutex>

static std::mutex rarMutex;
struct OPRar {
    // ponytail: UnRAR has global error state; serialize readers until upstream isolates it.
    std::unique_lock<std::mutex> lock{rarMutex};
    HANDLE archive = nullptr;
    std::string password, path, missing;
    OPRarWrite write = nullptr;
    void *context = nullptr;
};

static int callback(UINT message, LPARAM user, LPARAM p1, LPARAM p2) {
    auto &r = *reinterpret_cast<OPRar *>(user);
    switch (message) {
    case UCM_PROCESSDATA:
        if (r.write) {
            auto bytes = reinterpret_cast<const char *>(p1);
            size_t count = static_cast<size_t>(p2);
            while (count) {
                size_t chunk = std::min(count, size_t(1 << 20));
                if (r.write(r.context, bytes, chunk) != 0) return -1;
                bytes += chunk;
                count -= chunk;
            }
        }
        return 1;
    case UCM_NEEDPASSWORDW: {
        if (r.password.empty()) return -1;
        std::wstring wide;
        UtfToWide(r.password.c_str(), wide);
        if (wide.size() >= static_cast<size_t>(p2)) return -1;
        wcscpy(reinterpret_cast<wchar_t *>(p1), wide.c_str());
        return 1;
    }
    case UCM_NEEDPASSWORD:
        if (r.password.empty() || r.password.size() >= static_cast<size_t>(p2)) return -1;
        strcpy(reinterpret_cast<char *>(p1), r.password.c_str());
        return 1;
    case UCM_CHANGEVOLUMEW:
        if (p2 == RAR_VOL_ASK) {
            r.missing.clear();
            WideToUtf(reinterpret_cast<const wchar_t *>(p1), r.missing);
            return -1;
        }
        return 1;
    case UCM_CHANGEVOLUME:
        if (p2 == RAR_VOL_ASK) { r.missing = reinterpret_cast<const char *>(p1); return -1; }
        return 1;
    case UCM_LARGEDICT: return -1;
    default: return 1;
    }
}

OPRar *op_rar_open(const char *path, const char *password, int *error) {
    auto r = std::make_unique<OPRar>();
    r->password = password ? password : "";
    std::wstring wide;
    UtfToWide(path, wide);
    RAROpenArchiveDataEx data{};
    data.ArcNameW = const_cast<wchar_t *>(wide.c_str());
    data.OpenMode = RAR_OM_EXTRACT;
    data.Callback = callback;
    data.UserData = reinterpret_cast<LPARAM>(r.get());
    r->archive = RAROpenArchiveEx(&data);
    *error = data.OpenResult;
    return r->archive ? r.release() : nullptr;
}

int op_rar_next(OPRar *r, OPRarEntry *entry) {
    RARHeaderDataEx header{};
    wchar_t name[32768]{};
    header.FileNameEx = name;
    header.FileNameExSize = 32768;
    int error = RARReadHeaderEx(r->archive, &header);
    if (error) return error;
    r->path.clear();
    WideToUtf(name, r->path);
    entry->path = r->path.c_str();
    entry->size = (uint64_t(header.UnpSizeHigh) << 32) | header.UnpSize;
    entry->packedSize = (uint64_t(header.PackSizeHigh) << 32) | header.PackSize;
    entry->dictionaryKiB = header.DictSize;
    unsigned type = header.FileAttr & 0170000;
    entry->kind = header.RedirType || (header.HostOS == 3 && type != 0 && type != 0100000 && type != 0040000)
        ? 2 : (header.Flags & RHDF_DIRECTORY) ? 1 : 0;
    entry->encrypted = (header.Flags & RHDF_ENCRYPTED) != 0;
    entry->splitBefore = (header.Flags & RHDF_SPLITBEFORE) != 0;
    return 0;
}

int op_rar_process(OPRar *r, int skip, OPRarWrite write, void *context) {
    r->write = write;
    r->context = context;
    // TEST emits verified plaintext through the callback and never lets UnRAR choose output paths.
    int error = RARProcessFile(r->archive, skip ? RAR_SKIP : RAR_TEST, nullptr, nullptr);
    r->write = nullptr;
    r->context = nullptr;
    return error;
}
const char *op_rar_missing_volume(OPRar *r) { return r->missing.c_str(); }
void op_rar_close(OPRar *r) { RARCloseArchive(r->archive); delete r; }
