module Immagini
  class Image
    # Gaussian blur with standard deviation `sigma` (pixels). Separable,
    # fixed-point, alpha-aware, edges clamp.
    #
    # With `fast: true` the Gaussian is approximated by three successive box
    # blurs (running sums). Cost per pixel no longer depends on `sigma`, so it
    # is much faster for sigma > ~2, at the price of a small shape error
    # (typically < 1-2 grey levels).
    def blur(sigma : Float64, fast : Bool = false) : Image
      raise ArgumentError.new("sigma must be >= 0") if sigma < 0
      return dup if sigma == 0
      return fast_gaussian(sigma) if fast
      radius = Math.max((sigma * 3).ceil.to_i32, 1)
      raw = Array(Float64).new(radius * 2 + 1) { |i| Math.exp(-((i - radius) ** 2) / (2 * sigma * sigma)) }
      kernel = Pixels.quantize_kernel(raw, 14)
      convolve_separable(kernel, kernel)
    end

    # Uniform box blur of the given radius (fast, softer than gaussian).
    def box_blur(radius : Int) : Image
      raise ArgumentError.new("radius must be >= 0") if radius < 0
      return dup if radius == 0
      k = Pixels.quantize_kernel(Array(Float64).new(radius * 2 + 1, 1.0), 14)
      convolve_separable(k, k)
    end

    # Unsharp mask: `amount` of the (original - blurred) detail added back.
    # `threshold` ignores differences smaller than it (avoids amplifying noise).
    def sharpen(sigma : Float64 = 1.0, amount : Float64 = 1.0, threshold : Int = 0) : Image
      blurred = blur(sigma)
      result = dup
      a = (amount * 256).round.to_i32
      o = result.pixels.to_unsafe
      b = blurred.pixels.to_unsafe
      t = threshold.to_i32
      Parallel.bands(@height, 128) do |y0, y1|
        i = y0 * @width * 4
        ((y1 - y0) * @width).times do
          3.times do |c|
            diff = o[i + c].to_i32 - b[i + c].to_i32
            if diff.abs > t
              o[i + c] = Immagini.clamp_u8(o[i + c].to_i32 &+ ((diff &* a) >> 8))
            end
          end
          i += 4
        end
      end
      result
    end

    # Convolves with a square, odd-sized `kernel` (row-major). Result is
    # divided by `divisor` (default: kernel sum, or 1 if the sum is 0) and
    # `bias` is added. Alpha is preserved. Edges clamp.
    def convolve(kernel : Array(Float64), divisor : Float64? = nil, bias : Float64 = 0.0) : Image
      n = Math.sqrt(kernel.size).to_i32
      unless n * n == kernel.size && n.odd?
        raise ArgumentError.new("kernel must be square with odd side length")
      end
      sum = kernel.sum
      div = divisor || (sum.abs < 1e-9 ? 1.0 : sum)
      k = kernel.map { |v| (v / div * 1024).round.to_i32 }
      bi = (bias * 1024).round.to_i32
      r = n // 2
      result = Image.new(@width, @height)
      src = @pixels.to_unsafe
      dst = result.pixels.to_unsafe
      w = @width
      h = @height
      kp = k.to_unsafe
      Parallel.bands(h, 16) do |y0, y1|
        (y0...y1).each do |y|
          row_inner = y >= r && y < h - r
          w.times do |x|
            sr = sg = sb = bi
            if row_inner && x >= r && x < w - r
              # interior: direct addressing, no clamping
              ki = 0
              n.times do |ky|
                q = src + ((y + ky - r) * w + (x - r)) * 4
                n.times do
                  wt = kp[ki]
                  sr &+= q[0].to_i32 &* wt
                  sg &+= q[1].to_i32 &* wt
                  sb &+= q[2].to_i32 &* wt
                  q += 4
                  ki += 1
                end
              end
            else
              n.times do |ky|
                yy = (y + ky - r).clamp(0, h - 1)
                n.times do |kx|
                  xx = (x + kx - r).clamp(0, w - 1)
                  wt = kp[ky * n + kx]
                  q = src + (yy * w + xx) * 4
                  sr &+= q[0].to_i32 &* wt
                  sg &+= q[1].to_i32 &* wt
                  sb &+= q[2].to_i32 &* wt
                end
              end
            end
            d = dst + (y * w + x) * 4
            d[0] = Immagini.clamp_u8((sr &+ 512) >> 10)
            d[1] = Immagini.clamp_u8((sg &+ 512) >> 10)
            d[2] = Immagini.clamp_u8((sb &+ 512) >> 10)
            d[3] = src[(y * w + x) * 4 + 3]
          end
        end
      end
      result
    end

    # Sobel gradient magnitude as an opaque grayscale image.
    def edges : Image
      result = Image.new(@width, @height)
      sobel_magnitude(grayscale, result)
      result
    end

    private def sobel_magnitude(g : Image, result : Image) : Nil
      w = @width
      h = @height
      s = g.pixels.to_unsafe
      o = result.pixels.to_unsafe
      Parallel.bands(h, 16) do |y0, y1|
        (y0...y1).each do |y|
          ym = Math.max(y - 1, 0)
          yp = Math.min(y + 1, h - 1)
          w.times do |x|
            xm = Math.max(x - 1, 0)
            xp = Math.min(x + 1, w - 1)
            v = ->(xx : Int32, yy : Int32) { s[(yy * w + xx) * 4].to_i32 }
            gx = -v.call(xm, ym) + v.call(xp, ym) - 2 * v.call(xm, y) + 2 * v.call(xp, y) - v.call(xm, yp) + v.call(xp, yp)
            gy = -v.call(xm, ym) - 2 * v.call(x, ym) - v.call(xp, ym) + v.call(xm, yp) + 2 * v.call(x, yp) + v.call(xp, yp)
            m = Immagini.clamp_u8(Math.sqrt((gx * gx + gy * gy).to_f64).to_i32)
            d = o + (y * w + x) * 4
            d[0] = m
            d[1] = m
            d[2] = m
            d[3] = 255_u8
          end
        end
      end
    end

    # Median filter over a (2r+1)^2 window per colour channel. Good for
    # removing salt-and-pepper noise. O(r^2) per pixel; keep r small.
    def median(radius : Int = 1) : Image
      raise ArgumentError.new("radius must be >= 1") if radius < 1
      r = radius.to_i32
      result = Image.new(@width, @height)
      src = @pixels.to_unsafe
      dst = result.pixels.to_unsafe
      w = @width
      h = @height
      Parallel.bands(h, 16) do |y0, y1|
        cnt = (2 * r + 1) ** 2
        buf = Slice(UInt8).new(cnt)
        (y0...y1).each do |y|
          w.times do |x|
            4.times do |c|
              i = 0
              (-r..r).each do |dy|
                yy = (y + dy).clamp(0, h - 1)
                (-r..r).each do |dx|
                  xx = (x + dx).clamp(0, w - 1)
                  buf[i] = src[(yy * w + xx) * 4 + c]
                  i += 1
                end
              end
              buf.sort!
              dst[(y * w + x) * 4 + c] = buf[cnt // 2]
            end
          end
        end
      end
      result
    end

    # Gaussian/box style separable convolution on premultiplied RGBA.
    private def convolve_separable(kx : Array(Int32), ky : Array(Int32)) : Image
      alpha = !opaque?
      src = @pixels
      if alpha
        src = @pixels.dup
        Pixels.premultiply!(src.to_unsafe, size)
      end
      rx = kx.size // 2
      ry = ky.size // 2
      w = @width
      h = @height
      tmp = Bytes.new(@pixels.size)
      sp = src.to_unsafe
      tp = tmp.to_unsafe

      kp = kx.to_unsafe
      taps = kx.size
      Parallel.bands(h, 32) do |y0, y1|
        (y0...y1).each do |y|
          row = sp + y * w * 4
          d = tp + y * w * 4
          w.times do |x|
            r = g = b = a = 8192
            if x >= rx && x < w - rx
              # interior: contiguous taps, no edge clamping
              q = row + (x - rx) * 4
              k = 0
              while k < taps
                wt = kp[k]
                r &+= q[0].to_i32 &* wt
                g &+= q[1].to_i32 &* wt
                b &+= q[2].to_i32 &* wt
                a &+= q[3].to_i32 &* wt
                q += 4
                k += 1
              end
            else
              taps.times do |k|
                wt = kp[k]
                q = row + (x + k - rx).clamp(0, w - 1) * 4
                r &+= q[0].to_i32 &* wt
                g &+= q[1].to_i32 &* wt
                b &+= q[2].to_i32 &* wt
                a &+= q[3].to_i32 &* wt
              end
            end
            d[0] = Immagini.clamp_u8(r >> 14)
            d[1] = Immagini.clamp_u8(g >> 14)
            d[2] = Immagini.clamp_u8(b >> 14)
            d[3] = Immagini.clamp_u8(a >> 14)
            d += 4
          end
        end
      end

      result = Bytes.new(@pixels.size)
      op = result.to_unsafe
      rowb = w * 4
      Parallel.bands(h, 16) do |y0, y1|
        acc = Slice(Int32).new(rowb)
        ap = acc.to_unsafe
        (y0...y1).each do |y|
          rowb.times { |i| ap[i] = 8192 }
          ky.each_with_index do |wt, k|
            yy = (y + k - ry).clamp(0, h - 1)
            s = tp + yy * rowb
            i = 0
            while i < rowb
              ap[i] &+= s[i].to_i32 &* wt
              i += 1
            end
          end
          d = op + y * rowb
          i = 0
          while i < rowb
            d[i] = Immagini.clamp_u8(ap[i] >> 14)
            i += 1
          end
        end
      end
      Pixels.unpremultiply!(op, size) if alpha
      Image.new(w, h, result)
    end

    # Box sizes whose successive application approximates a Gaussian
    # (W3C/CSS "boxes for gauss": n passes, ideal width sqrt(12 s^2 / n + 1)).
    private def box_radii(sigma : Float64, passes : Int32 = 3) : Array(Int32)
      ideal = Math.sqrt(12.0 * sigma * sigma / passes + 1.0)
      wl = ideal.floor.to_i32
      wl -= 1 if wl.even?
      wu = wl + 2
      m = ((12.0 * sigma * sigma - passes * wl * wl - 4.0 * passes * wl - 3.0 * passes) / (-4.0 * wl - 4.0)).round.to_i32
      Array(Int32).new(passes) { |i| ((i < m ? wl : wu) - 1) // 2 }
    end

    private def fast_gaussian(sigma : Float64) : Image
      alpha = !opaque?
      a = @pixels.dup
      Pixels.premultiply!(a.to_unsafe, size) if alpha
      b = Bytes.new(a.size)
      radii = box_radii(sigma)
      w = @width
      h = @height

      # ping-pong: a -> b -> a -> b ...
      from, to = a, b
      radii.each do |r|
        box_pass_h(from.to_unsafe, to.to_unsafe, w, h, r)
        from, to = to, from
      end
      radii.each do |r|
        box_pass_v(from.to_unsafe, to.to_unsafe, w, h, r)
        from, to = to, from
      end
      Pixels.unpremultiply!(from.to_unsafe, size) if alpha
      Image.new(w, h, from)
    end

    # Fixed-point reciprocal so `(sum * inv + half) >> 32` == round(sum / n).
    @[AlwaysInline]
    private def box_inv(n : Int32) : UInt64
      ((1_u64 << 32) + (n // 2).to_u64) // n.to_u64
    end

    # Horizontal box blur of radius `r`, edges clamped, via a running sum.
    private def box_pass_h(src : Pointer(UInt8), dst : Pointer(UInt8), w : Int32, h : Int32, r : Int32) : Nil
      if r == 0
        dst.copy_from(src, w * h * 4)
        return
      end
      inv = box_inv(2 * r + 1)
      Parallel.bands(h, 16) do |y0, y1|
        (y0...y1).each do |y|
          row = src + y * w * 4
          out = dst + y * w * 4
          # window for x = 0 is [-r, r] with clamping; all four channels in one sweep
          s0 = (r + 1).to_u32 &* row[0].to_u32
          s1 = (r + 1).to_u32 &* row[1].to_u32
          s2 = (r + 1).to_u32 &* row[2].to_u32
          s3 = (r + 1).to_u32 &* row[3].to_u32
          1.upto(r) do |i|
            q = row + Math.min(i, w - 1) * 4
            s0 &+= q[0].to_u32
            s1 &+= q[1].to_u32
            s2 &+= q[2].to_u32
            s3 &+= q[3].to_u32
          end
          o = out
          x = 0
          while x < w
            o[0] = ((s0.to_u64 &* inv &+ 0x80000000_u64) >> 32).to_u8!
            o[1] = ((s1.to_u64 &* inv &+ 0x80000000_u64) >> 32).to_u8!
            o[2] = ((s2.to_u64 &* inv &+ 0x80000000_u64) >> 32).to_u8!
            o[3] = ((s3.to_u64 &* inv &+ 0x80000000_u64) >> 32).to_u8!
            ad = row + Math.min(x + r + 1, w - 1) * 4
            sb = row + Math.max(x - r, 0) * 4
            s0 = s0 &+ ad[0].to_u32 &- sb[0].to_u32
            s1 = s1 &+ ad[1].to_u32 &- sb[1].to_u32
            s2 = s2 &+ ad[2].to_u32 &- sb[2].to_u32
            s3 = s3 &+ ad[3].to_u32 &- sb[3].to_u32
            o += 4
            x += 1
          end
        end
      end
    end

    # Vertical box blur; works on whole rows so memory access stays sequential.
    private def box_pass_v(src : Pointer(UInt8), dst : Pointer(UInt8), w : Int32, h : Int32, r : Int32) : Nil
      if r == 0
        dst.copy_from(src, w * h * 4)
        return
      end
      inv = box_inv(2 * r + 1)
      rowb = w * 4
      # split the width into column bands so threads never share output bytes
      Parallel.bands(w, 64) do |x0, x1|
        n = (x1 - x0) * 4
        sums = Slice(UInt32).new(n)
        sp = sums.to_unsafe
        off = x0 * 4
        # window for y = 0 is [-r, r] with clamping
        first = src + off
        n.times { |i| sp[i] = (r + 1).to_u32 &* first[i].to_u32 }
        1.upto(r) do |i|
          q = src + Math.min(i, h - 1) * rowb + off
          n.times { |k| sp[k] &+= q[k].to_u32 }
        end
        h.times do |y|
          o = dst + y * rowb + off
          n.times { |k| o[k] = ((sp[k].to_u64 &* inv &+ 0x80000000_u64) >> 32).to_u8! }
          add = src + Math.min(y + r + 1, h - 1) * rowb + off
          sub = src + Math.max(y - r, 0) * rowb + off
          n.times { |k| sp[k] = sp[k] &+ add[k].to_u32 &- sub[k].to_u32 }
        end
      end
    end
  end
end
