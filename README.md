<img width="192" height="192" alt="Italian Heart Icon Collage Burst" src="https://github.com/user-attachments/assets/0c4dc2c2-f9a5-4cb6-b4e1-350e037152c8" />
# immagini

Fast, dependency-free image processing for [Crystal](https://crystal-lang.org).
Think "ImageMagick for .NET (`System.Drawing` / ImageSharp)", but small enough to read in an afternoon:
pure Crystal, no C bindings, no shards, one flat RGBA8 pixel buffer. Can be built as an executable.

```crystal
require "immagini"

img = Immagini::Image.open("photo.jpg", auto_orient: true)
img.fit(1200, 800).sharpen(0.8).save("web.jpg", quality: 88)
img.fill(256, 256).save("avatar.png")
```

* **Formats:** PNG, JPEG, BMP, PNM (read + write), sniffed from content.
* **Operations:** resize (6 filters), crop, rotate (any angle), flip, transpose, EXIF orient, pad, trim,
  grayscale/invert/sepia/brightness/contrast/gamma/levels/saturation/hue/threshold, gaussian & box blur,
  unsharp mask, convolution, Sobel edges, median, alpha compositing with 8 blend modes, histogram.
* **Size:** ~4,500 lines, 1.8 MB release CLI, links only libc, libm, libgcc_s, libz and libpcre2 (what any Crystal binary links).
* **Verified** against Pillow, libjpeg and ImageMagick output, and fuzzed with ~670,000 corrupted files (see [Verification](#verification)).

---

## Contents

1. [Install](#install) · 2. [Quick start](#quick-start) · 3. [CLI](#cli) · 4. [Design](#design)
5. [Codecs](#codecs) · 6. [Operations reference](#operations-reference) · 7. [How resampling works](#how-resampling-works)
8. [Performance](#performance) · 9. [Threading](#threading) · 10. [Verification](#verification)
11. [Limitations](#limitations) · 12. [Errors](#errors) · 13. [Project layout](#project-layout)

---

## Install

```yaml
# shard.yml
dependencies:
  immagini:
    github: your-org/immagini
```

Requires Crystal ≥ 1.16 (developed and tested on 1.16.3 / LLVM 18; older versions are untested). **Always build with
`--release`:** the pixel loops use raw pointers and rely on LLVM optimisation, and debug builds are much slower.

```sh
shards build --release                 # builds bin/immagini as executable
crystal build --release -Dpreview_mt app.cr   # opt in to multi-threaded operations (the user's own program)
```

## Quick start

Runnable version: [`examples/quickstart.cr`](examples/quickstart.cr).

```crystal
require "immagini"
include Immagini                        # optional: Image, Color, Filter, Format, Blend

img = Image.open("in.jpg", auto_orient: true)    # format sniffed, EXIF rotation applied
puts img                                         # => #<Immagini::Image 4000x3000 RGB>

# Every operation returns a NEW image, so calls chain.
img.thumbnail(320).save("thumb.jpg", quality: 85)          # format from extension
img.fill(256, 256).save("avatar.png")                      # cover + centre crop
img.fit(1200, 800).sharpen(0.8, amount: 0.6).saturation(1.15).save("web.jpg", quality: 88)

# Compositing
web   = img.fit(1200, 800)
badge = Image.new(160, 48, Color.rgba(0, 0, 0, 160))
web.composite!(badge, web.width - 176, web.height - 64)    # in-place variant

# Raw pixels, in memory
bytes = img.thumbnail(64).encode(Format::PNG)              # Bytes
back  = Image.decode(bytes)
img.pixels                                                 # Bytes, RGBA8, row-major, no padding
```

## CLI

Operations run **left to right**, as in ImageMagick.

```sh
immagini info photo.jpg
# photo.jpg: JPEG 4000x3000 RGB 2558677 bytes

immagini convert in.jpg out.png -resize 800x600 -sharpen 1.0
immagini convert in.jpg out.jpg -auto-orient -fill 400x400 -grayscale -quality 80
immagini convert in.jpg out.jpg -crop 500x300+100+50 -rotate 30 -background '#202020'
```

`-resize -fit -fill -contain -scale -thumbnail -crop -trim -rotate -flip -flop -transpose -auto-orient -grayscale
-invert -sepia -auto-contrast -brightness -contrast -gamma -saturation -hue -threshold -blur -sharpen -median -edges`,
plus `-filter -quality -compression -background`. `immagini --help` lists them. Exit codes: `0` ok, `1` I/O or
decode error, `2` bad usage.

---

## See Docs.md for Immagini User Guide

## Design

### One pixel format

Every image is a single flat, row-major, interleaved **RGBA8** `Bytes` (`width*height*4`, straight alpha).
Decoders write straight into it; operations read and write it. Consequences:

| Choice | Benefit | Cost |
|---|---|---|
| One format, no pixel-type generics | No per-format code paths, no dispatch, no monomorphisation bloat; tiny binary | Grayscale images use 4 B/px in memory |
| Flat `Bytes`, row stride = `width*4` | Contiguous memory; whole-image ops are one loop; trivially interoperable (`pixels` is yours) | Max `width*height ≤ 2²⁹` (Int32-sized buffer) |
| Straight alpha at rest | Matches PNG/BMP and what users expect from `[]` | Alpha-aware ops (resize, blur, rotate) premultiply internally, then un-premultiply |
| 8 bits per channel | Fastest path, covers >99% of use | No HDR/16-bit pipeline (16-bit PNG is reduced on load) |

### Hot-loop rules

* Hot loops use `Pointer(UInt8)` and `&+ &* ` wrapping arithmetic — no bounds checks, no overflow checks.
  Inputs are validated **once, up front** (dimensions, filter ranges, header sizes), never per pixel.
* All colour maths is **integer / fixed point**: LUTs for per-channel ops, 8.8 fixed point for matrices,
  14-bit weights for resampling and blur. Floats appear only in the JPEG forward DCT and the per-pixel coordinate maths of arbitrary-angle `rotate`.
* Row-major accumulation for vertical passes, so memory access stays sequential and the compiler can
  auto-vectorise.
* Mutating (`!`) variants exist where in-place is natural (`flip_*!`, `grayscale!`, `composite!`, `fill!`, …).

### Data flow

```
bytes ──► Format.detect ──► Codecs::{PNG,JPEG,BMP,PNM}.decode ──► Image (RGBA8)
                                                                      │
                          ops: geometry · resize · color · filters · composite
                                                                      │
Image ──► Codecs::*.encode (flattening alpha for JPEG/BMP-24/PNM) ──► IO / file
```

---

## Codecs

| Format | Decode | Encode |
|---|---|---|
| **PNG** | Gray, RGB, palette, gray+α, RGBA; 1/2/4/8/16-bit; `tRNS`; Adam7 interlace; chunk CRCs verified. 16-bit → 8-bit. Gamma/ICC ignored | 8-bit gray / gray+α / RGB / RGBA (narrowest lossless layout chosen automatically); 6 filter modes incl. per-row **adaptive**; zlib level 0-9; streamed 128 KiB `IDAT` chunks |
| **JPEG** | Baseline + extended sequential Huffman, 8-bit, 1 or 3 components, any sampling factors, restart intervals, libjpeg-style "fancy" chroma upsampling, Adobe RGB, EXIF orientation. **Not** progressive/arithmetic/12-bit/CMYK | Baseline, Annex K tables scaled by quality 1-100, 4:4:4 / 4:2:2 / 4:2:0 / gray, streamed per MCU row (O(width) memory), AAN float DCT |
| **BMP** | 1/4/8/16/24/32-bit, bit-fields (R/G/B/A masks), top-down/bottom-up, OS/2 core + INFO/V4/V5 headers. No RLE. 32-bit `BI_RGB` alpha used only if any pixel has it non-zero | 24-bit, or 32-bit BGRA (V4 header, alpha mask) when translucent |
| **PNM** | P1-P6, comments, `maxval` ≤ 65535 | P6, or P5 with `grayscale: true` |

* JPEG/BMP-24/PNM can't store alpha; on write, transparent pixels are composited onto `background:` (white by default).
* `Image.decode(bytes, auto_orient: true)` applies EXIF orientation 1-8 for JPEG. `Codecs::JPEG.orientation(bytes)`,
  `Codecs::JPEG.dimensions`, `Codecs::PNG.dimensions` read metadata without decoding pixels.
* The JPEG decoder uses a 64-bit bit reader, a 9-bit Huffman fast-lookup table, and the `jidctint` integer IDCT.

---

## Operations reference

All return a new `Image` unless marked `!`. `Filter` ∈ `Nearest Box Bilinear Mitchell Bicubic Lanczos3` (default `Lanczos3`).

**Geometry**

| Method | Notes |
|---|---|
| `resize(w, h, filter)` | Exact size, separable, alpha-aware |
| `scale(factor)`, `thumbnail(n)` | Proportional; `thumbnail` never enlarges |
| `fit(w, h, upscale: false)` | Fit inside the box, keep aspect |
| `fill(w, h, gravity_x:, gravity_y:)` | CSS `object-fit: cover` — scale then crop |
| `contain(w, h, background:)` | Letterbox onto a canvas |
| `crop(x, y, w, h)` | Raises `ArgumentError` if out of bounds |
| `flip_horizontal`, `flip_vertical` (+ `!`), `rotate90/180/270`, `transpose`, `transverse`, `orient(1..8)` | Lossless; one tiled 32×32 remap kernel |
| `rotate(deg, filter:, background:, expand: true)` | Any angle, clockwise; bilinear or nearest; exact multiples of 90 are lossless |
| `pad(l, t, r, b, color)`, `trim(tolerance)` | Add / remove uniform borders |

**Colour** — `grayscale`, `invert`, `brightness(n)`, `contrast(f)`, `gamma(g)`, `levels(black, white, gamma)`,
`threshold(n)`, `saturation(f)`, `hue_rotate(deg)`, `sepia`, `opacity(f)`, `auto_contrast`, `flatten(bg)`,
`histogram → {r, g, b, luma}`, `apply_lut!`. Per-channel ops run through a 256-entry LUT.

**Filters** — `blur(sigma, fast: false)`, `box_blur(r)`, `sharpen(sigma, amount, threshold)` (unsharp mask),
`convolve(kernel, divisor, bias)` (odd square kernels), `edges` (Sobel), `median(r)`.

**Compositing** — `composite(src, x, y, blend:, opacity:)` / `composite!`. `Blend` ∈ `Normal Multiply Screen
Overlay Darken Lighten Add Difference`. Straight-alpha source-over; clips to the destination.

**Pixel access** — `img[x, y]` (bounds-checked, raises `IndexError`), `img[x, y]?`, `img[x, y] = color`,
`unsafe_get/unsafe_set`, `row_ptr(y)`, `each_pixel`, `map_pixels!`, `fill!`, `to_rgb`, `to_gray`,
`Image.from_rgb`, `Image.from_gray`. `Color` is a 4-byte struct (`rgb`, `rgba`, `gray`, `hex`, `luma`, named constants).

---

## How resampling works

`resize` is **separable**: one horizontal pass, one vertical pass, through a per-axis table of integer taps.

1. **Tap window.** For output index *i* the kernel centre in source space is `c = (i + 0.5) · s` (`s = src/dst`).
   The kernel is stretched by `max(s, 1)` when shrinking so every source pixel contributes (area-correct, no aliasing).
   Source pixel *k* has its centre at *k + 0.5*, so the window is `[⌊c − r + ½⌋, ⌊c + r + ½⌋)` with `r = support · max(s,1)`.
   Weights are `filter((k + 0.5 − c) / max(s,1))`.
2. **Fixed point.** Weights are normalised, scaled by 2¹⁴, rounded, and the rounding residual is put on the
   largest tap so each row sums to *exactly* 16384. A flat region therefore reproduces **bit-exactly**
   (tested for every filter).
3. **Pass order.** The axis that shrinks the intermediate image most runs first.
4. **Alpha.** Translucent images are premultiplied before and un-premultiplied after, so transparent pixels
   don't bleed colour into neighbours. Fully opaque images skip both steps.

`blur` uses the same idea with a Gaussian kernel (radius `⌈3σ⌉`). `blur(σ, fast: true)` instead applies **three box
blurs** with widths chosen by the standard "boxes for gauss" formula, each a running sum — cost per pixel is
independent of σ, at the price of a slight shape error (typically < 1.5 grey levels mean vs exact).

---

## Performance

Measured on a 2-vCPU x86-64 container; Crystal 1.16.3 `--release`; Pillow 12.3.0 (plain, not SIMD fork); input is
a 4000×3000 (12 MP) photo-like image; best of 7 runs, in-memory bytes (no disk). Reproduce with
`crystal build --release bench/bench.cr && ./bench photo.jpg photo.png`. **Times in ms, lower is better.**

| Operation | immagini 1 thread | immagini 2 threads¹ | Pillow |
|---|---:|---:|---:|
| JPEG decode | 139 | 133 | **71** |
| PNG decode | **205** | 203 | 219 |
| JPEG encode q90 4:2:0 | 222 | 241 | **44** |
| PNG encode level 6, adaptive² | 1692 | 1739 | 1575 |
| PNG encode level 1² | 467 | 506 | 448 |
| resize 800×600 Lanczos | 139 | 75 | **40** |
| resize 800×600 bilinear | 55 | 30 | **20** |
| resize 6000×4500 bicubic (up) | 452 | 233 | **110** |
| rotate 90° | 23 | **13** | 34 |
| flip horizontal | 14 | 10 | **6** |
| rotate 17° bilinear, expand | 583 | **296** | 418 |
| grayscale | 22 | 17 | **8.5** |
| brightness (LUT) | 16 | **12** | 16 |
| gaussian blur σ=3, exact kernel | 856 | 415 | – |
| gaussian blur σ=3, `fast: true` | **282** | **145** | 351³ |
| unsharp mask σ=1 | 474 | **239** | 461 |
| convolve 3×3 | 263 | **129** | 271 |
| composite 2000×1500, 50% over | 21 | 20 | **9** |

¹ `-Dpreview_mt`, `CRYSTAL_WORKERS=2`. Only the pixel-processing operations are parallel; codecs are serial.
² Dominated by zlib deflate (the same library Pillow uses). Pillow's decode rows include `.convert('RGBA')`.
³ Pillow's `GaussianBlur` is itself a box-blur approximation, so compare with the `fast: true` row.

**Honest reading:** Pillow is hand-tuned C with SIMD. Immagini is on par or ahead for PNG, rotation, fast blur,
sharpen and convolution, but **2-5× slower for JPEG encode/decode, resizing and simple per-pixel ops** — Crystal has no
SIMD intrinsics and relies on LLVM auto-vectorisation. Against ImageMagick 6.9 (legacy, `-limit thread 1`)
end-to-end for the same command (JPEG in → PNG out, includes process start and 12 MP PNG encoding):

| Command | ImageMagick | immagini |
|---|---:|---:|
| `-resize 800x600` (Lanczos) | 543 ms | 432 ms |
| `-blur 3` | 4591 ms | 2570 ms |
| `-rotate 17` | 4925 ms | 3080 ms |
| grayscale | 3685 ms | 681 ms |

**Footprint:** release binary 1.8 MB; decode 12 MP JPEG → resize → encode peaks at **96 MB** RSS (the decoded RGBA
image is 48 MB; JPEG decoding keeps one plane per component).

---

## Threading

Crystal's multithreading is still opt-in (`-Dpreview_mt`). Immagini uses it through one primitive, `Parallel.bands`,
which splits an axis into contiguous bands and runs them on fibers. Without the flag it compiles to a **direct inline call** —
zero scheduling overhead. With it:

```sh
CRYSTAL_WORKERS=4 IMMAGINI_THREADS=4 ./app      # worker threads / bands (default: CPU count)
```
```crystal
Immagini::Parallel.threads = 2                  # or set in code
```

Rules that keep it correct: bands write only to their own rows (or column range); there is no shared mutable
state; results are **byte-identical for any thread count** (a spec compares 1 vs 4 threads for every parallel
operation and was verified to fail against the original closure bug).

---

## Verification

`crystal spec` (58 examples, passes in both serial and `-Dpreview_mt` builds) plus tooling in `tools/`.

* **Lossless codecs are pixel-exact** against a closed-form fixture; encoder output is read back by **PIL**
  and **ImageMagick**.
* **JPEG decode vs libjpeg** (via PIL) at 4:4:4, 4:2:2, 4:2:0, gray and restart intervals: mean error < 0.6, max ≤ 4.
* **Resize vs PIL**: bilinear / bicubic / Lanczos agree to rounding (mean < 0.1, max ≤ 3 on a harsh
  sawtooth image). Box differs a little at fractional scales (mean < 1); I believe this is tie-breaking for pixels
  lying exactly on the box edge, but have not isolated it.
* **Blur vs ImageMagick** `-gaussian-blur`: mean error < 1.
* **Fuzzing** (`tools/fuzz.cr`): bit flips, truncation and `0xFF` runs over every fixture format, ≈670,000 inputs
  across 7 seeds on the release build — decoders must either succeed or raise an `Immagini::Error`; nothing else may escape.

Bugs this process caught during development, now covered by regression specs: a **PNG `IEND` CRC of 0** (zlib's
`crc32` returns 0 for an empty buffer — lenient decoders tolerate it, strict ones reject the file); a **half-pixel
error in the resampling tap window** (up to 171 levels off on sharp edges before the fix); **integer overflow on hostile
headers** in BMP/PNM/PNG; and a **by-reference closure capture** in `Parallel.bands` that corrupted multi-threaded output.

---

## Limitations

* **Progressive JPEG is not decoded** (raises `UnsupportedError`). Many web photos are progressive; re-encode them first
  or convert with another tool. CMYK/YCCK and arithmetic-coded JPEG are also unsupported.
* **Metadata is not preserved on encode** (EXIF, ICC, text chunks). Orientation can be *applied* on load.
* **No palette PNG output**, no APNG, no interlaced output, no zopfli: files are larger than an optimising PNG tool's.
* **No GIF, WebP, TIFF, AVIF, SVG.** No text rendering or drawing primitives, no colour management (all maths is in
  gamma-encoded sRGB-ish space, like most 8-bit pipelines).
* **8 bits per channel**; 16-bit sources are truncated to 8.
* **Size limit:** `width × height ≤ 536,870,911` px (the buffer must fit an `Int32` byte count). A tiny hostile PNG can
  still *declare* dimensions that make the decoder allocate up to ~2 GB before the data runs out; run untrusted input
  under a memory limit.
* Multi-threading depends on Crystal's preview MT runtime. `Image` is not safe to mutate from several fibers at once.
* Speed gap to SIMD libraries — see [Performance](#performance).

## Errors

| Class | When |
|---|---|
| `Immagini::Error` | Base class of everything below |
| `UnknownFormatError` | Can't identify the format (content or extension) |
| `DecodeError` | Corrupt / truncated data, failed CRC, hostile header |
| `UnsupportedError` | Valid file using an unimplemented feature (e.g. progressive JPEG) |
| `ArgumentError` / `IndexError` | Bad parameter (negative radius, crop outside image) / out-of-bounds `img[x, y]` |

## Project layout

```
src/immagini.cr              entry point (requires everything)
src/cli.cr                   command line front end
src/immagini/image.cr        Image: storage, accessors, bulk helpers
src/immagini/color.cr        Color struct, clamp/div255 helpers
src/immagini/pixels.cr       premultiply, kernel quantisation
src/immagini/parallel.cr     Parallel.bands
src/immagini/format.cr       Format enum, sniffing, decode/encode/save
src/immagini/codecs/         png.cr  jpeg.cr (+_decoder, _encoder)  bmp.cr  pnm.cr
src/immagini/ops/            resize.cr  geometry.cr  color_ops.cr  filters.cr  composite.cr
spec/                        specs + fixtures generated by independent encoders (PIL/ImageMagick)
bench/bench.cr               benchmark harness
tools/fuzz.cr                decoder fuzzer
examples/quickstart.cr       runnable tour
```

## License

MIT
