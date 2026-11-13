#include "../policy.hpp"
#include <algorithm>
#include <cstdlib>
#include <cstdio>
#include <vector>

using namespace dozor;

// Evaluate the production-generated filter plan in a synthetic WFP sublayer.
int main() {
    std::vector<Rule> rules;
    for (auto action : {Action::block, Action::permit})
        forEachRule(action, [&](Rule r) { rules.push_back(r); });
    std::sort(rules.begin(), rules.end(), [](Rule a, Rule b) { return a.weight > b.weight; });

    unsigned scenarios = 0;
    for (auto family : {Family::ipv4, Family::ipv6})
    for (bool session : {true, false})
    for (unsigned local : {0, 1, 2}) // unknown, VPN, other
    for (unsigned next : {0, 1, 2}) {
        bool matched = false;
        for (auto rule : rules) {
            if (rule.family != family || (!session && !rule.persistent)) continue;
            if (rule.matchVpnInterfaces && (local != 1 || next != 1)) continue;
            if ((rule.action == Action::permit) != (session && local == 1 && next == 1)) return EXIT_FAILURE;
            matched = true;
            break;
        }
        if (!matched) return EXIT_FAILURE;
        ++scenarios;
    }
    std::printf("PASS: %u IPv4/IPv6 policy scenarios\n", scenarios);
}
