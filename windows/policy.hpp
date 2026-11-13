#pragma once
#include <initializer_list>

namespace dozor {
enum class Family { ipv4, ipv6 };
enum class Action { block, permit };
struct Rule {
    Family family;
    Action action;
    unsigned char weight;
    bool persistent;
    bool matchVpnInterfaces;
};

template<class Add> void forEachRule(Action action, Add add) {
    const bool permit = action == Action::permit;
    for (auto family : {Family::ipv4, Family::ipv6})
        add(Rule{family, action, static_cast<unsigned char>(permit ? 15 : 1), !permit, permit});
}
}
