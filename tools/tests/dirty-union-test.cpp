// dirty-union-test.cpp - tools/wgcbroker/dirty_union.h (the broker's union of two frames' dirty regions) against a per-pixel reference.
// Compiles the SHIPPED header on Linux: g++ -std=c++17 -O1 -o /tmp/dut tools/tests/dirty-union-test.cpp && /tmp/dut
// For random rect lists (overlapping, nested, touching, identical, empty) every pixel of the union must be copied EXACTLY once and no
// pixel outside it at all; plus the measured cases: a caret's same 3x20 rect in both lists (240 bytes, not 480) and two consecutive
// marquee rects. -DUNION_DEFECT walks the two lists one after the other (the sum, as PublishCard did before 2026-10-03) - this test
// must then FAIL on the double copies.
#include "../wgcbroker/dirty_union.h"
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <vector>

struct Rc { long left, top, right, bottom; };

template <typename F>
static void Walk(const std::vector<Rc>& a, const std::vector<Rc>& b, F f) {
#ifdef UNION_DEFECT
    for (const Rc& k : a) if (k.right > k.left && k.bottom > k.top) f(k.top, k.bottom, k.left, k.right);
    for (const Rc& k : b) if (k.right > k.left && k.bottom > k.top) f(k.top, k.bottom, k.left, k.right);
#else
    ForEachUnionRun(a, b, f);
#endif
}

static int fails = 0;
static void Check(const char* what, bool ok) { if (!ok) { printf("FAIL %s\n", what); fails++; } }

// Copies through the walk into a W x H canvas, counting writes per pixel; returns the bytes a 32-bpp copy would move.
static long long Run(const std::vector<Rc>& a, const std::vector<Rc>& b, int W, int H, std::vector<int>& cnt) {
    cnt.assign((size_t)W * H, 0);
    long long bytes = 0;
    Walk(a, b, [&](long y0, long y1, long l, long r) {
        for (long y = y0; y < y1; y++) for (long x = l; x < r; x++) cnt[(size_t)y * W + x]++;
        bytes += (long long)(r - l) * (y1 - y0) * 4;
    });
    return bytes;
}

static bool Inside(const std::vector<Rc>& v, long x, long y) {
    for (const Rc& k : v) if (x >= k.left && x < k.right && y >= k.top && y < k.bottom) return true;
    return false;
}

int main() {
    const int W = 64, H = 48;
    std::vector<int> cnt;
    // the caret: the same 3x20 rect in both lists -> 60 px, 240 bytes, once
    {
        std::vector<Rc> a = {{100 - 90, 5, 103 - 90, 25}}, b = a;
        long long by = Run(a, b, W, H, cnt);
        Check("caret: the same 3x20 rect in both lists is copied once (240 bytes)", by == 240);
    }
    // two consecutive marquee positions on a 40x3 bar, overlapping by 30 px
    {
        std::vector<Rc> a = {{2, 10, 42, 13}}, b = {{12, 10, 52, 13}};
        long long by = Run(a, b, W, H, cnt);
        Check("marquee: two overlapping bar rects are copied as their union (50x3)", by == 50 * 3 * 4);
    }
    // random lists: exactness
    srand(12345);
    int cases = 0;
    for (int t = 0; t < 4000; t++) {
        std::vector<Rc> a, b;
        int na = rand() % 5, nb = rand() % 5;
        auto rr = [&]() { long x0 = rand() % W, y0 = rand() % H; long x1 = x0 + rand() % (W - x0 + 1), y1 = y0 + rand() % (H - y0 + 1);
                          return Rc{x0, y0, x1, y1}; };
        for (int i = 0; i < na; i++) a.push_back(rr());
        for (int i = 0; i < nb; i++) b.push_back(rr());
        if (t % 7 == 0 && !a.empty()) b.push_back(a[0]);                      // an identical rect in both lists
        if (t % 11 == 0 && !b.empty() && b[0].right < W) b.push_back(Rc{b[0].right, b[0].top, b[0].right + 3 > W ? W : b[0].right + 3, b[0].bottom});   // a touching one, inside the canvas
        long long by = Run(a, b, W, H, cnt);
        long long want = 0;
        bool ok = true;
        for (long y = 0; y < H && ok; y++)
            for (long x = 0; x < W && ok; x++) {
                bool in = Inside(a, x, y) || Inside(b, x, y);
                int c = cnt[(size_t)y * W + x];
                if (in) want += 4;
                if ((in && c != 1) || (!in && c != 0)) ok = false;
            }
        if (!ok || by != want) { if (fails < 3) printf("FAIL random case %d: a pixel copied %s\n", t, ok ? "right, bytes wrong" : "not exactly once"); fails++; }
        cases++;
    }
    if (fails) { printf("FAIL %d check(s) over %d random cases + 2 measured cases\n", fails, cases); return 1; }
    printf("PASS every pixel of the union copied exactly once, none outside (%d random cases + the caret and marquee cases)\n", cases);
    return 0;
}
