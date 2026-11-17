require "../src/immagini"

# Usage: crystal run examples/quickstart.cr -- input.jpg outdir/
input, outdir = ARGV[0], ARGV[1]
Dir.mkdir_p(outdir)

img = Immagini::Image.open(input, auto_orient: true) # sniffs format, applies EXIF rotation
puts img                                             # => #<Immagini::Image 4000x3000 RGB>

# 1. Thumbnail that fits inside 320x320, saved as JPEG
img.thumbnail(320).save("#{outdir}/thumb.jpg", quality: 85)

# 2. Square avatar: scale-to-cover, then centre-crop
img.fill(256, 256).save("#{outdir}/avatar.png")

# 3. Chain operations; every method returns a new image
img.fit(1200, 800)
  .sharpen(0.8, amount: 0.6)
  .saturation(1.15)
  .save("#{outdir}/web.jpg", quality: 88)

# 4. Watermark: composite a translucent badge in the bottom-right corner
badge = Immagini::Image.new(160, 48, Immagini::Color.rgba(0, 0, 0, 160))
web = img.fit(1200, 800)
web.composite!(badge, web.width - badge.width - 16, web.height - badge.height - 16)
web.save("#{outdir}/watermarked.png")

# 5. Work on raw pixels without per-pixel overhead
gray = img.thumbnail(512).grayscale
hist = gray.histogram[3] # luma histogram, 256 bins
puts "darkest bin with data: #{hist.index { |n| n > 0 }}"

# 6. In-memory encode/decode (e.g. for HTTP bodies)
bytes = img.thumbnail(64).encode(Immagini::Format::PNG)
puts "png thumbnail: #{bytes.size} bytes -> #{Immagini::Image.decode(bytes)}"
