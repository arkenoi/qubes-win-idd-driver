// dirty_union.h - the EXACT union of two rect lists, walked as row bands (rest-zero S1, docs/DESIGN-rest-zero-capture.md: "per arrival
// copy dirty(N) ∪ pendingOther into the spare ring buffer"; Jev fork 2026-10-01: the union of two frames' regions 0.95).
//
// WHY A UNION, measured 2026-10-03 (M9(b) on rz36): PublishCard wrote the previous arrival's rects and then this arrival's rects one
// after the other - the SUM - so every overlap was copied twice: a blinking caret's same 3x20 rect cost ~500 bytes per publish instead of
// 240, a marquee progress bar ~2x its rect. The design asks for the union.
//
// Header-only and Windows-free on purpose: tools/tests/dirty-union-test.cpp compiles this same file on Linux, so the code under test is
// the code that ships. No allocation failure path, no GDI regions - nothing to fall back from.
#pragma once
#include <algorithm>
#include <utility>
#include <vector>

// Calls f(y0, y1, x0, x1) for every run of the union: rows [y0, y1) x columns [x0, x1). Every pixel inside any rect of a or b is
// covered by exactly one run, and no pixel outside them by any. R needs left/top/right/bottom (RECT does).
template <typename R, typename F>
void ForEachUnionRun(const std::vector<R>& a, const std::vector<R>& b, F f) {
    std::vector<R> all;
    all.reserve(a.size() + b.size());
    for (const R& k : a) if (k.right > k.left && k.bottom > k.top) all.push_back(k);
    for (const R& k : b) if (k.right > k.left && k.bottom > k.top) all.push_back(k);
    // Bands: the rows between consecutive distinct top/bottom edges are covered by the same set of rects.
    std::vector<long> ys;
    ys.reserve(all.size() * 2);
    for (const R& k : all) { ys.push_back((long)k.top); ys.push_back((long)k.bottom); }
    std::sort(ys.begin(), ys.end());
    ys.erase(std::unique(ys.begin(), ys.end()), ys.end());
    std::vector<std::pair<long, long>> xs;
    for (size_t j = 0; j + 1 < ys.size(); j++) {
        const long y0 = ys[j], y1 = ys[j + 1];
        xs.clear();
        for (const R& k : all)
            if ((long)k.top <= y0 && (long)k.bottom >= y1) xs.emplace_back((long)k.left, (long)k.right);
        if (xs.empty()) continue;
        std::sort(xs.begin(), xs.end());
        long l = xs[0].first, r = xs[0].second;
        for (size_t n = 1; n < xs.size(); n++) {
            if (xs[n].first <= r) { if (xs[n].second > r) r = xs[n].second; }   // overlapping or touching: one run
            else { f(y0, y1, l, r); l = xs[n].first; r = xs[n].second; }
        }
        f(y0, y1, l, r);
    }
}
