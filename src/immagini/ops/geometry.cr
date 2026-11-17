module Immagini
  class Image
    # Returns the `w`x`h` rectangle whose top-left corner is `(x, y)`.
    # Raises `ArgumentError` if the rectangle is not fully inside the image.
    def crop(x : Int, y : Int, w : Int, h : Int) : Image
      unless w > 0 && h > 0 && x >= 0 && y >= 0 && x + w <= @width && y + h <= @height
        raise ArgumentError.new("crop rectangle #{x},#{y} #{w}x#{h} is outside the #{@width}x#{@height} image")
      end
      result = Image.new(w.to_i32, h.to_i32)
      dst = result.pixels.to_unsafe
      row = w.to_i32 * 4
      h.times do |r|
        (dst + r * row).copy_from(row_ptr((y + r).to_i32) + x * 4, row)
      end
      result
    end

    # Mirrors left-right.
    def flip_horizontal : Image
      remap(@width, @height, @width - 1, -1, @width)
    end

    # Mirrors top-bottom.
    def flip_vertical : Image
      remap(@width, @height, (@height - 1) * @width, 1, -@width)
    end

    # In-place left-right mirror.
    def flip_horizontal! : self
      p = @pixels.to_unsafe.as(UInt32*)
      @height.times do |y|
        row = p + y * @width
        i = 0
        j = @width - 1
        while i < j
          t = row[i]
          row[i] = row[j]
          row[j] = t
          i += 1
          j -= 1
        end
      end
      self
    end

    # In-place top-bottom mirror.
    def flip_vertical! : self
      rb = @width * 4
      tmp = Bytes.new(rb)
      base = @pixels.to_unsafe
      i = 0
      j = @height - 1
      while i < j
        a = base + i * rb
        b = base + j * rb
        tmp.to_unsafe.copy_from(a, rb)
        a.copy_from(b, rb)
        b.copy_from(tmp.to_unsafe, rb)
        i += 1
        j -= 1
      end
      self
    end

    # Rotates 90 degrees clockwise.
    def rotate90 : Image
      remap(@height, @width, @height - 1, @height, -1)
    end

    def rotate180 : Image
      remap(@width, @height, @width * @height - 1, -1, -@width)
    end

    # Rotates 270 degrees clockwise (90 counter-clockwise).
    def rotate270 : Image
      remap(@height, @width, (@width - 1) * @height, -@height, 1)
    end

    # Reflects across the main diagonal (swaps x and y).
    def transpose : Image
      remap(@height, @width, 0, @height, 1)
    end

    # Reflects across the anti-diagonal.
    def transverse : Image
      remap(@height, @width, @width * @height - 1, -@height, -1)
    end

    # Applies an EXIF orientation value (1..8) so the image displays upright.
    def orient(orientation : Int) : Image
      case orientation
      when 2 then flip_horizontal
      when 3 then rotate180
      when 4 then flip_vertical
      when 5 then transpose
      when 6 then rotate90
      when 7 then transverse
      when 8 then rotate270
      else        dup
      end
    end

    # Copies every pixel `(x, y)` to `dst[base + x * xs + y * ys]` (pixel
    # units), walking in 32x32 tiles so both sides stay cache-friendly.
    private def remap(out_w : Int32, out_h : Int32, base : Int32, xs : Int32, ys : Int32) : Image
      result = Image.new(out_w, out_h)
      src = @pixels.to_unsafe.as(UInt32*)
      dst = result.pixels.to_unsafe.as(UInt32*)
      w = @width
      h = @height
      tile = 32
      Parallel.bands(h, 64) do |ya, yb|
        ty = ya
        while ty < yb
          ty_end = Math.min(ty + tile, yb)
          tx = 0
          while tx < w
            tx_end = Math.min(tx + tile, w)
            y = ty
            while y < ty_end
              s = src + y * w
              d = dst + base + y * ys
              x = tx
              while x < tx_end
                d[x * xs] = s[x]
                x += 1
              end
              y += 1
            end
            tx += tile
          end
          ty += tile
        end
      end
      result
    end

    # Rotates by `degrees` clockwise around the center.
    #
    # With `expand: true` (default) the canvas grows to hold the whole rotated
    # image; otherwise the original size is kept and corners are cut off.
    # Uncovered areas get `background`. `Filter::Nearest` samples the nearest
    # pixel; any other filter uses bilinear interpolation. Exact multiples of
    # 90 degrees take a lossless fast path when `expand` is true.
    def rotate(degrees : Float64, filter : Filter = Filter::Bilinear,
               background : Color = Color::TRANSPARENT, expand : Bool = true) : Image
      d = degrees % 360.0
      d += 360.0 if d < 0
      if expand
        return dup if d == 0.0
        return rotate90 if d == 90.0
        return rotate180 if d == 180.0
        return rotate270 if d == 270.0
      end

      theta = d * Math::PI / 180.0
      cos = Math.cos(theta)
      sin = Math.sin(theta)
      ow, oh = if expand
                 {((@width * cos.abs + @height * sin.abs) - 1e-9).ceil.to_i32.clamp(1, Int32::MAX),
                  ((@width * sin.abs + @height * cos.abs) - 1e-9).ceil.to_i32.clamp(1, Int32::MAX)}
               else
                 {@width, @height}
               end
      Image.check_dimensions(ow, oh)
      result = Image.new(ow, oh)

      cx_in = @width / 2.0
      cy_in = @height / 2.0
      cx_out = ow / 2.0
      cy_out = oh / 2.0
      nearest = filter.nearest?
      opaque_src = opaque? && background.opaque?
      w = @width
      h = @height
      src = @pixels.to_unsafe
      bg = background
      dst0 = result.pixels.to_unsafe

      Parallel.bands(oh, 16) do |y0, y1|
        (y0...y1).each do |yo|
          dst = dst0 + yo * ow * 4
          dy = yo + 0.5 - cy_out
          ow.times do |xo|
            dx = xo + 0.5 - cx_out
            # inverse rotation back into source space (pixel-center coordinates)
            fx = dx * cos + dy * sin + cx_in - 0.5
            fy = -dx * sin + dy * cos + cy_in - 0.5
            if nearest
              ix = (fx + 0.5).floor.to_i32
              iy = (fy + 0.5).floor.to_i32
              if ix >= 0 && iy >= 0 && ix < w && iy < h
                dst.copy_from(src + (iy * w + ix) * 4, 4)
              else
                dst[0] = bg.r
                dst[1] = bg.g
                dst[2] = bg.b
                dst[3] = bg.a
              end
            else
              x0 = fx.floor.to_i32
              y0i = fy.floor.to_i32
              wx = ((fx - x0) * 256.0).to_i32
              wy = ((fy - y0i) * 256.0).to_i32
              w00 = (256 - wx) * (256 - wy)
              w10 = wx * (256 - wy)
              w01 = (256 - wx) * wy
              w11 = wx * wy
              if opaque_src && x0 >= 0 && y0i >= 0 && x0 + 1 < w && y0i + 1 < h
                p00 = src + (y0i * w + x0) * 4
                p10 = p00 + 4
                p01 = p00 + w * 4
                p11 = p01 + 4
                3.times do |c|
                  v = p00[c].to_i32 &* w00 &+ p10[c].to_i32 &* w10 &+ p01[c].to_i32 &* w01 &+ p11[c].to_i32 &* w11
                  dst[c] = ((v &+ 32768) >> 16).to_u8!
                end
                dst[3] = 255_u8
              else
                # Edge or translucent: alpha-weighted blend, out-of-range = background.
                sa = 0_i64
                sr = sg = sb = 0_i64
                {% for pair in [{"00", "x0", "y0i"}, {"10", "x0 + 1", "y0i"}, {"01", "x0", "y0i + 1"}, {"11", "x0 + 1", "y0i + 1"}] %}
                  begin
                    px = {{pair[1].id}}
                    py = {{pair[2].id}}
                    if px >= 0 && py >= 0 && px < w && py < h
                      q = src + (py * w + px) * 4
                      a = q[3].to_i64 * w{{pair[0].id}}
                      sa += a
                      sr += a * q[0]
                      sg += a * q[1]
                      sb += a * q[2]
                    else
                      a = bg.a.to_i64 * w{{pair[0].id}}
                      sa += a
                      sr += a * bg.r
                      sg += a * bg.g
                      sb += a * bg.b
                    end
                  end
                {% end %}
                if sa == 0
                  dst[0] = 0_u8
                  dst[1] = 0_u8
                  dst[2] = 0_u8
                  dst[3] = 0_u8
                else
                  dst[0] = ((sr + sa // 2) // sa).to_u8!
                  dst[1] = ((sg + sa // 2) // sa).to_u8!
                  dst[2] = ((sb + sa // 2) // sa).to_u8!
                  dst[3] = ((sa + 32768) >> 16).clamp(0, 255).to_u8!
                end
              end
            end
            dst += 4
          end
        end
      end
      result
    end

    # Adds a border of `color` around the image.
    def pad(left : Int = 0, top : Int = 0, right : Int = 0, bottom : Int = 0,
            color : Color = Color::TRANSPARENT) : Image
      if left < 0 || top < 0 || right < 0 || bottom < 0
        raise ArgumentError.new("padding must not be negative")
      end
      result = Image.new((@width + left + right).to_i32, (@height + top + bottom).to_i32, color)
      row = @width * 4
      dst = result.pixels.to_unsafe
      ow = result.width
      @height.times do |y|
        (dst + ((y + top) * ow + left) * 4).copy_from(row_ptr(y), row)
      end
      result
    end

    # Crops away the border that matches `color` (default: the top-left pixel)
    # within `tolerance` per channel. Returns a copy when nothing differs.
    def trim(tolerance : Int = 0, color : Color? = nil) : Image
      bg = color || unsafe_get(0, 0)
      differs = ->(p : Pointer(UInt8)) {
        (p[0].to_i32 - bg.r).abs > tolerance || (p[1].to_i32 - bg.g).abs > tolerance ||
        (p[2].to_i32 - bg.b).abs > tolerance || (p[3].to_i32 - bg.a).abs > tolerance
      }
      row_has = ->(y : Int32) {
        p = row_ptr(y)
        found = false
        @width.times do
          if differs.call(p)
            found = true
            break
          end
          p += 4
        end
        found
      }
      top = 0
      while top < @height && !row_has.call(top)
        top += 1
      end
      return dup if top == @height
      bottom = @height - 1
      while bottom > top && !row_has.call(bottom)
        bottom -= 1
      end

      left = @width
      right = -1
      (top..bottom).each do |y|
        p = row_ptr(y)
        @width.times do |x|
          if differs.call(p + x * 4)
            left = x if x < left
            break
          end
        end
        (@width - 1).downto(0) do |x|
          if differs.call(p + x * 4)
            right = x if x > right
            break
          end
        end
      end
      crop(left, top, right - left + 1, bottom - top + 1)
    end
  end
end
