module Immagini
  # Resampling filters, ordered roughly from fastest to highest quality.
  enum Filter
    # Picks the closest source pixel. No smoothing; blocky when enlarging.
    Nearest
    # Area average. Ideal for shrinking; blocky when enlarging.
    Box
    # Triangle. Cheap and smooth.
    Bilinear
    # Mitchell-Netravali (B = C = 1/3). Soft, no ringing.
    Mitchell
    # Catmull-Rom cubic (B = 0, C = 1/2). Sharper than bilinear.
    Bicubic
    # Lanczos with a = 3. Sharpest; slight ringing. Best for photos.
    Lanczos3

    # Kernel radius in source pixels at scale 1.
    def support : Float64
      case self
      in Nearest  then 0.5
      in Box      then 0.5
      in Bilinear then 1.0
      in Mitchell then 2.0
      in Bicubic  then 2.0
      in Lanczos3 then 3.0
      end
    end

    def weight(x : Float64) : Float64
      x = x.abs
      case self
      in Nearest, Box
        x < 0.5 ? 1.0 : 0.0
      in Bilinear
        x < 1.0 ? 1.0 - x : 0.0
      in Mitchell
        cubic(x, 1.0 / 3.0, 1.0 / 3.0)
      in Bicubic
        cubic(x, 0.0, 0.5)
      in Lanczos3
        if x < 1e-9
          1.0
        elsif x < 3.0
          px = Math::PI * x
          3.0 * Math.sin(px) * Math.sin(px / 3.0) / (px * px)
        else
          0.0
        end
      end
    end

    private def cubic(x : Float64, b : Float64, c : Float64) : Float64
      if x < 1.0
        ((12 - 9 * b - 6 * c) * x * x * x + (-18 + 12 * b + 6 * c) * x * x + (6 - 2 * b)) / 6.0
      elsif x < 2.0
        ((-b - 6 * c) * x * x * x + (6 * b + 30 * c) * x * x + (-12 * b - 48 * c) * x + (8 * b + 24 * c)) / 6.0
      else
        0.0
      end
    end
  end

  # Per-output-pixel tap list for one axis: `starts[i]` is the first source
  # index, `counts[i]` the number of taps, and the taps live at
  # `weights[i * stride, counts[i]]` as 14-bit fixed-point values that sum to
  # exactly 16384.
  private struct Contribs
    getter starts : Slice(Int32)
    getter counts : Slice(Int32)
    getter weights : Slice(Int32)
    getter stride : Int32

    BITS = 14

    def initialize(src_len : Int32, dst_len : Int32, filter : Filter)
      scale = src_len / dst_len
      # Widen the kernel when shrinking so every source pixel contributes.
      fscale = Math.max(scale, 1.0)
      support = filter.support * fscale
      @stride = (support * 2).ceil.to_i32 + 2
      @starts = Slice(Int32).new(dst_len)
      @counts = Slice(Int32).new(dst_len)
      @weights = Slice(Int32).new(dst_len * @stride)

      dst_len.times do |i|
        center = (i + 0.5) * scale
        # Pixel k has its centre at k + 0.5, so it is inside the kernel when
        # k + 0.5 lies within `support` of `center`.
        lo = Math.max((center - support + 0.5).floor.to_i32, 0)
        hi = Math.min((center + support + 0.5).floor.to_i32, src_len)
        lo = Math.min(lo, src_len - 1)
        hi = Math.max(hi, lo + 1)
        raw = Array(Float64).new(hi - lo) do |k|
          filter.weight((lo + k + 0.5 - center) / fscale)
        end
        if raw.sum.abs < 1e-12
          # degenerate (e.g. nearest between samples): fall back to the closest tap
          nearest = (center.floor.to_i32).clamp(lo, hi - 1) - lo
          raw.fill(0.0)
          raw[nearest] = 1.0
        end
        q = Pixels.quantize_kernel(raw, BITS)
        @starts[i] = lo
        @counts[i] = q.size
        q.each_with_index { |v, k| @weights[i * @stride + k] = v }
      end
    end
  end

  class Image
    # Resizes to exactly `width` x `height`.
    #
    # Resampling is separable (horizontal then vertical) with fixed-point
    # integer weights. Colour is weighted by alpha so transparent pixels do
    # not bleed into their neighbours.
    def resize(width : Int, height : Int, filter : Filter = Filter::Lanczos3) : Image
      Image.check_dimensions(width, height)
      w = width.to_i32
      h = height.to_i32
      return dup if w == @width && h == @height

      if filter.nearest?
        return resize_nearest(w, h)
      end

      has_alpha = !opaque?
      src = @pixels
      if has_alpha
        src = @pixels.dup
        Pixels.premultiply!(src.to_unsafe, size)
      end

      # Run the cheaper axis first: it shrinks the intermediate image most.
      if w * @height <= @width * h
        mid = resample_axis(src, @width, @height, w, true, filter)
        res = resample_axis(mid, w, @height, h, false, filter)
      else
        mid = resample_axis(src, @width, @height, h, false, filter)
        res = resample_axis(mid, @width, h, w, true, filter)
      end
      Pixels.unpremultiply!(res.to_unsafe, w * h) if has_alpha
      Image.new(w, h, res)
    end

    # Scales both sides by `factor`.
    def scale(factor : Float64, filter : Filter = Filter::Lanczos3) : Image
      raise ArgumentError.new("scale factor must be positive") unless factor > 0
      resize(Math.max((@width * factor).round.to_i32, 1), Math.max((@height * factor).round.to_i32, 1), filter)
    end

    # Resizes so the image fits inside `max_w` x `max_h`, keeping aspect ratio.
    # Never enlarges unless `upscale` is true.
    def fit(max_w : Int, max_h : Int, filter : Filter = Filter::Lanczos3, upscale : Bool = false) : Image
      raise ArgumentError.new("fit box must be positive") unless max_w > 0 && max_h > 0
      s = Math.min(max_w / @width, max_h / @height)
      return dup if s >= 1.0 && !upscale
      w = Math.max((@width * s).round.to_i32, 1)
      h = Math.max((@height * s).round.to_i32, 1)
      resize(Math.min(w, max_w), Math.min(h, max_h), filter)
    end

    # Resizes and center-crops so the result is exactly `width` x `height`
    # (like CSS `object-fit: cover`). `gravity_x`/`gravity_y` in 0..1 pick which
    # part is kept (0.5 = centre).
    def fill(width : Int, height : Int, filter : Filter = Filter::Lanczos3,
             gravity_x : Float64 = 0.5, gravity_y : Float64 = 0.5) : Image
      Image.check_dimensions(width, height)
      s = Math.max(width / @width, height / @height)
      iw = Math.max((@width * s).round.to_i32, width.to_i32)
      ih = Math.max((@height * s).round.to_i32, height.to_i32)
      big = resize(iw, ih, filter)
      x = ((iw - width) * gravity_x.clamp(0.0, 1.0)).round.to_i32
      y = ((ih - height) * gravity_y.clamp(0.0, 1.0)).round.to_i32
      big.crop(x, y, width, height)
    end

    # Resizes to fit inside `width` x `height` and centres it on a canvas of
    # that size filled with `background` (letterboxing).
    def contain(width : Int, height : Int, filter : Filter = Filter::Lanczos3,
                background : Color = Color::TRANSPARENT) : Image
      inner = fit(width, height, filter, upscale: true)
      canvas = Image.new(width.to_i32, height.to_i32, background)
      canvas.composite!(inner, (width - inner.width) // 2, (height - inner.height) // 2)
      canvas
    end

    # Makes a thumbnail no larger than `size` x `size` (never enlarges).
    def thumbnail(size : Int, filter : Filter = Filter::Lanczos3) : Image
      fit(size, size, filter)
    end

    private def resize_nearest(w : Int32, h : Int32) : Image
      result = Image.new(w, h)
      xmap = Slice(Int32).new(w) { |x| Math.min(((x + 0.5) * @width / w).floor.to_i32, @width - 1) }
      src = @pixels.to_unsafe.as(UInt32*)
      dst = result.pixels.to_unsafe.as(UInt32*)
      Parallel.bands(h, 64) do |y0, y1|
        (y0...y1).each do |y|
          sy = Math.min(((y + 0.5) * @height / h).floor.to_i32, @height - 1)
          s = src + sy * @width
          d = dst + y * w
          x = 0
          while x < w
            d[x] = s[xmap.unsafe_fetch(x)]
            x += 1
          end
        end
      end
      result
    end

    # Resamples one axis. `horizontal` selects x (true) or y (false);
    # `src_w`/`src_h` describe `src`; `dst_len` is the new length on that axis.
    private def resample_axis(src : Bytes, src_w : Int32, src_h : Int32, dst_len : Int32,
                              horizontal : Bool, filter : Filter) : Bytes
      if horizontal
        c = Contribs.new(src_w, dst_len, filter)
        result = Bytes.new(dst_len * src_h * 4)
        sp = src.to_unsafe
        op = result.to_unsafe
        Parallel.bands(src_h, 32) do |y0, y1|
          (y0...y1).each do |y|
            s = sp + y * src_w * 4
            d = op + y * dst_len * 4
            dst_len.times do |x|
              n = c.counts.unsafe_fetch(x)
              wp = c.weights.to_unsafe + x * c.stride
              p = s + c.starts.unsafe_fetch(x) * 4
              r = g = b = a = 8192
              n.times do |k|
                wt = wp[k]
                r &+= p[0].to_i32 &* wt
                g &+= p[1].to_i32 &* wt
                b &+= p[2].to_i32 &* wt
                a &+= p[3].to_i32 &* wt
                p += 4
              end
              d[0] = Immagini.clamp_u8(r >> 14)
              d[1] = Immagini.clamp_u8(g >> 14)
              d[2] = Immagini.clamp_u8(b >> 14)
              d[3] = Immagini.clamp_u8(a >> 14)
              d += 4
            end
          end
        end
        result
      else
        c = Contribs.new(src_h, dst_len, filter)
        row = src_w * 4
        result = Bytes.new(src_w * dst_len * 4)
        sp = src.to_unsafe
        op = result.to_unsafe
        Parallel.bands(dst_len, 16) do |y0, y1|
          acc = Slice(Int32).new(row)
          (y0...y1).each do |y|
            n = c.counts.unsafe_fetch(y)
            wp = c.weights.to_unsafe + y * c.stride
            first = sp + c.starts.unsafe_fetch(y) * row
            ap = acc.to_unsafe
            # row-major accumulation: one contiguous pass per tap
            row.times { |i| ap[i] = 8192 }
            n.times do |k|
              wt = wp[k]
              s = first + k * row
              i = 0
              while i < row
                ap[i] &+= s[i].to_i32 &* wt
                i += 1
              end
            end
            d = op + y * row
            i = 0
            while i < row
              d[i] = Immagini.clamp_u8(ap[i] >> 14)
              i += 1
            end
          end
        end
        result
      end
    end
  end
end
