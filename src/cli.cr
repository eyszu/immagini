require "./immagini"

# immagini: a small ImageMagick-style command line on top of the library.
#
#   immagini info photo.jpg
#   immagini convert in.jpg out.png -resize 800x600 -sharpen 1.0
#
# Operations run left to right, exactly in the order given.
module Immagini::CLI
  USAGE = <<-TXT
    immagini #{Immagini::VERSION}

    Usage:
      immagini info <file>
      immagini convert <input> <output> [operations] [options]

    Operations (applied in the order given):
      -resize WxH          exact size             -fit WxH        fit inside, keep aspect
      -fill WxH            cover + centre crop    -contain WxH    letterbox
      -scale F             scale by factor        -thumbnail N    fit inside NxN
      -crop WxH+X+Y        crop rectangle         -trim [TOL]     remove uniform border
      -rotate DEG          clockwise degrees      -flip           mirror top-bottom
      -flop                mirror left-right      -transpose      swap x and y
      -auto-orient         apply EXIF orientation
      -grayscale           -invert    -sepia      -auto-contrast
      -brightness N        (-255..255)            -contrast F     (1 = unchanged)
      -gamma F             -saturation F          -hue DEG        -threshold N
      -blur SIGMA          -sharpen SIGMA         -median R       -edges

    Options:
      -filter NAME         nearest box bilinear mitchell bicubic lanczos (default lanczos)
      -quality N           JPEG quality 1-100 (default 90)
      -compression N       PNG zlib level 0-9 (default 6)
      -background HEX      colour for transparency / padding (default #ffffff)
      -h, --help           show this help
    TXT

  class Fail < Exception
  end

  def self.dims(s : String) : {Int32, Int32}
    a = s.downcase.split('x')
    raise Fail.new("expected WxH, got #{s.inspect}") unless a.size == 2
    {a[0].to_i? || raise(Fail.new("bad width in #{s.inspect}")), a[1].to_i? || raise(Fail.new("bad height in #{s.inspect}"))}
  end

  def self.run(argv : Array(String)) : Int32
    if argv.empty? || argv.first.in?("-h", "--help", "help")
      puts USAGE
      return 0
    end

    case argv.first
    when "info"
      raise Fail.new("usage: immagini info <file>") unless argv.size == 2
      data = File.read(argv[1]).to_slice
      fmt = Format.detect(data) || raise Fail.new("unrecognised image format")
      img = Image.decode(data)
      puts "#{argv[1]}: #{fmt} #{img.width}x#{img.height} #{img.has_alpha? ? "RGBA" : "RGB"} #{data.size} bytes"
      if fmt.jpeg? && (o = Codecs::JPEG.orientation(data)) > 1
        puts "  EXIF orientation: #{o}"
      end
      0
    when "convert"
      convert(argv[1..])
      0
    else
      raise Fail.new("unknown command #{argv.first.inspect} (try --help)")
    end
  rescue ex : Fail
    STDERR.puts "immagini: #{ex.message}"
    2
  rescue ex : Immagini::Error | ArgumentError | IndexError | File::Error
    STDERR.puts "immagini: #{ex.message}"
    1
  end

  private def self.convert(args : Array(String)) : Nil
    raise Fail.new("usage: immagini convert <input> <output> [operations]") if args.size < 2
    input, output = args[0], args[1]
    rest = args[2..]

    filter = Filter::Lanczos3
    quality = 90
    compression = 6
    background = Color::WHITE
    ops = [] of Proc(Image, Image)

    i = 0
    take = ->(name : String) {
      i += 1
      rest[i]? || raise Fail.new("#{name} needs a value")
    }
    float = ->(name : String) { v = take.call(name); v.to_f? || raise Fail.new("#{name}: #{v.inspect} is not a number") }
    int = ->(name : String) { v = take.call(name); v.to_i? || raise Fail.new("#{name}: #{v.inspect} is not an integer") }

    # Filter/background may appear after the operation that uses them, so the
    # operations read the final values through these closures.
    while i < rest.size
      arg = rest[i]
      case arg
      when "-filter"
        name = take.call(arg)
        filter = Filter.parse?(name.tr("-", "_").camelcase) || (name == "lanczos" ? Filter::Lanczos3 : raise Fail.new("unknown filter #{name.inspect}"))
      when "-quality"     then quality = int.call(arg)
      when "-compression" then compression = int.call(arg)
      when "-background"  then background = Color.hex(take.call(arg))
      when "-resize"
        w, h = dims(take.call(arg))
        ops << ->(im : Image) { im.resize(w, h, filter) }
      when "-fit"
        w, h = dims(take.call(arg))
        ops << ->(im : Image) { im.fit(w, h, filter) }
      when "-fill"
        w, h = dims(take.call(arg))
        ops << ->(im : Image) { im.fill(w, h, filter) }
      when "-contain"
        w, h = dims(take.call(arg))
        ops << ->(im : Image) { im.contain(w, h, filter, background) }
      when "-scale"
        f = float.call(arg)
        ops << ->(im : Image) { im.scale(f, filter) }
      when "-thumbnail"
        n = int.call(arg)
        ops << ->(im : Image) { im.thumbnail(n, filter) }
      when "-crop"
        m = take.call(arg).match(/^(\d+)x(\d+)\+(\d+)\+(\d+)$/) || raise Fail.new("-crop expects WxH+X+Y")
        w, h, x, y = m[1].to_i, m[2].to_i, m[3].to_i, m[4].to_i
        ops << ->(im : Image) { im.crop(x, y, w, h) }
      when "-trim"
        tol = 0
        if (nxt = rest[i + 1]?) && (t = nxt.to_i?)
          tol = t
          i += 1
        end
        ops << ->(im : Image) { im.trim(tol) }
      when "-rotate"
        d = float.call(arg)
        ops << ->(im : Image) { im.rotate(d, background: background) }
      when "-flip"          then ops << ->(im : Image) { im.flip_vertical }
      when "-flop"          then ops << ->(im : Image) { im.flip_horizontal }
      when "-transpose"     then ops << ->(im : Image) { im.transpose }
      when "-grayscale"     then ops << ->(im : Image) { im.grayscale }
      when "-invert"        then ops << ->(im : Image) { im.invert }
      when "-sepia"         then ops << ->(im : Image) { im.sepia }
      when "-auto-contrast" then ops << ->(im : Image) { im.auto_contrast }
      when "-edges"         then ops << ->(im : Image) { im.edges }
      when "-brightness"
        n = int.call(arg)
        ops << ->(im : Image) { im.brightness(n) }
      when "-contrast"
        f = float.call(arg)
        ops << ->(im : Image) { im.contrast(f) }
      when "-gamma"
        f = float.call(arg)
        ops << ->(im : Image) { im.gamma(f) }
      when "-saturation"
        f = float.call(arg)
        ops << ->(im : Image) { im.saturation(f) }
      when "-hue"
        f = float.call(arg)
        ops << ->(im : Image) { im.hue_rotate(f) }
      when "-threshold"
        n = int.call(arg)
        ops << ->(im : Image) { im.threshold(n) }
      when "-blur"
        f = float.call(arg)
        ops << ->(im : Image) { im.blur(f) }
      when "-sharpen"
        f = float.call(arg)
        ops << ->(im : Image) { im.sharpen(f) }
      when "-median"
        n = int.call(arg)
        ops << ->(im : Image) { im.median(n) }
      when "-auto-orient"
        # handled at load time so it can use the EXIF data
      else
        raise Fail.new("unknown option #{arg.inspect} (try --help)")
      end
      i += 1
    end

    img = Image.open(input, auto_orient: rest.includes?("-auto-orient"))
    ops.each { |op| img = op.call(img) }
    img.save(output, quality: quality, compression: compression, background: background)
  end
end

exit Immagini::CLI.run(ARGV)
