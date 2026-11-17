require "./spec_helper"

def pil_resize(src_path : String, w : Int32, h : Int32, filt : String) : Image
  dst = "#{TMP}/pil_#{filt}_#{w}x#{h}.ppm"
  system(%(python3 -c "from PIL import Image;Image.open('#{src_path}').convert('RGB').resize((#{w},#{h}),Image.#{filt}).save('#{dst}')"))
  Image.open(dst)
end

describe "geometry" do
  img = Image.new(5, 3)
  img.map_pixels! { |x, y, _| Color.rgb(x * 10, y * 10, 0) }

  it "crops and validates" do
    c = img.crop(1, 1, 3, 2)
    c.dimensions.should eq({3, 2})
    c[0, 0].should eq img[1, 1]
    expect_raises(ArgumentError) { img.crop(3, 0, 5, 1) }
  end

  it "flips (copy and in-place agree)" do
    img.flip_horizontal[0, 0].should eq img[4, 0]
    img.flip_vertical[0, 0].should eq img[0, 2]
    img.dup.flip_horizontal!.should eq img.flip_horizontal
    img.dup.flip_vertical!.should eq img.flip_vertical
  end

  it "rotates 90/180/270 and 4x90 is identity" do
    r = img.rotate90
    r.dimensions.should eq({3, 5})
    r[2, 0].should eq img[0, 0] # top-left goes to top-right
    img.rotate180[4, 2].should eq img[0, 0]
    img.rotate270[0, 4].should eq img[0, 0]
    img.rotate90.rotate90.rotate90.rotate90.should eq img
    img.rotate270.should eq img.rotate90.rotate180
  end

  it "transpose/transverse and all 8 EXIF orientations keep pixel counts" do
    img.transpose[1, 2].should eq img[2, 1]
    img.transpose.transpose.should eq img
    (1..8).each { |o| img.orient(o).size.should eq img.size }
  end

  it "rotates by arbitrary angle" do
    big = Image.new(40, 20, Color::RED)
    r = big.rotate(45.0)
    r.width.should be > 40
    r[r.width // 2, r.height // 2].should eq Color::RED
    r[0, 0].a.should eq 0
    big.rotate(30.0, expand: false).dimensions.should eq({40, 20})
    big.rotate(90.0).should eq big.rotate90
    big.rotate(-90.0).should eq big.rotate270
  end

  it "pads and trims" do
    p = img.pad(2, 3, 4, 5, Color::WHITE)
    p.dimensions.should eq({11, 11})
    p[0, 0].should eq Color::WHITE
    p[2, 3].should eq img[0, 0]
    solid = Image.new(10, 10, Color::WHITE)
    solid[3, 4] = Color::BLACK
    solid[6, 7] = Color::BLACK
    t = solid.trim
    t.dimensions.should eq({4, 4})
    t[0, 0].should eq Color::BLACK
  end
end

describe "resize" do
  it "matches PIL for every filter (down and up)" do
    pending!("PIL not available") unless HAVE_PIL
    src = "spec/fixtures/rgb.png"
    ref = Image.open(src)
    {
      {Filter::Bilinear, "BILINEAR"}, {Filter::Bicubic, "BICUBIC"},
      {Filter::Lanczos3, "LANCZOS"}, {Filter::Box, "BOX"},
    }.each do |f, name|
      {ref.resize(15, 11, f) => pil_resize(src, 15, 11, name),
       ref.resize(80, 70, f) => pil_resize(src, 80, 70, name)}.each do |ours, pil|
        mean, max = diff(ours, pil)
        # Bilinear/bicubic/lanczos agree with PIL to rounding. Box differs a
        # little at fractional scales (likely edge-weight tie-breaking).
        if f.box?
          mean.should be < 1.0
        else
          mean.should be < 0.1
          max.should be <= 3
        end
      end
    end
  end

  it "preserves flat colour exactly and keeps alpha straight" do
    flat = Image.new(50, 40, Color.rgba(200, 100, 50, 255))
    Filter.each { |f| flat.resize(17, 23, f).each_pixel { |_, _, c| c.should eq flat[0, 0] } }
    a = Image.new(20, 20, Color.rgba(255, 0, 0, 128))
    r = a.resize(7, 7)
    r[3, 3].should eq Color.rgba(255, 0, 0, 128)
  end

  it "does not bleed colour from transparent pixels" do
    img = Image.new(8, 8, Color::TRANSPARENT)
    4.times { |y| 4.times { |x| img[x, y] = Color::RED } }
    r = img.resize(4, 4, Filter::Bilinear)
    r.each_pixel { |_, _, c| (c.r.should eq 255) if c.a > 0 }
  end

  it "nearest is exact for integer upscale" do
    img = Image.new(2, 2)
    img[0, 0] = Color::RED; img[1, 0] = Color::GREEN; img[0, 1] = Color::BLUE; img[1, 1] = Color::WHITE
    big = img.resize(6, 6, Filter::Nearest)
    big[2, 2].should eq Color::RED
    big[3, 0].should eq Color::GREEN
    big[5, 5].should eq Color::WHITE
  end

  it "fit / fill / contain / scale / thumbnail" do
    img = Image.new(200, 100, Color::BLUE)
    img.fit(50, 50).dimensions.should eq({50, 25})
    img.fit(500, 500).dimensions.should eq({200, 100})
    img.fit(500, 500, upscale: true).dimensions.should eq({500, 250})
    img.fill(40, 40).dimensions.should eq({40, 40})
    c = img.contain(60, 60, background: Color::RED)
    c.dimensions.should eq({60, 60})
    c[30, 0].should eq Color::RED
    c[30, 30].should eq Color::BLUE
    img.scale(0.5).dimensions.should eq({100, 50})
    img.thumbnail(20).dimensions.should eq({20, 10})
    expect_raises(ArgumentError) { img.resize(0, 5) }
  end
end

describe "colour" do
  px = Image.new(1, 1, Color.rgb(100, 150, 200))

  it "grayscale / invert / brightness / contrast / gamma" do
    px.grayscale[0, 0].should eq Color.gray(px[0, 0].luma)
    px.invert[0, 0].should eq Color.rgb(155, 105, 55)
    px.invert.invert.should eq px
    px.brightness(100)[0, 0].should eq Color.rgb(200, 250, 255)
    px.brightness(-200)[0, 0].should eq Color.rgb(0, 0, 0)
    px.contrast(1.0).should eq px
    px.contrast(0.0)[0, 0].r.to_i.should be_close(128, 1)
    px.gamma(1.0).should eq px
    px.gamma(2.0)[0, 0].r.should be > 100
    expect_raises(ArgumentError) { px.gamma(0.0) }
  end

  it "saturation / hue / sepia / threshold / levels / opacity" do
    px.saturation(0.0)[0, 0].r.should eq px.saturation(0.0)[0, 0].b
    px.saturation(1.0).should eq px
    px.hue_rotate(0.0)[0, 0].r.to_i.should be_close(100, 1)
    px.hue_rotate(360.0)[0, 0].g.to_i.should be_close(150, 2)
    s = px.sepia[0, 0]
    (s.r >= s.g && s.g >= s.b).should be_true
    px.threshold(50)[0, 0].should eq Color::WHITE
    px.threshold(250)[0, 0].should eq Color::BLACK
    px.levels(100, 200)[0, 0].r.should eq 0
    px.levels(100, 200)[0, 0].b.should eq 255
    px.opacity(0.5)[0, 0].a.to_i.should be_close(128, 1)
  end

  it "flatten, histogram, auto_contrast" do
    t = Image.new(2, 2, Color.rgba(255, 0, 0, 0))
    t.flatten(Color::BLUE)[0, 0].should eq Color::BLUE
    h = px.histogram
    h[0][100].should eq 1
    h[1][150].should eq 1
    dull = Image.new(4, 1)
    dull[0, 0] = Color.gray(100); dull[1, 0] = Color.gray(120)
    dull[2, 0] = Color.gray(140); dull[3, 0] = Color.gray(160)
    ac = dull.auto_contrast
    ac[0, 0].r.should eq 0
    ac[3, 0].r.should eq 255
  end
end

describe "composite" do
  it "source-over with partial alpha" do
    bg = Image.new(2, 2, Color::BLUE)
    fg = Image.new(2, 2, Color.rgba(255, 0, 0, 128))
    r = bg.composite(fg)[0, 0]
    r.a.should eq 255
    r.r.should be_close(128, 1)
    r.b.should be_close(127, 1)
  end

  it "opaque source replaces, transparent leaves, clips at edges" do
    bg = Image.new(4, 4, Color::BLUE)
    bg.composite(Image.new(2, 2, Color::RED), 3, 3)[3, 3].should eq Color::RED
    bg.composite(Image.new(2, 2, Color::RED), 3, 3)[2, 2].should eq Color::BLUE
    bg.composite(Image.new(2, 2, Color::RED), -5, -5).should eq bg
    bg.composite(Image.new(2, 2, Color::TRANSPARENT)).should eq bg
  end

  it "blend modes" do
    bg = Image.new(1, 1, Color.gray(100))
    src = Image.new(1, 1, Color.gray(200))
    bg.composite(src, blend: Blend::Multiply)[0, 0].r.to_i.should be_close(78, 1)
    bg.composite(src, blend: Blend::Screen)[0, 0].r.to_i.should be_close(222, 1)
    bg.composite(src, blend: Blend::Darken)[0, 0].r.should eq 100
    bg.composite(src, blend: Blend::Lighten)[0, 0].r.should eq 200
    bg.composite(src, blend: Blend::Difference)[0, 0].r.should eq 100
    bg.composite(src, blend: Blend::Add)[0, 0].r.should eq 255
    bg.composite(src, opacity: 0.0).should eq bg
  end

  it "compositing onto transparent preserves the source" do
    c = Color.rgba(10, 20, 30, 77)
    r = Image.new(1, 1).composite(Image.new(1, 1, c))
    r[0, 0].a.should eq 77
    r[0, 0].r.to_i.should be_close(10, 1)
  end
end

describe "filters" do
  it "blur keeps flat images flat and preserves mean brightness" do
    flat = Image.new(30, 30, Color.rgb(90, 120, 200))
    flat.blur(2.5).should eq flat
    flat.box_blur(3).should eq flat
    src = synth(64, 48)
    m = ->(i : Image) { t = 0_i64; i.pixels.each_with_index { |b, k| t += b if k % 4 != 3 }; t / (i.size * 3).to_f }
    (m.call(src.blur(3.0)) - m.call(src)).abs.should be < 1.0
    src.blur(0).should eq src
  end

  it "blur matches ImageMagick gaussian within tolerance" do
    pending!("IM not available") unless HAVE_IM
    src = synth(64, 48)
    src.save("#{TMP}/blur_in.png")
    system("convert #{TMP}/blur_in.png -gaussian-blur 0x2 #{TMP}/blur_im.ppm")
    mean, _ = diff(src.blur(2.0), Image.open("#{TMP}/blur_im.ppm"))
    mean.should be < 1.0
  end

  it "blur reduces high frequency; sharpen increases it" do
    src = synth(64, 48)
    var = ->(i : Image) { g = i.to_gray.map(&.to_i); mu = g.sum / g.size.to_f; g.sum { |v| (v - mu) ** 2 } / g.size }
    var.call(src.blur(3.0)).should be < var.call(src)
    var.call(src.sharpen(1.5, 1.5)).should be > var.call(src)
  end

  it "alpha-aware blur does not darken translucent edges" do
    img = Image.new(10, 10, Color::TRANSPARENT)
    5.times { |y| 10.times { |x| img[x, y] = Color::RED } }
    img.blur(2.0).each_pixel { |_, _, c| (c.r.should be >= 250) if c.a > 20 }
  end

  it "convolve identity and validation" do
    src = synth(20, 20)
    src.convolve([0.0, 0.0, 0.0, 0.0, 1.0, 0.0, 0.0, 0.0, 0.0]).should eq src
    expect_raises(ArgumentError) { src.convolve([1.0, 1.0]) }
  end

  it "edges find a step; median removes salt noise" do
    step = Image.new(20, 10, Color::BLACK)
    10.times { |y| 10.times { |x| step[x + 10, y] = Color::WHITE } }
    e = step.edges
    e[10, 5].r.should be > 200
    e[3, 5].r.should eq 0
    noisy = Image.new(9, 9, Color.gray(100))
    noisy[4, 4] = Color::WHITE
    noisy.median(1)[4, 4].r.should eq 100
  end
end

describe "api" do
  it "bounds checks and conversions" do
    img = Image.new(3, 2, Color::RED)
    expect_raises(IndexError) { img[3, 0] }
    img[3, 0]?.should be_nil
    Image.from_rgb(1, 1, Bytes[1, 2, 3])[0, 0].should eq Color.rgb(1, 2, 3)
    Image.from_gray(1, 1, Bytes[9])[0, 0].should eq Color.gray(9)
    expect_raises(ArgumentError) { Image.new(0, 5) }
    expect_raises(ArgumentError) { Image.new(100_000, 100_000) }
    img.fill!(Color::GREEN)[2, 1].should eq Color::GREEN
    Color.hex("#f80").should eq Color.rgb(255, 136, 0)
    Color.hex("#ff8000").should eq Color.rgb(255, 128, 0)
    Color.hex("ff800080").a.should eq 128
    Color::RED.to_hex.should eq "#ff0000ff"
  end

  it "saves and opens files by extension" do
    img = synth(33, 21)
    {"png", "bmp", "ppm", "jpg", "jpeg"}.each do |ext|
      path = "#{TMP}/api.#{ext}"
      img.save(path)
      Image.open(path).dimensions.should eq({33, 21})
    end
    expect_raises(UnknownFormatError) { img.save("#{TMP}/x.unknown") }
  end
end

describe "fast gaussian" do
  it "approximates the exact blur, keeps flat flat, handles alpha" do
    src = synth(120, 90)
    {1.5, 3.0, 6.0}.each do |sg|
      mean, max = diff(src.blur(sg, fast: true), src.blur(sg))
      mean.should be < 1.5
      max.should be <= 8
    end
    flat = Image.new(40, 40, Color.rgb(90, 120, 200))
    flat.blur(4.0, fast: true).should eq flat
    src.blur(0.0, fast: true).should eq src
    img = Image.new(20, 20, Color::TRANSPARENT)
    10.times { |y| 20.times { |x| img[x, y] = Color::RED } }
    img.blur(3.0, fast: true).each_pixel { |_, _, c| (c.r.should be >= 250) if c.a > 20 }
  end
end

# Every parallelised operation must give byte-identical results regardless of
# the thread count. (Only meaningful when built with -Dpreview_mt; otherwise it
# still runs, trivially serial.) Guards against shared-closure bugs in bands.
describe "parallel determinism" do
  it "gives identical results with 1 and many threads" do
    src = synth(173, 131)
    src[5, 5] = Color.rgba(10, 20, 30, 40) # make it non-opaque
    ops = {
      "resize down"    => ->(i : Image) { i.resize(61, 47, Filter::Lanczos3) },
      "resize up"      => ->(i : Image) { i.resize(311, 257, Filter::Bicubic) },
      "resize nearest" => ->(i : Image) { i.resize(77, 53, Filter::Nearest) },
      "rotate 23"      => ->(i : Image) { i.rotate(23.0, background: Color::BLUE) },
      "rotate90"       => ->(i : Image) { i.rotate90 },
      "flip h"         => ->(i : Image) { i.flip_horizontal },
      "blur"           => ->(i : Image) { i.blur(2.0) },
      "blur fast"      => ->(i : Image) { i.blur(3.0, fast: true) },
      "sharpen"        => ->(i : Image) { i.sharpen(1.0) },
      "convolve"       => ->(i : Image) { i.convolve([1.0, 2.0, 1.0, 2.0, 4.0, 2.0, 1.0, 2.0, 1.0]) },
      "median"         => ->(i : Image) { i.median(1) },
      "edges"          => ->(i : Image) { i.edges },
      "grayscale"      => ->(i : Image) { i.grayscale },
      "saturation"     => ->(i : Image) { i.saturation(1.7) },
      "sepia"          => ->(i : Image) { i.sepia },
      "brightness"     => ->(i : Image) { i.brightness(30) },
    }
    original = Parallel.threads
    begin
      ops.each do |name, op|
        Parallel.threads = 1
        serial = op.call(src)
        Parallel.threads = 4
        threaded = op.call(src)
        (serial == threaded).should be_true, "#{name} differs between 1 and 4 threads"
      end
    ensure
      Parallel.threads = original
    end
  end
end
