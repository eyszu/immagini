module Immagini
  # An in-memory raster image.
  #
  # Pixels are stored as one flat, row-major, interleaved RGBA8 buffer
  # (`width * height * 4` bytes, straight alpha). Every codec decodes into this
  # layout and every operation works on it, so there are no per-format code
  # paths or pixel-type generics to pay for at runtime.
  #
  # Operations come in two flavours: the plain name returns a new image and
  # leaves the receiver untouched; the `!` variant (where it makes sense)
  # mutates in place.
  class Image
    getter width : Int32
    getter height : Int32

    # The raw RGBA8 buffer. Writing to it is allowed; keep its size unchanged.
    getter pixels : Bytes

    # True when a `width` x `height` RGBA8 buffer fits in a `Bytes`
    # (`Int32::MAX` bytes). Safe against overflow for any integer inputs.
    def self.valid_dimensions?(width : Int, height : Int) : Bool
      width > 0 && height > 0 && width <= Int32::MAX && height <= Int32::MAX &&
        width.to_i64 * height.to_i64 <= (Int32::MAX // 4).to_i64
    end

    def self.check_dimensions(width : Int, height : Int) : Nil
      unless valid_dimensions?(width, height)
        raise ArgumentError.new("invalid image dimensions #{width}x#{height}")
      end
    end

    # A new image filled with `fill` (fully transparent by default).
    def initialize(@width : Int32, @height : Int32, fill : Color = Color::TRANSPARENT)
      Image.check_dimensions(@width, @height)
      @pixels = Bytes.new(@width * @height * 4)
      fill!(fill) unless fill == Color::TRANSPARENT
    end

    # Wraps an existing RGBA8 buffer (no copy).
    def initialize(@width : Int32, @height : Int32, @pixels : Bytes)
      Image.check_dimensions(@width, @height)
      unless @pixels.size == @width * @height * 4
        raise ArgumentError.new("buffer has #{@pixels.size} bytes, expected #{@width * @height * 4}")
      end
    end

    # Builds an image from packed RGB bytes (3 bytes per pixel, opaque).
    def self.from_rgb(width : Int32, height : Int32, rgb : Bytes) : Image
      check_dimensions(width, height)
      n = width * height
      raise ArgumentError.new("expected #{n * 3} bytes, got #{rgb.size}") unless rgb.size == n * 3
      result = Bytes.new(n * 4)
      s = rgb.to_unsafe
      d = result.to_unsafe
      n.times do
        d[0] = s[0]
        d[1] = s[1]
        d[2] = s[2]
        d[3] = 255_u8
        s += 3
        d += 4
      end
      new(width, height, result)
    end

    # Builds an image from 8-bit grayscale bytes (1 byte per pixel, opaque).
    def self.from_gray(width : Int32, height : Int32, gray : Bytes) : Image
      check_dimensions(width, height)
      n = width * height
      raise ArgumentError.new("expected #{n} bytes, got #{gray.size}") unless gray.size == n
      result = Bytes.new(n * 4)
      s = gray.to_unsafe
      d = result.to_unsafe
      n.times do
        v = s.value
        d[0] = v
        d[1] = v
        d[2] = v
        d[3] = 255_u8
        s += 1
        d += 4
      end
      new(width, height, result)
    end

    # Number of pixels.
    def size : Int32
      @width * @height
    end

    def dimensions : {Int32, Int32}
      {@width, @height}
    end

    def aspect_ratio : Float64
      @width / @height
    end

    # Returns the pixel at `(x, y)`; raises `IndexError` if outside the image.
    def [](x : Int, y : Int) : Color
      check_bounds!(x, y)
      unsafe_get(x.to_i32, y.to_i32)
    end

    # Like `[]` but returns nil when outside the image.
    def []?(x : Int, y : Int) : Color?
      return nil unless in_bounds?(x, y)
      unsafe_get(x.to_i32, y.to_i32)
    end

    def []=(x : Int, y : Int, color : Color) : Color
      check_bounds!(x, y)
      unsafe_set(x.to_i32, y.to_i32, color)
      color
    end

    @[AlwaysInline]
    def unsafe_get(x : Int32, y : Int32) : Color
      p = @pixels.to_unsafe + (y &* @width &+ x) &* 4
      Color.new(p[0], p[1], p[2], p[3])
    end

    @[AlwaysInline]
    def unsafe_set(x : Int32, y : Int32, c : Color) : Nil
      p = @pixels.to_unsafe + (y &* @width &+ x) &* 4
      p[0] = c.r
      p[1] = c.g
      p[2] = c.b
      p[3] = c.a
    end

    def in_bounds?(x : Int, y : Int) : Bool
      x >= 0 && y >= 0 && x < @width && y < @height
    end

    # Pointer to the first byte of row `y` (no bounds check).
    @[AlwaysInline]
    def row_ptr(y : Int32) : Pointer(UInt8)
      @pixels.to_unsafe + y &* @width &* 4
    end

    # Yields `(x, y, color)` for every pixel, row by row. Convenient, not fast:
    # use the bulk operations or `pixels` for hot paths.
    def each_pixel(& : Int32, Int32, Color ->) : Nil
      @height.times do |y|
        @width.times do |x|
          yield x, y, unsafe_get(x, y)
        end
      end
    end

    # Replaces every pixel with the block's result.
    def map_pixels!(& : Int32, Int32, Color -> Color) : self
      @height.times do |y|
        @width.times do |x|
          unsafe_set(x, y, yield(x, y, unsafe_get(x, y)))
        end
      end
      self
    end

    # Sets every pixel to `color`.
    def fill!(color : Color) : self
      total = @pixels.size
      p = @pixels.to_unsafe
      p[0] = color.r
      p[1] = color.g
      p[2] = color.b
      p[3] = color.a
      done = 4
      while done < total
        n = Math.min(done, total - done)
        (p + done).copy_from(p, n)
        done += n
      end
      self
    end

    # An independent copy.
    def dup : Image
      copy = Bytes.new(@pixels.size)
      copy.copy_from(@pixels)
      Image.new(@width, @height, copy)
    end

    def clone : Image
      dup
    end

    # True when every pixel has alpha 255.
    def opaque? : Bool
      Pixels.opaque?(@pixels.to_unsafe, size)
    end

    def has_alpha? : Bool
      !opaque?
    end

    def ==(other : Image) : Bool
      @width == other.width && @height == other.height && @pixels == other.pixels
    end

    # Packed RGB bytes (alpha dropped, not composited; see `flatten`).
    def to_rgb : Bytes
      n = size
      result = Bytes.new(n * 3)
      s = @pixels.to_unsafe
      d = result.to_unsafe
      n.times do
        d[0] = s[0]
        d[1] = s[1]
        d[2] = s[2]
        s += 4
        d += 3
      end
      result
    end

    # 8-bit luma bytes (Rec. 601).
    def to_gray : Bytes
      n = size
      result = Bytes.new(n)
      s = @pixels.to_unsafe
      d = result.to_unsafe
      n.times do
        d.value = ((s[0].to_i32 &* 77 &+ s[1].to_i32 &* 150 &+ s[2].to_i32 &* 29 &+ 128) >> 8).to_u8!
        s += 4
        d += 1
      end
      result
    end

    def inspect(io : IO) : Nil
      io << "#<Immagini::Image " << @width << 'x' << @height << ' ' << (opaque? ? "RGB" : "RGBA") << '>'
    end

    def to_s(io : IO) : Nil
      inspect(io)
    end

    private def check_bounds!(x : Int, y : Int) : Nil
      unless in_bounds?(x, y)
        raise IndexError.new("pixel (#{x}, #{y}) is outside the #{@width}x#{@height} image")
      end
    end
  end
end
