module Immagini
  # Clamp an integer into 0..255.
  @[AlwaysInline]
  def self.clamp_u8(v : Int32) : UInt8
    v < 0 ? 0_u8 : (v > 255 ? 255_u8 : v.to_u8!)
  end

  # Exact `round(x / 255)` for x in 0..65025.
  @[AlwaysInline]
  def self.div255(x : Int32) : Int32
    t = x &+ 128
    (t &+ (t >> 8)) >> 8
  end

  # A straight (non-premultiplied) 8-bit RGBA color.
  struct Color
    getter r : UInt8
    getter g : UInt8
    getter b : UInt8
    getter a : UInt8

    def initialize(@r : UInt8, @g : UInt8, @b : UInt8, @a : UInt8 = 255_u8)
    end

    # Opaque color from any integers (clamped to 0..255).
    def self.rgb(r : Int, g : Int, b : Int) : Color
      rgba(r, g, b, 255)
    end

    def self.rgba(r : Int, g : Int, b : Int, a : Int) : Color
      new(Immagini.clamp_u8(r.to_i32), Immagini.clamp_u8(g.to_i32),
        Immagini.clamp_u8(b.to_i32), Immagini.clamp_u8(a.to_i32))
    end

    def self.gray(v : Int, a : Int = 255) : Color
      rgba(v, v, v, a)
    end

    # Parses `#rgb`, `#rgba`, `#rrggbb` or `#rrggbbaa` (the `#` is optional).
    def self.hex(str : String) : Color
      s = str.lstrip('#')
      v = s.to_u32?(16) || raise ArgumentError.new("invalid hex color #{str.inspect}")
      case s.size
      when 3
        new(((v >> 8) & 0xF).to_u8 * 17, ((v >> 4) & 0xF).to_u8 * 17, (v & 0xF).to_u8 * 17)
      when 4
        new(((v >> 12) & 0xF).to_u8 * 17, ((v >> 8) & 0xF).to_u8 * 17,
          ((v >> 4) & 0xF).to_u8 * 17, (v & 0xF).to_u8 * 17)
      when 6
        new(((v >> 16) & 0xFF).to_u8, ((v >> 8) & 0xFF).to_u8, (v & 0xFF).to_u8)
      when 8
        new(((v >> 24) & 0xFF).to_u8, ((v >> 16) & 0xFF).to_u8, ((v >> 8) & 0xFF).to_u8, (v & 0xFF).to_u8)
      else
        raise ArgumentError.new("invalid hex color #{str.inspect}")
      end
    end

    # Rec. 601 luma, 0..255.
    def luma : UInt8
      ((@r.to_i32 &* 77 &+ @g.to_i32 &* 150 &+ @b.to_i32 &* 29 &+ 128) >> 8).to_u8!
    end

    def opaque? : Bool
      @a == 255_u8
    end

    def with_alpha(a : Int) : Color
      Color.new(@r, @g, @b, Immagini.clamp_u8(a.to_i32))
    end

    def to_hex : String
      String.build do |io|
        io << '#'
        {@r, @g, @b, @a}.each { |c| io << c.to_s(16, precision: 2) }
      end
    end

    def to_s(io : IO) : Nil
      io << to_hex
    end

    def inspect(io : IO) : Nil
      io << "Color(" << to_hex << ')'
    end

    TRANSPARENT = new(0_u8, 0_u8, 0_u8, 0_u8)
    BLACK       = new(0_u8, 0_u8, 0_u8)
    WHITE       = new(255_u8, 255_u8, 255_u8)
    RED         = new(255_u8, 0_u8, 0_u8)
    GREEN       = new(0_u8, 255_u8, 0_u8)
    BLUE        = new(0_u8, 0_u8, 255_u8)
    YELLOW      = new(255_u8, 255_u8, 0_u8)
    CYAN        = new(0_u8, 255_u8, 255_u8)
    MAGENTA     = new(255_u8, 0_u8, 255_u8)
  end
end
