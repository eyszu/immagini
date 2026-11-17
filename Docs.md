# Immagini User Guide

A hands-on guide to **immagini**, in two parts:

* **Part 1 – Command line.** Edit images from your terminal. No programming needed.
* **Part 2 – Crystal programs.** Use the library from your own code.

The commands, code samples and complete programs here were all run against the real library. (The cheat sheet at the end is a summary, not a runnable listing.)

> New to this? Read **Part 1, sections 1-3**, then jump to the [recipes](#5-recipes). Programmers can go straight to [Part 2](#part-2--using-immagini-in-crystal-programs).

---

## Contents

**Part 1 – Command line**
1. [Install and build](#1-install-and-build) · 2. [Your first command](#2-your-first-command) ·
3. [How commands are read](#3-how-commands-are-read) · 4. [Every operation](#4-every-operation) ·
5. [Recipes](#5-recipes) · 6. [Batch processing](#6-batch-processing) · 7. [CLI troubleshooting](#7-cli-troubleshooting)

**Part 2 – Crystal**
8. [Add it to a project](#8-add-it-to-a-project) · 9. [Open, save, convert](#9-open-save-convert) ·
10. [The golden rule: methods return new images](#10-the-golden-rule) · 11. [Resizing](#11-resizing) ·
12. [Crop, rotate, flip](#12-crop-rotate-flip) · 13. [Colour adjustments](#13-colour-adjustments) ·
14. [Blur, sharpen, filters](#14-blur-sharpen-filters) · 15. [Compositing and watermarks](#15-compositing-and-watermarks) ·
16. [Working with pixels and colours](#16-working-with-pixels-and-colours) · 17. [Memory, bytes and streams](#17-memory-bytes-and-streams) ·
18. [Handling errors](#18-handling-errors) · 19. [Making it fast](#19-making-it-fast) · 20. [Complete programs](#20-complete-programs) ·
21. [Cheat sheet](#21-cheat-sheet)

---

# Part 1 – Command line

## 1. Install and build

You need [Crystal](https://crystal-lang.org/install/) 1.16 or newer. From the project folder:

```sh
shards build --release
```

This creates `bin/immagini`. **Always use `--release`**: without it the program is much slower.

Check that it works:

```sh
bin/immagini --help
```

Tip: copy it somewhere on your `PATH` so you can type just `immagini`:

```sh
sudo cp bin/immagini /usr/local/bin/
```

The rest of this guide writes `immagini`; use `bin/immagini` if you haven't installed it.

## 2. Your first command

Two commands cover everything.

**`info`** tells you about a file:

```sh
immagini info photo.jpg
# photo.jpg: JPEG 4000x3000 RGB 2558677 bytes
```

**`convert`** reads an image, applies operations, and writes a new one:

```sh
immagini convert INPUT OUTPUT [operations...] [options...]
```

Make a small copy of a photo:

```sh
immagini convert photo.jpg small.jpg -resize 800x600
```

That's it. The **output format is chosen by the file extension** of `OUTPUT`, so converting between formats needs no extra flag:

```sh
immagini convert photo.jpg photo.png      # JPEG → PNG
immagini convert logo.png logo.bmp        # PNG → BMP
immagini convert photo.jpg photo.ppm      # → PPM
immagini convert photo.jpg photo.pgm      # → grayscale PGM
```

| Extension | Format |
|---|---|
| `.png` | PNG |
| `.jpg` `.jpeg` | JPEG |
| `.bmp` | BMP |
| `.ppm` `.pnm` | PNM colour |
| `.pgm` | PNM grayscale |

The **input** format is detected from the file's content, not its name, so a PNG accidentally named `.jpg` still opens.

Your original file is never modified. Immagini always writes a new file.

## 3. How commands are read

Understanding three rules prevents most confusion.

**Rule 1: operations run left to right, in the order you type them.**

```sh
# shrink first, THEN sharpen (sharpening the small image)
immagini convert in.jpg out.jpg -resize 800x600 -sharpen 1

# sharpen first, THEN shrink (different result)
immagini convert in.jpg out.jpg -sharpen 1 -resize 800x600
```

For quality, the usual order is: orient → crop → resize → colour tweaks → sharpen last.

**Rule 2: options can go anywhere.** `-filter`, `-quality`, `-compression` and `-background` are *settings*, not steps. They apply to the whole command wherever you place them.

**Rule 3: sizes are written `WIDTHxHEIGHT`** with a lowercase `x` and no spaces: `800x600`. A crop adds an offset: `WIDTHxHEIGHT+X+Y`.

If something is wrong you get a message and a non-zero exit code: `1` for a file or decoding problem, `2` for a usage mistake. That makes it easy to use in scripts (`immagini ... || echo failed`).

## 4. Every operation

### Resizing

| Operation | What it does |
|---|---|
| `-resize WxH` | Forces the **exact** size. May stretch the picture. |
| `-fit WxH` | Shrinks to fit **inside** the box, keeping proportions. Won't enlarge. |
| `-fill WxH` | Fills the box **completely**, keeping proportions, then centre-crops the overflow. Always gives exactly `WxH`. |
| `-contain WxH` | Fits inside the box and pads the rest with the background colour (letterbox). Always gives exactly `WxH`. |
| `-scale F` | Multiplies both sides by `F`. `0.5` = half size, `2` = double. |
| `-thumbnail N` | Fits inside an `N`×`N` square. Won't enlarge. |

Which should I pick?

For a 400×200 photo and a 100×100 box:

| Operation | Result size | What happened to the picture |
|---|---|---|
| `-resize 100x100` | 100×100 | Stretched (squashed vertically) |
| `-fit 100x100` | 100×50 | Shrunk, nothing cut, box not filled |
| `-fill 100x100` | 100×100 | Shrunk, then left and right edges cropped |
| `-contain 100x100` | 100×100 | Shrunk to 100×50, with bands of background above and below |

* Need an exact size and don't care about distortion → `-resize`.
* Need "no bigger than" (web gallery) → `-fit` or `-thumbnail`.
* Need a uniform grid of squares (avatars, cards) → `-fill`.
* Need a uniform size with nothing cut off → `-contain`.

```sh
immagini convert photo.jpg card.jpg   -fill 600x400
immagini convert photo.jpg square.png -contain 500x500 -background '#ffffff'
immagini convert photo.jpg half.jpg   -scale 0.5
```

### Cropping and trimming

```sh
# a 500x300 rectangle whose top-left corner is 100 pixels from the left, 50 from the top
immagini convert photo.jpg part.jpg -crop 500x300+100+50

# remove a uniform border (colour taken from the top-left pixel)
immagini convert scan.png clean.png -trim

# same, but treat colours within 12 levels (per channel) as "the same"
immagini convert scan.png clean.png -trim 12
```

If the crop rectangle sticks out of the image you get an error instead of a surprise.

### Rotating and flipping

| Operation | What it does |
|---|---|
| `-rotate DEG` | Rotates **clockwise** by any angle. `-rotate -15` goes the other way. |
| `-flip` | Mirrors **top ↔ bottom**. |
| `-flop` | Mirrors **left ↔ right**. |
| `-transpose` | Swaps x and y (mirrors across the diagonal). |
| `-auto-orient` | Applies the camera's EXIF rotation so a phone photo displays upright. |

Multiples of 90° are lossless and fast. Other angles enlarge the canvas to fit the whole picture; the new corners are filled with `-background` (white by default):

```sh
immagini convert photo.jpg a.jpg -rotate 90
immagini convert photo.jpg b.jpg -rotate 15 -background '#202020'
immagini convert phone.jpg up.jpg -auto-orient
```

> **Mnemonic:** "flip" is like flipping a pancake (vertical); "flop" is a flop sideways (horizontal). Same as ImageMagick.

### Colour

| Operation | Range / meaning |
|---|---|
| `-grayscale` | Black and white. |
| `-invert` | Photographic negative. |
| `-sepia` | Warm brown vintage tone. |
| `-brightness N` | Add `N` to every channel, `-255`..`255`. `+30` is a little brighter. |
| `-contrast F` | `1` = unchanged, `0` = flat grey, `1.3` = punchier. |
| `-gamma F` | `>1` brightens midtones, `<1` darkens them; shadows and highlights barely change. |
| `-saturation F` | `0` = grey, `1` = unchanged, `1.5` = vivid. |
| `-hue DEG` | Rotates all hues around the colour wheel. |
| `-threshold N` | Pure black/white: brighter than `N` (0-255) becomes white. |
| `-auto-contrast` | Stretches the tones actually used to fill 0-255. Fixes flat, hazy images. |

```sh
immagini convert photo.jpg warm.jpg  -brightness 15 -contrast 1.15 -saturation 1.2
immagini convert scan.jpg bw.png     -grayscale -auto-contrast -threshold 140
immagini convert photo.jpg moody.jpg -sepia -contrast 1.2
```

### Blur, sharpen, detail

| Operation | What it does |
|---|---|
| `-blur S` | Gaussian blur. `S` is the strength in pixels (sigma). Try 1-3 for soft, 10+ for background blur. |
| `-sharpen S` | Unsharp mask with detail radius `S`. `0.8`-`1.5` is typical. |
| `-median R` | Removes speckle noise (salt-and-pepper). `R` = radius, keep it `1`-`2`; it is slow for big values. |
| `-edges` | Black-and-white outline image (Sobel). |

```sh
immagini convert noisy.png clean.png -median 1
immagini convert photo.jpg soft.jpg -blur 2
immagini convert photo.jpg lines.png -edges
```

### Settings (options)

| Option | Default | Meaning |
|---|---|---|
| `-filter NAME` | `lanczos` | Resampling method for resize/fit/fill/contain/scale/thumbnail. See below. |
| `-quality N` | `90` | JPEG quality 1-100. |
| `-compression N` | `6` | PNG compression 0-9 (0 = fastest/biggest, 9 = slowest/smallest). |
| `-background HEX` | `#ffffff` | Colour for transparent areas, rotation corners, `-contain` padding. Forms: `#rgb`, `#rgba`, `#rrggbb`, `#rrggbbaa`. |

**Choosing a `-filter`:**

| Filter | Speed | Look | Use for |
|---|---|---|---|
| `nearest` | fastest | blocky | pixel art, icons you want crisp |
| `box` | fast | soft | shrinking a lot, quickly |
| `bilinear` | fast | smooth | general quick resize |
| `bicubic` | medium | sharper | enlarging |
| `mitchell` | medium | soft, no halos | smooth enlarging |
| `lanczos` | slowest | sharpest | **photos (default)** |

**Choosing `-quality`** (JPEG): 90 is visually near-lossless; 80 is a good web default; below 60 you will see blockiness. Lower quality = smaller file.

**Transparency note.** JPEG, BMP (24-bit) and PNM can't store transparency. When you save a see-through image to those formats, transparent areas are filled with `-background`. Save as `.png` to keep transparency.

## 5. Recipes

Copy, paste, adjust.

**Web-ready photo** (fit in 1600 px, light sharpening, good size):
```sh
immagini convert photo.jpg web.jpg -auto-orient -fit 1600x1600 -sharpen 0.8 -quality 82
```

**Thumbnail:**
```sh
immagini convert photo.jpg thumb.jpg -thumbnail 320 -quality 80
```

**Square avatar:**
```sh
immagini convert photo.jpg avatar.png -auto-orient -fill 256x256
```

**Black-and-white, high contrast:**
```sh
immagini convert photo.jpg bw.jpg -grayscale -auto-contrast -contrast 1.2
```

**Fix a sideways phone photo:**
```sh
immagini convert IMG_1234.jpg upright.jpg -auto-orient
```

**Blurred background banner** (make a wide, soft image from a photo):
```sh
immagini convert photo.jpg banner.jpg -fill 1600x400 -blur 6 -brightness -20
```

**Clean up a scan** (remove border, whiten paper, sharpen):
```sh
immagini convert scan.png clean.png -trim 20 -auto-contrast -sharpen 1
```

**Convert a folder format-by-format** — see the next section.

**Shrink a PNG's file size** (JPEG is smaller for photos; for PNG raise compression):
```sh
immagini convert big.png smaller.png -compression 9
```

**Pixel-art enlargement** (keep hard edges):
```sh
immagini convert sprite.png sprite4x.png -scale 4 -filter nearest
```

**Inspect before and after:**
```sh
immagini info original.jpg
immagini info result.jpg
```

## 6. Batch processing

Immagini handles one file per command; your shell repeats it.

**Make thumbnails for every JPEG in a folder** (bash/zsh):

```sh
mkdir -p thumbs
for f in *.jpg; do
  immagini convert "$f" "thumbs/$f" -auto-orient -thumbnail 320 -quality 80
done
```

**Convert all PNGs to JPEG:**

```sh
for f in *.png; do
  immagini convert "$f" "${f%.png}.jpg" -quality 85 -background '#ffffff'
done
```

**Stop and report problems instead of ignoring them:**

```sh
for f in *.jpg; do
  immagini convert "$f" "out/$f" -fit 1200x1200 || echo "FAILED: $f"
done
```

**Use all your CPU cores.** A single command is already multi-threaded if built with `-Dpreview_mt` (see [section 19](#19-making-it-fast)). Alternatively, run several files in parallel with `xargs`:

```sh
ls *.jpg | xargs -P 4 -I{} immagini convert {} out/{} -fit 1200x1200
```

(Create the `out` folder first.)

## 7. CLI troubleshooting

| Message / symptom | Cause and fix |
|---|---|
| `unknown option "-resise"` | Typo in an operation. Run `immagini --help` for the list. |
| `expected WxH, got "800"` | Sizes need both numbers: `800x600`. |
| `-resize needs a value` | You ended the command after the operation name. |
| `-crop expects WxH+X+Y` | Write all four numbers: `500x300+100+50`. |
| `crop rectangle ... is outside the ... image` | The crop box extends beyond the picture. Check with `immagini info`. |
| `progressive JPEG is not supported` | Some web JPEGs are "progressive". Re-save it as a baseline JPEG or PNG with another tool first. This is a known limitation. |
| `unrecognised image format` | The file isn't PNG/JPEG/BMP/PNM (e.g. GIF, WebP, TIFF are not supported). |
| `cannot infer format from "out.xyz"` | Use a supported output extension. |
| Output is slow | You are running a debug build. Rebuild with `shards build --release`. |
| JPEG has a white background where it was transparent | Expected: JPEG can't be transparent. Use `.png` or pick `-background`. |

---

# Part 2 – Using immagini in Crystal programs

## 8. Add it to a project

In your project's `shard.yml`:

```yaml
dependencies:
  immagini:
    github: your-org/immagini   # or:  path: ../immagini
```

Run `shards install`, then in your code:

```crystal
require "immagini"
```

Everything lives in the `Immagini` module. To avoid typing the prefix you can add `include Immagini` at the top level. The examples below use the prefix so it's always clear where things come from.

Build your program with `crystal build --release my_program.cr`.

## 9. Open, save, convert

```crystal
require "immagini"

img = Immagini::Image.open("photo.jpg")      # detects the format from the file's content
puts img                                      # => #<Immagini::Image 4000x3000 RGB>
puts img.width, img.height                    # 4000, 3000

img.save("copy.png")                          # format chosen from the extension
img.save("copy.jpg", quality: 85)             # JPEG with options
```

**Convert formats** just by changing the extension:

```crystal
Immagini::Image.open("logo.png").save("logo.bmp")
```

**Apply the camera's rotation when opening** (recommended for phone photos):

```crystal
img = Immagini::Image.open("phone.jpg", auto_orient: true)
```

**Save options** (all optional):

| Option | Applies to | Default |
|---|---|---|
| `quality: 1..100` | JPEG | `90` |
| `subsampling:` `Codecs::JPEG::Subsampling::S444 / S422 / S420 / Gray` | JPEG | `S420` |
| `compression: 0..9` | PNG | `6` |
| `filter:` `Codecs::PNG::Filter::None / Sub / Up / Average / Paeth / Adaptive` | PNG | `Adaptive` |
| `grayscale: true` | PNM | `false` (`.pgm` implies true) |
| `background: Color` | JPEG / BMP-24 / PNM, for transparent pixels | white |

When the extension doesn't tell the format (or you want to override it), pass it explicitly:

```crystal
img.save("output.dat", Immagini::Format::PNG)
```

**Create a new blank image:**

```crystal
blank   = Immagini::Image.new(400, 300)                              # fully transparent
red     = Immagini::Image.new(400, 300, Immagini::Color::RED)        # solid colour
```

## 10. The golden rule

> **Methods return a new image. The original is never changed.**

```crystal
small = img.resize(200, 100)   # `img` is still its original size
img.width                      # still 4000
```

That makes chaining safe and natural:

```crystal
img.crop(100, 100, 2000, 1500)
   .resize(800, 600)
   .sharpen(1.0)
   .save("result.jpg")
```

A few operations also come in an **in-place version ending in `!`** that changes the image directly and returns it, saving a copy when you don't need the original:

| Copying | In-place |
|---|---|
| `flip_horizontal`, `flip_vertical` | `flip_horizontal!`, `flip_vertical!` |
| `grayscale`, `invert`, `brightness(n)`, `contrast(f)`, `gamma(g)` | `grayscale!`, `invert!`, `brightness!(n)`, `contrast!(f)`, `gamma!(g)` |
| `composite(...)` | `composite!(...)` |
| – | `fill!(color)`, `map_pixels!`, `apply_lut!` |

```crystal
img = Immagini::Image.open("photo.jpg")
img.grayscale!.contrast!(1.2)      # modifies img itself
img.save("bw.jpg")
```

## 11. Resizing

```crystal
img.resize(800, 600)                     # exact size (may stretch)
img.fit(800, 800)                        # fit inside the box, keep proportions, never enlarges
img.fit(800, 800, upscale: true)         # ...but allow enlarging
img.fill(300, 300)                       # cover the box and centre-crop; always exactly 300x300
img.contain(500, 500, background: Immagini::Color::WHITE)   # letterbox
img.scale(0.5)                           # half size
img.thumbnail(256)                       # fit inside 256x256
```

**Choose the quality/speed trade-off with a filter:**

```crystal
img.resize(800, 600, Immagini::Filter::Bilinear)   # fast
img.resize(800, 600, Immagini::Filter::Lanczos3)   # sharpest (default)
img.resize(64, 64, Immagini::Filter::Nearest)      # blocky; keeps hard pixel edges
```

Filters: `Nearest`, `Box`, `Bilinear`, `Mitchell`, `Bicubic`, `Lanczos3`. See the filter table in section 4.

**Choose where `fill` crops** with `gravity_x` / `gravity_y` (0.0 = left/top, 0.5 = centre, 1.0 = right/bottom). Handy for portraits where the face is near the top:

```crystal
img.fill(300, 300, gravity_y: 0.2)
```

**Transparent images resize correctly**: colours don't bleed in from see-through pixels, so logos with soft edges stay clean.

**Compute sizes yourself** when you need to:

```crystal
target_w = 640
target_h = (target_w / img.aspect_ratio).round.to_i
img.resize(target_w, target_h)
```

## 12. Crop, rotate, flip

```crystal
img.crop(100, 50, 500, 300)       # x, y, width, height. Raises ArgumentError if outside the image.
img.rotate90                      # clockwise; also rotate180, rotate270
img.flip_horizontal               # mirror left <-> right
img.flip_vertical                 # mirror top <-> bottom
img.transpose                     # swap x and y
img.transverse                    # mirror across the other diagonal
```

**Rotate by any angle** (clockwise degrees):

```crystal
img.rotate(15.0)                                              # canvas grows; corners transparent
img.rotate(15.0, background: Immagini::Color.hex("#202020"))  # fill the corners
img.rotate(15.0, expand: false)                               # keep original size, corners cut off
img.rotate(-30.0, filter: Immagini::Filter::Nearest)          # fastest, no smoothing
```

**Add or remove borders:**

```crystal
img.pad(left: 20, top: 20, right: 20, bottom: 20, color: Immagini::Color::WHITE)
img.trim                           # crop away a border matching the top-left pixel
img.trim(tolerance: 10)            # ...allowing small colour differences
img.trim(color: Immagini::Color::WHITE)   # trim a specific colour
```

**EXIF orientation by hand** (values 1-8), if you read it yourself:

```crystal
bytes = File.read("phone.jpg").to_slice
n = Immagini::Codecs::JPEG.orientation(bytes)        # 1 = already upright
upright = Immagini::Image.decode(bytes).orient(n)
```

(`Image.open(path, auto_orient: true)` does exactly this for you.)

## 13. Colour adjustments

```crystal
img.grayscale
img.invert
img.sepia
img.brightness(30)            # -255..255
img.contrast(1.3)             # 1.0 = unchanged
img.gamma(1.4)                # >1 brightens midtones
img.saturation(1.5)           # 0 = grey, 1 = unchanged
img.hue_rotate(90.0)          # degrees
img.threshold(128)            # pure black / white
img.auto_contrast             # stretch used tones to full range
img.levels(20, 235)           # black point, white point (optionally gamma:)
img.opacity(0.5)              # halve the alpha channel
```

**Histogram** (counts of each brightness value, 256 bins — useful for analysis or auto-exposure):

```crystal
r, g, b, luma = img.histogram
darkest = luma.index { |count| count > 0 }
puts "darkest tone present: #{darkest}"
```

**Flatten transparency onto a solid colour:**

```crystal
opaque = logo.flatten(Immagini::Color::WHITE)
```

**Your own per-channel curve** with a lookup table (fast: one table lookup per value):

```crystal
lut = StaticArray(UInt8, 256).new { |i| (255.0 * (i / 255.0) ** 0.8).round.clamp(0, 255).to_u8 }
img.dup.apply_lut!(lut)       # apply_lut! modifies in place; dup first to keep the original
```

## 14. Blur, sharpen, filters

```crystal
img.blur(2.0)                        # gaussian, sigma in pixels
img.blur(12.0, fast: true)           # approximate but MUCH faster for large sigma
img.box_blur(3)                      # simple average blur, radius in pixels
img.sharpen(1.0)                     # unsharp mask
img.sharpen(1.2, amount: 0.7, threshold: 3)   # gentler, ignores tiny differences (noise)
img.median(1)                        # remove speckle noise
img.edges                            # outline image
```

**Pick `blur`'s mode:** the default is the exact Gaussian. Use `fast: true` when sigma is larger than about 2 and you don't need textbook accuracy (backgrounds, privacy blur); cost no longer grows with sigma.

**Your own 3x3 (or 5x5...) convolution kernel** — odd-sized, square, row-major:

```crystal
emboss = [
  -2.0, -1.0, 0.0,
  -1.0,  1.0, 1.0,
   0.0,  1.0, 2.0,
]
img.convolve(emboss, bias: 128.0)     # bias lifts the result to mid-grey

box3 = Array.new(9, 1.0)
img.convolve(box3)                    # divisor defaults to the kernel sum, so this is an average
```

Notes: `convolve` leaves alpha untouched; edge pixels are handled by repeating the border.

## 15. Compositing and watermarks

`composite` draws one image on top of another at an `(x, y)` position. Parts that fall outside the base image are clipped.

```crystal
base  = Immagini::Image.open("photo.jpg")
badge = Immagini::Image.open("logo.png")          # with transparency

result = base.composite(badge, 20, 20)            # returns a new image
base.composite!(badge, 20, 20)                    # or draw in place
```

**Bottom-right watermark with 60% opacity:**

```crystal
margin = 24
x = base.width  - badge.width  - margin
y = base.height - badge.height - margin
base.composite!(badge, x, y, opacity: 0.6)
```

**Blend modes:**

```crystal
base.composite(overlay, 0, 0, blend: Immagini::Blend::Multiply)
```

| Mode | Effect |
|---|---|
| `Normal` | Plain "paint on top" (default) |
| `Multiply` | Darkens; great for shadows and textures |
| `Screen` | Lightens; great for glows |
| `Overlay` | Increases contrast using the layer |
| `Darken` / `Lighten` | Keep the darker / lighter of each pair |
| `Add` | Adds brightness (light effects) |
| `Difference` | Absolute difference; handy for comparing two images |

**Compare two images** (shows what changed):

```crystal
diff = a.composite(b, 0, 0, blend: Immagini::Blend::Difference)
```

**Build a contact sheet** by compositing thumbnails onto one canvas:

```crystal
sheet = Immagini::Image.new(3 * 210 + 10, 210 + 10, Immagini::Color::WHITE)
paths.first(3).each_with_index do |path, i|
  thumb = Immagini::Image.open(path).fill(200, 200)
  sheet.composite!(thumb, 10 + i * 210, 10)
end
sheet.save("sheet.png")
```

## 16. Working with pixels and colours

### Colours

```crystal
include Immagini                       # optional, saves typing "Immagini::"

Color.rgb(255, 128, 0)                 # opaque orange (values are clamped to 0..255)
Color.rgba(255, 128, 0, 128)           # half transparent
Color.gray(100)                        # grey
Color.hex("#ff8000")                   # also "#f80", "#ff800080", or without the "#"
Color::RED                             # BLACK WHITE RED GREEN BLUE YELLOW CYAN MAGENTA TRANSPARENT

c = Color.hex("#336699")
c.r; c.g; c.b; c.a                     # channel values 0..255
c.luma                                 # brightness 0..255
c.with_alpha(128)                      # a copy with different alpha
c.to_hex                               # "#336699ff"
```

### Reading and writing single pixels

```crystal
img[10, 20]                  # Color at x=10, y=20 (raises IndexError if outside)
img[10, 20]?                 # same, but nil if outside
img[10, 20] = Color::RED     # set a pixel
img.in_bounds?(10, 20)       # true / false
```

### Looping

```crystal
# read every pixel
img.each_pixel do |x, y, color|
  puts "bright at #{x},#{y}" if color.luma > 250
end

# rewrite every pixel (e.g. red channel only)
img.map_pixels! { |x, y, c| Color.new(c.r, 0_u8, 0_u8, c.a) }
```

**Drawing something** (a gradient and a rectangle):

```crystal
canvas = Immagini::Image.new(256, 100)
256.times { |x| 100.times { |y| canvas[x, y] = Color.rgb(x, 0, 255 - x) } }
(20...60).each { |x| (30...70).each { |y| canvas[x, y] = Color::WHITE } }
canvas.save("gradient.png")
```

### Speed note

`img[x, y]` and `each_pixel` are convenient, but they create a `Color` per pixel. For large images or hot loops, prefer the built-in operations (they are optimised), or work on the raw bytes:

```crystal
px = img.pixels                    # Bytes: R,G,B,A, R,G,B,A, ... row after row, no padding
i = (y * img.width + x) * 4        # offset of pixel (x, y)
px[i] = 255_u8                     # set red of that pixel
```

## 17. Memory, bytes and streams

You don't need files. Everything works on memory and IO objects, which is how you'd use it in a web server, a queue worker or a test.

```crystal
# bytes -> image
bytes = File.read("photo.jpg").to_slice
img   = Immagini::Image.decode(bytes)                 # format detected automatically
img   = Immagini::Image.decode(bytes, auto_orient: true)

# image -> bytes
jpeg = img.encode(Immagini::Format::JPEG, quality: 80)     # Bytes
png  = img.encode(Immagini::Format::PNG, compression: 9)

# any IO: read from / write to a socket, pipe, File, IO::Memory ...
img = Immagini::Image.read(STDIN)
img.write(STDOUT, Immagini::Format::PNG)
```

**Find the format or the size without decoding everything:**

```crystal
Immagini::Format.detect(bytes)                    # => Format::JPEG (or nil)
Immagini::Format.from_extension(".png")           # => Format::PNG
Immagini::Format::JPEG.mime_type                  # => "image/jpeg"
Immagini::Codecs::JPEG.dimensions(bytes)          # => {4000, 3000}  (fast)
Immagini::Codecs::PNG.dimensions(png)             # => {w, h}
```

**Raw pixel data in and out** (interop with other libraries):

```crystal
rgb  = img.to_rgb                     # Bytes, 3 per pixel (alpha dropped)
gray = img.to_gray                    # Bytes, 1 per pixel
img2 = Immagini::Image.from_rgb(w, h, rgb)
img3 = Immagini::Image.from_gray(w, h, gray)
img4 = Immagini::Image.new(w, h, rgba_bytes)     # you already have RGBA bytes (no copy!)
```

## 18. Handling errors

Everything Immagini itself raises inherits from `Immagini::Error`:

| Error | Meaning |
|---|---|
| `Immagini::UnknownFormatError` | Not a recognised format (or can't infer from the file extension) |
| `Immagini::DecodeError` | Corrupt, truncated or invalid file |
| `Immagini::UnsupportedError` | A valid file using a feature that isn't implemented (e.g. progressive JPEG) |
| `ArgumentError` | A bad argument: crop outside the image, negative radius, size 0 |
| `IndexError` | `img[x, y]` outside the image |
| `File::Error` / `IO::Error` | Normal file problems (missing file, permissions) |

**Typical pattern for user-supplied files:**

```crystal
def load(path : String) : Immagini::Image?
  Immagini::Image.open(path)
rescue ex : Immagini::UnsupportedError
  STDERR.puts "#{path}: not supported yet (#{ex.message})"
rescue ex : Immagini::Error
  STDERR.puts "#{path}: not a valid image (#{ex.message})"
rescue ex : File::Error
  STDERR.puts "#{path}: #{ex.message}"
end
```

Decoders are fuzz-tested: damaged or hostile input raises one of the errors above rather than crashing. They can still allocate a lot of memory for a tiny file that *claims* huge dimensions, so run untrusted input under a memory limit and check the size first:

```crystal
w, h = Immagini::Codecs::JPEG.dimensions(bytes)
raise "too large" if w * h > 50_000_000
```

## 19. Making it fast

1. **Build with `--release`.** This is the single biggest factor.
2. **Shrink early.** Resizing a 12-megapixel photo first makes every later step cheaper:

   ```crystal
   img.fit(1600, 1600).sharpen(1.0)      # good
   img.sharpen(1.0).fit(1600, 1600)      # sharpens all 12 million pixels first: many times slower
   ```
3. **Pick the filter for the job.** `Bilinear` is about 2.5x faster than `Lanczos3`; `Nearest` is nearly free.
4. **Use `blur(sigma, fast: true)`** when sigma > 2: about 3x faster, with a barely visible difference.
5. **Use the in-place `!` versions** when you don't need the original; they skip a copy.
6. **Don't loop over pixels yourself** when a built-in operation exists. If you must, work on `img.pixels`.
7. **Enable threads** (optional). Build with `-Dpreview_mt`:

   ```sh
   crystal build --release -Dpreview_mt my_program.cr
   CRYSTAL_WORKERS=4 IMMAGINI_THREADS=4 ./my_program
   ```

   Resizing, rotating, blurring, convolution and colour operations are split across cores (about 1.9x faster on 2 cores in testing); results are byte-for-byte identical to the single-threaded build. JPEG/PNG decoding and encoding stay single-threaded. You can also set it in code: `Immagini::Parallel.threads = 2`.
8. **Process many files in parallel yourself** with fibers — each file is independent:

   ```crystal
   done = Channel(Nil).new
   files.each do |f|
     spawn do
       Immagini::Image.open(f).thumbnail(320).save("thumbs/#{File.basename(f)}")
     ensure
       done.send(nil)
     end
   end
   files.size.times { done.receive }
   ```

   (Needs `-Dpreview_mt` to use more than one core.)
9. **PNG encoding is the slow part** for big images, because compression is expensive. For speed use `compression: 1` and `filter: Immagini::Codecs::PNG::Filter::Sub`; for smaller files use higher levels, or save photos as JPEG.

## 20. Complete programs

### A. Thumbnail generator for a folder

```crystal
require "immagini"

src = ARGV[0]? || abort("usage: thumbs <input_dir> <output_dir>")
dst = ARGV[1]? || abort("usage: thumbs <input_dir> <output_dir>")
Dir.mkdir_p(dst)

made = 0
Dir.glob(File.join(src, "*.{jpg,jpeg,png,bmp}")) do |path|
  begin
    img = Immagini::Image.open(path, auto_orient: true)
    img.thumbnail(320).save(File.join(dst, File.basename(path)), quality: 80)
    made += 1
  rescue ex : Immagini::Error
    STDERR.puts "skipped #{path}: #{ex.message}"
  end
end
puts "created #{made} thumbnails"
```

### B. Watermarker

```crystal
require "immagini"

photo = Immagini::Image.open(ARGV[0], auto_orient: true).fit(1600, 1600)
mark  = Immagini::Image.open(ARGV[1])
mark  = mark.fit(photo.width // 5, photo.height // 5)       # 20% of the photo

margin = 20
photo.composite!(mark, photo.width - mark.width - margin,
                       photo.height - mark.height - margin, opacity: 0.7)
photo.save(ARGV[2], quality: 88)
```

Run: `./watermark photo.jpg logo.png out.jpg`.

### C. A small image-resizing web service

Resizes any uploaded image to a width given in the query string, e.g. `curl --data-binary @photo.jpg 'localhost:8080/?w=300' > small.jpg`.

```crystal
require "http/server"
require "immagini"

server = HTTP::Server.new do |ctx|
  begin
    width = (ctx.request.query_params["w"]? || "400").to_i.clamp(16, 2000)
    img   = Immagini::Image.read(ctx.request.body || IO::Memory.new, auto_orient: true)
    jpeg  = img.fit(width, width * 10).encode(Immagini::Format::JPEG, quality: 82)

    ctx.response.content_type = "image/jpeg"
    ctx.response.write(jpeg)
  rescue ex : Immagini::Error | ArgumentError
    ctx.response.status = HTTP::Status::UNPROCESSABLE_ENTITY
    ctx.response.print "bad image: #{ex.message}"
  end
end
server.listen(8080)
```

### D. Tiny image analyser

```crystal
require "immagini"

img = Immagini::Image.open(ARGV[0])
_, _, _, luma = img.histogram
total = img.size.to_f
mean  = luma.each_with_index.sum { |count, level| count * level } / total

puts "size:       #{img.width}x#{img.height} (#{(img.size / 1e6).round(1)} MP)"
puts "transparent: #{img.has_alpha?}"
puts "mean brightness: #{mean.round(1)} / 255"
puts "looks #{mean < 80 ? "dark" : mean > 170 ? "bright" : "balanced"}"
```

## 21. Cheat sheet

**CLI**

```text
immagini info FILE
immagini convert IN OUT  [ops, left to right]  [-filter -quality -compression -background]

size:    -resize WxH  -fit WxH  -fill WxH  -contain WxH  -scale F  -thumbnail N
region:  -crop WxH+X+Y  -trim [TOL]
turn:    -rotate DEG  -flip  -flop  -transpose  -auto-orient
colour:  -grayscale -invert -sepia -auto-contrast -brightness N -contrast F -gamma F
         -saturation F -hue DEG -threshold N
detail:  -blur S  -sharpen S  -median R  -edges
```

**Crystal**

```crystal
require "immagini"

img = Immagini::Image.open("in.jpg", auto_orient: true)

img.resize(w, h) / fit(w, h) / fill(w, h) / contain(w, h) / scale(f) / thumbnail(n)
img.crop(x, y, w, h)   img.rotate(deg)   img.rotate90   img.flip_horizontal   img.pad(...)   img.trim
img.grayscale  invert  sepia  brightness(n)  contrast(f)  gamma(g)  saturation(f)  hue_rotate(d)  auto_contrast
img.blur(s)   img.blur(s, fast: true)   img.sharpen(s)   img.median(r)   img.edges   img.convolve(kernel)
base.composite(top, x, y, blend: Immagini::Blend::Multiply, opacity: 0.5)

img.save("out.png")                 img.encode(Immagini::Format::JPEG, quality: 85)   # → Bytes
Immagini::Image.decode(bytes)       Immagini::Image.read(io)                           # ← bytes / IO
img[x, y]   img[x, y] = color   img.pixels   img.width   img.height

rescue Immagini::Error   # everything Immagini raises (plus ArgumentError / IndexError for bad arguments)
```

---

*Need the internals, benchmarks and limits? See `README.md`. For what changed per version, see `RELEASE_NOTES.md`.*
