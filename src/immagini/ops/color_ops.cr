module Immagini
  class Image
    # Applies a 256-entry lookup table to the R, G and B channels (alpha untouched).
    def apply_lut!(lut : StaticArray(UInt8, 256)) : self
      apply_lut!(lut, lut, lut)
    end

    def apply_lut!(rl : StaticArray(UInt8, 256), gl : StaticArray(UInt8, 256), bl : StaticArray(UInt8, 256)) : self
      p = @pixels.to_unsafe
      Parallel.bands(@height, 128) do |y0, y1|
        q = p + y0 * @width * 4
        ((y1 - y0) * @width).times do
          q[0] = rl.unsafe_fetch(q[0])
          q[1] = gl.unsafe_fetch(q[1])
          q[2] = bl.unsafe_fetch(q[2])
          q += 4
        end
      end
      self
    end

    protected def self.build_lut(& : Int32 -> Int32) : StaticArray(UInt8, 256)
      lut = StaticArray(UInt8, 256).new(0_u8)
      256.times { |i| lut[i] = Immagini.clamp_u8(yield i) }
      lut
    end

    # Converts to grayscale (Rec. 601 luma). Alpha is kept.
    def grayscale : Image
      result = dup
      result.grayscale!
      result
    end

    def grayscale! : self
      p = @pixels.to_unsafe
      Parallel.bands(@height, 128) do |y0, y1|
        q = p + y0 * @width * 4
        ((y1 - y0) * @width).times do
          v = ((q[0].to_i32 &* 77 &+ q[1].to_i32 &* 150 &+ q[2].to_i32 &* 29 &+ 128) >> 8).to_u8!
          q[0] = v
          q[1] = v
          q[2] = v
          q += 4
        end
      end
      self
    end

    # Adds `amount` (-255..255) to every colour channel.
    def brightness(amount : Int) : Image
      result = dup
      result.brightness!(amount)
      result
    end

    def brightness!(amount : Int) : self
      a = amount.to_i32
      apply_lut!(Image.build_lut { |i| i + a })
    end

    # Scales contrast around mid-grey. 1.0 = unchanged, 0 = flat grey, 2 = double.
    def contrast(factor : Float64) : Image
      result = dup
      result.contrast!(factor)
      result
    end

    def contrast!(factor : Float64) : self
      apply_lut!(Image.build_lut { |i| ((i - 127.5) * factor + 127.5).round.to_i32 })
    end

    # Gamma correction: output = input^(1/gamma). gamma > 1 brightens midtones.
    def gamma(g : Float64) : Image
      result = dup
      result.gamma!(g)
      result
    end

    def gamma!(g : Float64) : self
      raise ArgumentError.new("gamma must be positive") unless g > 0
      inv = 1.0 / g
      apply_lut!(Image.build_lut { |i| ((i / 255.0) ** inv * 255.0).round.to_i32 })
    end

    # Inverts R, G and B (alpha untouched).
    def invert : Image
      result = dup
      result.invert!
      result
    end

    def invert! : self
      apply_lut!(Image.build_lut { |i| 255 - i })
    end

    # Stretches [black, white] to [0, 255] (clipping outside it), then applies `gamma`.
    def levels(black : Int = 0, white : Int = 255, gamma : Float64 = 1.0) : Image
      raise ArgumentError.new("white must be greater than black") unless white > black
      b = black.to_i32
      range = (white - black).to_f64
      inv = 1.0 / gamma
      lut = Image.build_lut { |i| (((i - b) / range).clamp(0.0, 1.0) ** inv * 255.0).round.to_i32 }
      result = dup
      result.apply_lut!(lut)
      result
    end

    # Pixels with luma >= `level` become white, others black.
    def threshold(level : Int = 128) : Image
      result = dup
      p = result.pixels.to_unsafe
      size.times do
        l = (p[0].to_i32 &* 77 &+ p[1].to_i32 &* 150 &+ p[2].to_i32 &* 29 &+ 128) >> 8
        v = l >= level ? 255_u8 : 0_u8
        p[0] = v
        p[1] = v
        p[2] = v
        p += 4
      end
      result
    end

    # Scales colour intensity. 0 = grayscale, 1 = unchanged, >1 = more vivid.
    def saturation(factor : Float64) : Image
      result = dup
      f = (factor * 256).round.to_i32
      p = result.pixels.to_unsafe
      Parallel.bands(@height, 128) do |y0, y1|
        q = p + y0 * @width * 4
        ((y1 - y0) * @width).times do
          l = (q[0].to_i32 &* 77 &+ q[1].to_i32 &* 150 &+ q[2].to_i32 &* 29 &+ 128) >> 8
          q[0] = Immagini.clamp_u8(l &+ (((q[0].to_i32 &- l) &* f) >> 8))
          q[1] = Immagini.clamp_u8(l &+ (((q[1].to_i32 &- l) &* f) >> 8))
          q[2] = Immagini.clamp_u8(l &+ (((q[2].to_i32 &- l) &* f) >> 8))
          q += 4
        end
      end
      result
    end

    # Rotates hue by `degrees` using a linear RGB rotation about the grey axis.
    def hue_rotate(degrees : Float64) : Image
      r = degrees * Math::PI / 180.0
      c = Math.cos(r)
      s = Math.sin(r)
      m = {
        0.213 + c * 0.787 - s * 0.213, 0.715 - c * 0.715 - s * 0.715, 0.072 - c * 0.072 + s * 0.928,
        0.213 - c * 0.213 + s * 0.143, 0.715 + c * 0.285 + s * 0.140, 0.072 - c * 0.072 - s * 0.283,
        0.213 - c * 0.213 - s * 0.787, 0.715 - c * 0.715 + s * 0.715, 0.072 + c * 0.928 + s * 0.072,
      }.map { |v| (v * 256).round.to_i32 }
      color_matrix(m)
    end

    # Warm brown tone.
    def sepia : Image
      color_matrix({
        (0.393 * 256).round.to_i32, (0.769 * 256).round.to_i32, (0.189 * 256).round.to_i32,
        (0.349 * 256).round.to_i32, (0.686 * 256).round.to_i32, (0.168 * 256).round.to_i32,
        (0.272 * 256).round.to_i32, (0.534 * 256).round.to_i32, (0.131 * 256).round.to_i32,
      })
    end

    # Applies a 3x3 colour matrix given in 8.8 fixed point (row-major, rows = R,G,B out).
    private def color_matrix(m : Tuple) : Image
      result = dup
      p = result.pixels.to_unsafe
      Parallel.bands(@height, 128) do |y0, y1|
        q = p + y0 * @width * 4
        ((y1 - y0) * @width).times do
          r = q[0].to_i32
          g = q[1].to_i32
          b = q[2].to_i32
          q[0] = Immagini.clamp_u8((r &* m[0] &+ g &* m[1] &+ b &* m[2] &+ 128) >> 8)
          q[1] = Immagini.clamp_u8((r &* m[3] &+ g &* m[4] &+ b &* m[5] &+ 128) >> 8)
          q[2] = Immagini.clamp_u8((r &* m[6] &+ g &* m[7] &+ b &* m[8] &+ 128) >> 8)
          q += 4
        end
      end
      result
    end

    # Multiplies the alpha channel by `factor` (0..1).
    def opacity(factor : Float64) : Image
      result = dup
      f = (factor.clamp(0.0, 1.0) * 256).round.to_i32
      p = result.pixels.to_unsafe + 3
      size.times do
        p.value = ((p.value.to_i32 &* f) >> 8).clamp(0, 255).to_u8!
        p += 4
      end
      result
    end

    # Composites onto an opaque `background`, returning a fully opaque image.
    def flatten(background : Color = Color::WHITE) : Image
      result = Image.new(@width, @height, background.with_alpha(255))
      result.composite!(self, 0, 0)
      result
    end

    # Per-channel histogram: `{r, g, b, luma}`, each 256 counts.
    def histogram : {Array(Int32), Array(Int32), Array(Int32), Array(Int32)}
      r = Array(Int32).new(256, 0)
      g = Array(Int32).new(256, 0)
      b = Array(Int32).new(256, 0)
      l = Array(Int32).new(256, 0)
      p = @pixels.to_unsafe
      size.times do
        r[p[0]] += 1
        g[p[1]] += 1
        b[p[2]] += 1
        l[(p[0].to_i32 &* 77 &+ p[1].to_i32 &* 150 &+ p[2].to_i32 &* 29 &+ 128) >> 8] += 1
        p += 4
      end
      {r, g, b, l}
    end

    # Linearly stretches the range of luma values actually present to
    # 0..255 (a "levels" with black/white points taken from the histogram).
    def auto_contrast : Image
      _, _, _, l = histogram
      lo = 0
      while lo < 255 && l[lo] == 0
        lo += 1
      end
      hi = 255
      while hi > lo && l[hi] == 0
        hi -= 1
      end
      return dup if hi <= lo
      levels(lo, hi)
    end
  end
end
