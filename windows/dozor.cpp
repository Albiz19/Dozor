// Build with the Windows 10+ SDK. See README.md.
#define WIN32_LEAN_AND_MEAN
#define _WIN32_WINNT 0x0A00
#include <winsock2.h>
#include <ws2tcpip.h>
#include <windows.h>
#include <initguid.h>
#include <fwpmu.h>
#include <iphlpapi.h>
#include <netioapi.h>
#include <bcrypt.h>
#include <objbase.h>
#include <cstdio>
#include <cstring>
#include <string>
#include <filesystem>
#include "policy.hpp"

#pragma comment(lib, "fwpuclnt.lib")
#pragma comment(lib, "iphlpapi.lib")
#pragma comment(lib, "bcrypt.lib")
#pragma comment(lib, "ole32.lib")

namespace {
const GUID sublayer = {0xd9dd64fe,0x19dd,0x4370,{0x8f,0xb1,0x98,0xf2,0x4a,0x35,0xa7,0x38}};
struct Failure { const char* what; DWORD code; };
void check(DWORD code, const char* what) { if (code) throw Failure{what, code}; }
struct Engine {
    HANDLE h = nullptr;
    explicit Engine(bool dynamic) {
        FWPM_SESSION0 s{};
        s.flags = dynamic ? FWPM_SESSION_FLAG_DYNAMIC : 0;
        check(FwpmEngineOpen0(nullptr, RPC_C_AUTHN_WINNT, nullptr, &s, &h), "open BFE (run as administrator)");
    }
    ~Engine() { FwpmEngineClose0(h); }
};
struct Transaction {
    HANDLE h;
    bool committed = false;
    explicit Transaction(HANDLE handle) : h(handle) { check(FwpmTransactionBegin0(h, 0), "begin transaction"); }
    void commit() { check(FwpmTransactionCommit0(h), "commit transaction"); committed = true; }
    ~Transaction() { if (!committed) FwpmTransactionAbort0(h); }
};
struct App {
    FWP_BYTE_BLOB* id = nullptr;
    explicit App(const wchar_t* path) {
        std::filesystem::path p(path);
        if (!p.is_absolute() || !std::filesystem::is_regular_file(p) || _wcsicmp(p.extension().c_str(), L".exe"))
            throw Failure{"expected an absolute path to an existing .exe", ERROR_INVALID_PARAMETER};
        check(FwpmGetAppIdFromFileName0(p.c_str(), &id), "resolve executable identity");
    }
    ~App() { if (id) FwpmFreeMemory0(reinterpret_cast<void**>(&id)); }
};
// Persistent filter ID depends on the canonical WFP app id and the address family.
GUID lockId(const App& app, dozor::Family family) {
    BYTE digest[32];
    BCRYPT_ALG_HANDLE algorithm{};
    check(BCryptOpenAlgorithmProvider(&algorithm, BCRYPT_SHA256_ALGORITHM, nullptr, 0), "open SHA256");
    auto result = BCryptHash(algorithm, nullptr, 0, app.id->data, app.id->size, digest, sizeof(digest));
    BCryptCloseAlgorithmProvider(algorithm, 0);
    check(result, "hash app path");
    GUID key{};
    std::memcpy(&key, digest, sizeof(key));
    key.Data1 ^= sublayer.Data1;
    key.Data4[7] ^= family == dozor::Family::ipv4 ? 4 : 6;
    return key;
}
void ensureSublayer(HANDLE h) {
    FWPM_SUBLAYER0 layer{};
    layer.subLayerKey = sublayer;
    layer.displayData.name = const_cast<wchar_t*>(L"Dozor per-program VPN");
    layer.flags = FWPM_SUBLAYER_FLAG_PERSISTENT;
    layer.weight = 0x7000;
    auto r = FwpmSubLayerAdd0(h, &layer, nullptr);
    if (r != FWP_E_ALREADY_EXISTS) check(r, "create Dozor sublayer");
}
void changeRule(HANDLE h, const App& app, dozor::Rule rule, UINT64 vpn, bool remove) {
    FWPM_FILTER0 filter{};
    if (rule.persistent) filter.filterKey = lockId(app, rule.family);
    if (rule.persistent) {
        // Replacement occurs inside the caller's transaction, without a rule gap.
        auto r = FwpmFilterDeleteByKey0(h, &filter.filterKey);
        if (r != FWP_E_FILTER_NOT_FOUND) check(r, "remove Dozor lock");
        if (remove) return;
    }

    FWPM_FILTER_CONDITION0 cond[3]{};
    cond[0].fieldKey = FWPM_CONDITION_ALE_APP_ID;
    cond[0].matchType = FWP_MATCH_EQUAL;
    cond[0].conditionValue.type = FWP_BYTE_BLOB_TYPE;
    cond[0].conditionValue.byteBlob = app.id;
    if (rule.matchVpnInterfaces) {
        cond[1].fieldKey = FWPM_CONDITION_IP_LOCAL_INTERFACE;
        cond[2].fieldKey = FWPM_CONDITION_IP_NEXTHOP_INTERFACE;
        for (unsigned i = 1; i <= 2; ++i) {
            cond[i].matchType = FWP_MATCH_EQUAL;
            cond[i].conditionValue.type = FWP_UINT64;
            cond[i].conditionValue.uint64 = &vpn;
        }
    }
    filter.displayData.name = const_cast<wchar_t*>(rule.persistent ? L"Dozor: lock program" : L"Dozor: selected VPN");
    filter.layerKey = rule.family == dozor::Family::ipv4 ? FWPM_LAYER_ALE_AUTH_CONNECT_V4 : FWPM_LAYER_ALE_AUTH_CONNECT_V6;
    filter.subLayerKey = sublayer;
    filter.flags = rule.persistent ? FWPM_FILTER_FLAG_PERSISTENT : 0;
    filter.action.type = rule.action == dozor::Action::block ? FWP_ACTION_BLOCK : FWP_ACTION_PERMIT;
    filter.weight.type = FWP_UINT8;
    filter.weight.uint8 = rule.weight;
    filter.numFilterConditions = rule.matchVpnInterfaces ? 3 : 1;
    filter.filterCondition = cond;
    auto r = FwpmFilterAdd0(h, &filter, nullptr, nullptr);
    check(r, "install WFP rule");
}
void changeApps(HANDLE engine, dozor::Action action, UINT64 vpn, bool remove, int count, wchar_t** paths) {
    Transaction tx(engine);
    if (action == dozor::Action::block && !remove) ensureSublayer(engine);
    for (int i = 0; i < count; ++i) {
        App app(paths[i]);
        dozor::forEachRule(action, [&](dozor::Rule rule) { changeRule(engine, app, rule, vpn, remove); });
    }
    tx.commit();
}
UINT64 tunnel(const GUID& id) {
#ifdef DOZOR_TEST_LOOPBACK
    // This executable is built only for the disposable CI client.
    // Resolve the adapter through a kernel route lookup, never through an external request.
    SOCKADDR_INET address{};
    address.Ipv4.sin_family = AF_INET;
    address.Ipv4.sin_addr.s_addr = htonl(INADDR_LOOPBACK);
    MIB_IPFORWARD_ROW2 route{};
    SOCKADDR_INET source{};
    check(GetBestRoute2(nullptr, 0, nullptr, &address, 0, &route, &source), "resolve fixture loopback");
    return route.InterfaceLuid.Value;
#else
    NET_LUID luid{};
    check(ConvertInterfaceGuidToLuid(&id, &luid), "resolve interface GUID");
    MIB_IF_ROW2 row{};
    row.InterfaceLuid = luid;
    check(GetIfEntry2(&row), "inspect VPN interface");
    if (row.OperStatus != IfOperStatusUp || row.InterfaceAndOperStatusFlags.HardwareInterface ||
        row.Type == IF_TYPE_SOFTWARE_LOOPBACK || !luid.Value)
        throw Failure{"selected interface must be virtual, up, and not loopback", ERROR_NOT_READY};
    return luid.Value;
#endif
}
}
int wmain(int argc, wchar_t** argv) {
    if (argc < 3) {
        std::fputs("dozor-win lock APP.exe [...]\ndozor-win guard {VPN-GUID} APP.exe [...]\ndozor-win unlock APP.exe [...]\n", stderr);
        return 2;
    }
    try {
        const std::wstring command(argv[1]);
        bool guard = command == L"guard", remove = command == L"unlock";
        if ((!guard && !remove && command != L"lock") || (guard && argc < 4))
            throw Failure{"invalid arguments", ERROR_INVALID_PARAMETER};
        // Prevent a second instance from leaving a permit on another tunnel.
        HANDLE mutex = CreateMutexW(nullptr, TRUE, L"Global\\DozorPerProgramWfp-5fa60f49");
        if (!mutex) check(GetLastError(), "create guard mutex");
        if (GetLastError() == ERROR_ALREADY_EXISTS) throw Failure{"another Dozor command is active", ERROR_BUSY};
        Engine persistent(false);
        int first = guard ? 3 : 2;
        changeApps(persistent.h, dozor::Action::block, 0, remove, argc - first, argv + first);
        if (guard) {
            GUID id{};
            check(CLSIDFromString(argv[2], &id), "parse VPN adapter GUID (programs remain locked)");
            UINT64 luid = tunnel(id);
            Engine dynamic(true);
            changeApps(dynamic.h, dozor::Action::permit, luid, false, argc - first, argv + first);
            std::puts("VPN rules active. Ctrl+C closes the temporary permits. Persistent locks remain.");
            std::fflush(stdout);
            for (;;) {
                Sleep(500);
                if (tunnel(id) != luid) throw Failure{"VPN identity changed; closing permits", ERROR_NOT_READY};
            }
        }
        std::puts(remove ? "Selected program locks removed." : "Selected programs locked for new outbound connections.");
    } catch (const Failure& failure) {
        std::fprintf(stderr, "%s (0x%08lx)\n", failure.what, failure.code);
        return 1;
    } catch (const std::exception& error) {
        std::fprintf(stderr, "%s\n", error.what());
        return 1;
    }
    return 0;
}
