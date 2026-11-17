require "./spec_helper"

describe "PNG" do
  it "decodes RGB exactly" do
    img = Image.decode(fixture("rgb.png"))
    img.dimensions.should eq({37, 29})
    img.each_pixel { |x, y, c| c.should eq pattern(x, y) }
  end

  it "decodes RGBA exactly" do
    img = Image.decode(fixture("rgba.png"))
    img.each_pixel { |x, y, c| c.should eq pattern_a(x, y) }
  end

  it "decodes grayscale" do
    img = Image.decode(fixture("gray.png"))
    ref = Image.decode(fixture("rgb.png")).grayscale
    diff(img, ref)[1].should be <= 1
  end

  it "decodes 4-bit palette" do
    img = Image.decode(fixture("pal4.png"))
    img.dimensions.should eq({37, 29})
  end

  it "decodes Adam7 interlaced" do
    img = Image.decode(fixture("interlaced.png"))
    img.each_pixel { |x, y, c| c.should eq pattern(x, y) }
  end

  it "round-trips every filter and level losslessly" do
    src = Image.decode(fixture("rgba.png"))
    Codecs::PNG::Filter.each do |f|
      {0, 6, 9}.each do |lvl|
        Image.decode(src.encode(Format::PNG, filter: f, compression: lvl)).should eq src
      end
    end
  end

  it "picks a narrow layout and still round-trips" do
    g = Image.decode(fixture("rgb.png")).grayscale
    Image.decode(g.encode(Format::PNG)).should eq g
    o = Image.decode(fixture("rgb.png"))
    Image.decode(o.encode(Format::PNG)).should eq o
  end

  it "is readable by PIL" do
    pending!("PIL not available") unless HAVE_PIL
    src = Image.decode(fixture("rgba.png"))
    path = "#{TMP}/enc.png"
    src.save(path)
    out = `python3 -c "from PIL import Image;import numpy as np;a=np.array(Image.open('#{path}').convert('RGBA'));print(a.tobytes().hex())"`.strip
    out.should eq src.pixels.hexstring
  end

  it "rejects corrupt data" do
    d = fixture("rgb.png").dup
    d[40] = d[40] ^ 0xFF
    expect_raises(DecodeError) { Image.decode(d) }
    expect_raises(DecodeError) { Image.decode(fixture("rgb.png")[0, 60]) }
  end
end

describe "BMP" do
  it "decodes 24-bit" do
    Image.decode(fixture("rgb.bmp")).each_pixel { |x, y, c| c.should eq pattern(x, y) }
  end

  it "decodes 32-bit alpha" do
    img = Image.decode(fixture("rgba.bmp"))
    img.each_pixel { |x, y, c| c.should eq pattern_a(x, y) }
  end

  it "round-trips 24 and 32-bit, readable by PIL" do
    pending!("PIL not available") unless HAVE_PIL
    {"rgb.png", "rgba.png"}.each do |n|
      src = Image.decode(fixture(n))
      Image.decode(src.encode(Format::BMP)).should eq src
    end
    src = Image.decode(fixture("rgb.png"))
    src.save("#{TMP}/enc.bmp")
    out = `python3 -c "from PIL import Image;print(Image.open('#{TMP}/enc.bmp').convert('RGB').tobytes().hex())"`.strip
    out.should eq src.to_rgb.hexstring
  end
end

describe "PNM" do
  it "decodes P6" do
    Image.decode(fixture("rgb.ppm")).each_pixel { |x, y, c| c.should eq pattern(x, y) }
  end

  it "decodes ASCII P3 with comments and P1 bitmaps" do
    Image.decode("P3\n# c\n2 1\n255\n255 0 0  0 0 255\n".to_slice)[1, 0].should eq Color::BLUE
    img = Image.decode("P1 2 1 10".to_slice)
    img[0, 0].should eq Color::BLACK
    img[1, 0].should eq Color::WHITE
  end

  it "round-trips P6 and P5" do
    src = Image.decode(fixture("rgb.png"))
    Image.decode(src.encode(Format::PNM)).should eq src
    g = Image.decode(src.encode(Format::PNM, grayscale: true))
    diff(g, src.grayscale)[1].should be <= 1
  end
end

