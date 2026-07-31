# Retracted findings — kept so the errors are not silently rewritten

1. **Framebuffer tearing** - a crop-alignment bug in `compare-views.py`. Aligned, the same
   captures read mean abs difference 0.1/255. No such defect. (`ARTIFACT-TEARING.md`)
2. **"One frame of lag" wobble measurement** - capture skew; the tool cannot measure a moving
   window. (`WOBBLE-STATUS.md`)
3. **Content-truncation regression, bisected to `3174d67e`** - the discriminator swung the full
   range on ONE unchanged binary and inverted when interleaved. The whole bisect is void, and
   so is the claim that our build truncated content where stock did not. Cause was an unsettled
   scene, fixed in `scene.ps1`. (`BISECT-TRUNCATION.md`)
4. **Drag regression from gating the per-frame work** - harness contamination: the bench dragged
   across windows left by the visual scene. Fixed; spread fell from 2.0x to 1.26x.
   (`DRAG-CURRENT.md`)
5. **Cold-boot defect bisected to the capture-thread desktop re-attach** - single samples of a
   check later shown to fail ~1 boot in 3. Void. Real cause in `COLDBOOT-ROOTCAUSE.md`.
6. **Hidden-window occlusion "regression that would have shipped"** - the test written for it
   passed on a build with the defect deliberately re-introduced, because hiding a window unmaps
   it and sinks it in z-order. Unreachable; the guard stands as defensive correctness only.

Common thread: each was a confident number from an instrument that had never been shown to
fail, or to be stable, before it was trusted. The rules that catch this are in CLAUDE.md.
