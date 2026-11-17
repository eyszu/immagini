require "../src/immagini"
include Immagini

# Usage: bench <photo.jpg> <photo.png> [runs]
# Reports the best of N runs per operation, in milliseconds (decode/encode of
# in-memory bytes, so disk speed does not matter).
jpg = File.read(ARGV[0]).to_slice
png = File.read(ARGV[1]).to_slice
runs = (ARGV[2]? || "5").to_i

def best(runs : Int32, & : ->) : Float64
  yield # warm up
  t = Float64::MAX
  runs.times do
    s = Time.monotonic
    yield
    t = Math.min(t, (Time.monotonic - s).total_milliseconds)
  end
  t
end

def row(name : String, ms : Float64)
  puts "#{name.ljust(34)} #{ms.round(1).to_s.rjust(9)} ms"
end

img = Image.decode(jpg)
puts "image #{img.width}x#{img.height} (#{(img.size / 1e6).round(1)} MP), threads=#{Parallel.threads}"

row "jpeg decode", best(runs) { Image.decode(jpg) }
row "png decode", best(runs) { Image.decode(png) }
row "jpeg encode q90 4:2:0", best(runs) { img.encode(Format::JPEG, quality: 90) }
row "png encode level 6 (adaptive)", best(runs) { img.encode(Format::PNG) }
row "png encode level 1 (sub)", best(runs) { img.encode(Format::PNG, compression: 1, filter: Codecs::PNG::Filter::Sub) }
row "resize 800x600 lanczos3", best(runs) { img.resize(800, 600, Filter::Lanczos3) }
row "resize 800x600 bilinear", best(runs) { img.resize(800, 600, Filter::Bilinear) }
row "resize 800x600 nearest", best(runs) { img.resize(800, 600, Filter::Nearest) }
row "resize 6000x4500 bicubic (up)", best(runs) { img.resize(6000, 4500, Filter::Bicubic) }
row "rotate90", best(runs) { img.rotate90 }
row "flip horizontal", best(runs) { img.flip_horizontal }
row "rotate 17 deg bilinear", best(runs) { img.rotate(17.0) }
row "crop 2000x1500", best(runs) { img.crop(500, 400, 2000, 1500) }
row "grayscale", best(runs) { img.grayscale }
row "brightness (LUT)", best(runs) { img.brightness(20) }
row "gaussian blur sigma 3", best(runs) { img.blur(3.0) }
row "gaussian blur sigma 3 (fast: true)", best(runs) { img.blur(3.0, fast: true) }
row "sharpen (unsharp, sigma 1)", best(runs) { img.sharpen(1.0) }
row "convolve 3x3", best(runs) { img.convolve([0.0, -1.0, 0.0, -1.0, 5.0, -1.0, 0.0, -1.0, 0.0]) }
row "composite 2000x1500 over", best(runs) { img.composite(img.crop(0, 0, 2000, 1500), 100, 100, opacity: 0.5) }