describe "JPEG" do
  {"q90_444", "q90_422", "q90_420", "gray", "restart"}.each do |n|
    it "decodes #{n} like libjpeg" do
      got = Image.decode(fixture("#{n}.jpg"))
      want = Image.decode(fixture("#{n}.expected.ppm"))
      mean, max = diff(got, want)
      mean.should be < 0.6
      max.should be <= 4
    end
  end

  it "rejects progressive with UnsupportedError" do
    expect_raises(UnsupportedError) { Image.decode(fixture("progressive.jpg")) }
  end

  it "rejects truncated data" do
    expect_raises(DecodeError) { Image.decode(fixture("q90_420.jpg")[0, 300]) }
  end

  it "encodes files that PIL reads, at every subsampling" do
    pending!("PIL not available") unless HAVE_PIL
    src = synth(61, 45)
    Codecs::JPEG::Subsampling.each do |s|
      path = "#{TMP}/enc_#{s}.jpg"
      src.save(path, quality: 92, subsampling: s)
      out = `python3 -c "from PIL import Image;im=Image.open('#{path}');print(im.size, im.mode)"`.strip
      out.should_not be_empty
      out.should start_with("(61, 45)")
      back = Image.open(path)
      mean, _ = diff(back, s.gray? ? src.grayscale : src)
      mean.should be < (s.s420? ? 6.0 : 4.0)
    end
  end

  it "quality changes size monotonically" do
    src = synth(128, 96)
    sizes = [20, 60, 95].map { |q| src.encode(Format::JPEG, quality: q).size }
    sizes.should eq sizes.sort
    sizes[0].should be < sizes[2]
  end

  it "reads EXIF orientation" do
    pending!("PIL not available") unless HAVE_PIL
    system(%(python3 -c "from PIL import Image;im=Image.new('RGB',(40,20),'red');e=im.getexif();e[274]=6;im.save('#{TMP}/o6.jpg',exif=e)"))
    data = File.read("#{TMP}/o6.jpg").to_slice
    Codecs::JPEG.orientation(data).should eq 6
    Image.decode(data).dimensions.should eq({40, 20})
    Image.decode(data, auto_orient: true).dimensions.should eq({20, 40})
  end
end

describe "Format" do
  it "sniffs content and extensions" do
    Format.detect(fixture("rgb.png")).should eq Format::PNG
    Format.detect(fixture("q90_420.jpg")).should eq Format::JPEG
    Format.detect(fixture("rgb.bmp")).should eq Format::BMP
    Format.detect(fixture("rgb.ppm")).should eq Format::PNM
    Format.from_extension(".JPG").should eq Format::JPEG
    expect_raises(UnknownFormatError) { Image.decode("hello world".to_slice) }
  end

  it "flattens alpha onto background for JPEG" do
    img = Image.new(8, 8, Color::TRANSPARENT)
    Image.decode(img.encode(Format::JPEG, background: Color::WHITE))[0, 0].r.should be > 250
  end
end

describe "regressions" do
  it "writes a correct IEND chunk (CRC AE426082)" do
    png = Image.new(2, 2, Color::RED).encode(Format::PNG)
    png[png.size - 12, 12].should eq Bytes[0, 0, 0, 0, 0x49, 0x45, 0x4E, 0x44, 0xAE, 0x42, 0x60, 0x82]
  end

  it "rejects absurd dimensions without arithmetic overflow" do
    expect_raises(DecodeError) { Image.decode("P6 2147483647 2147483647 255\n".to_slice) }
    expect_raises(DecodeError) { Image.decode("P5 99999 99999 255\n".to_slice) }
    bmp = fixture("rgb.bmp").dup
    bmp[14] = bmp[15] = bmp[16] = bmp[17] = 0xFF_u8 # header size 0xFFFFFFFF
    expect_raises(DecodeError) { Image.decode(bmp) }
    bmp = fixture("rgb.bmp").dup
    {18, 22}.each { |o| bmp[o] = 0; bmp[o + 1] = 0; bmp[o + 2] = 0; bmp[o + 3] = 0x80_u8 } # Int32::MIN
    expect_raises(DecodeError) { Image.decode(bmp) }
    png = fixture("rgb.png").dup
    png[16] = png[17] = png[18] = png[19] = 0xFF_u8 # width 0xFFFFFFFF
    expect_raises(DecodeError) { Image.decode(png) }
  end

  it "uses the correct half-pixel kernel window when resampling" do
    # Upscaling a 2-pixel ramp with bilinear must land exactly between the
    # two pixel centres at the output midpoint.
    img = Image.new(2, 1)
    img[0, 0] = Color.gray(0)
    img[1, 0] = Color.gray(200)
    r = img.resize(4, 1, Filter::Bilinear)
    {r[0, 0].r, r[1, 0].r, r[2, 0].r, r[3, 0].r}.should eq({0_u8, 50_u8, 150_u8, 200_u8})
  end
end
