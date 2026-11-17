require "spec"
require "file_utils"
require "../src/immagini"

include Immagini

FIX = File.join(__DIR__, "fixtures")
TMP = File.join(Dir.tempdir, "immagini_spec_#{Process.pid}")
Dir.mkdir_p(TMP)
Spec.after_suite { FileUtils.rm_rf(TMP) }

# Some specs cross-check against independent implementations. They are skipped
# (marked pending) when the tool is missing; set IMMAGINI_SPEC_NO_TOOLS=1 to
# force that.
NO_TOOLS = !ENV["IMMAGINI_SPEC_NO_TOOLS"]?.nil?
HAVE_PIL = !NO_TOOLS && system("python3 -c 'import PIL.Image' >/dev/null 2>&1")
HAVE_IM  = !NO_TOOLS && system("convert -version >/dev/null 2>&1")

def fixture(name : String) : Bytes
  File.read(File.join(FIX, name)).to_slice
end

# Fixture pattern used for rgb.* / rgba.* (37x29)
def pattern(x : Int32, y : Int32) : Color
  Color.new(((x * 7) % 256).to_u8, ((y * 9) % 256).to_u8, (((x + y) * 5) % 256).to_u8)
end

def pattern_a(x : Int32, y : Int32) : Color
  c = pattern(x, y)
  Color.new(c.r, c.g, c.b, ((x * 13 + y * 3) % 256).to_u8)
end

# Mean and max absolute RGB difference between two same-size images.
def diff(a : Image, b : Image) : {Float64, Int32}
  a.dimensions.should eq b.dimensions
  sum = 0_i64
  mx = 0
  pa, pb = a.pixels, b.pixels
  (0...pa.size).each do |i|
    next if i % 4 == 3
    d = (pa[i].to_i32 - pb[i].to_i32).abs
    sum += d
    mx = d if d > mx
  end
  {sum / (pa.size * 3 / 4).to_f64, mx}
end

# Smooth synthetic photo-like image (gradients + a circle) for lossy tests.
def synth(w : Int32, h : Int32) : Image
  img = Image.new(w, h)
  h.times do |y|
    w.times do |x|
      r = (128 + 100 * Math.sin(x / 9.0)).to_i
      g = (128 + 100 * Math.cos(y / 7.0)).to_i
      b = ((x + y) * 255 // (w + h)).to_i
      img[x, y] = Color.rgb(r, g, b)
    end
  end
  img
end
