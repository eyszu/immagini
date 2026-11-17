module Immagini
  # How a source image is combined with the destination.
  enum Blend
    Normal
    Multiply
    Screen
    Overlay
    Darken
    Lighten
    Add
    Difference
  end

  class Image
    # Draws `src` onto this image with its top-left at `(x, y)` (may be
    # partly or fully outside). `opacity` scales the source alpha (0..1).
    # Uses straight-alpha "source over" with the chosen blend mode on colour.
    def composite!(src : Image, x : Int = 0, y : Int = 0, blend : Blend = Blend::Normal,
                   opacity : Float64 = 1.0) : self
      x0 = Math.max(x, 0).to_i32
      y0 = Math.max(y, 0).to_i32
      x1 = Math.min(x + src.width, @width).to_i32
      y1 = Math.min(y + src.height, @height).to_i32
      return self if x1 <= x0 || y1 <= y0

      op = (opacity.clamp(0.0, 1.0) * 255).round.to_i32
      n = x1 - x0
      (y0...y1).each do |dy|
        s = src.row_ptr((dy - y).to_i32) + (x0 - x).to_i32 * 4
        d = row_ptr(dy) + x0 * 4
        n.times do
          sa = op == 255 ? s[3].to_i32 : Immagini.div255(s[3].to_i32 &* op)
          if sa != 0
            da = d[3].to_i32
            if blend.normal? && sa == 255
              d.copy_from(s, 3)
              d[3] = 255_u8
            elsif blend.normal? && da == 255
              # opaque backdrop: result = d + (s - d) * sa / 255
              inv = 255 &- sa
              d[0] = Immagini.div255(s[0].to_i32 &* sa &+ d[0].to_i32 &* inv).to_u8!
              d[1] = Immagini.div255(s[1].to_i32 &* sa &+ d[1].to_i32 &* inv).to_u8!
              d[2] = Immagini.div255(s[2].to_i32 &* sa &+ d[2].to_i32 &* inv).to_u8!
            else
              # result alpha and blended colour (straight alpha)
              ra = sa &+ Immagini.div255(da &* (255 &- sa))
              3.times do |c|
                sc = s[c].to_i32
                dc = d[c].to_i32
                bc = blend_channel(blend, sc, dc)
                # mix source colour with backdrop according to backdrop alpha
                src_c = Immagini.div255(sc &* (255 &- da) &+ bc &* da)
                num = src_c &* sa &* 255 &+ dc &* da &* (255 &- sa)
                d[c] = ra == 0 ? 0_u8 : Immagini.clamp_u8((num &+ (ra &* 255) // 2) // (ra &* 255))
              end
              d[3] = ra.to_u8!
            end
          end
          s += 4
          d += 4
        end
      end
      self
    end

    # Non-mutating `composite!` on a copy.
    def composite(src : Image, x : Int = 0, y : Int = 0, blend : Blend = Blend::Normal,
                  opacity : Float64 = 1.0) : Image
      dup.composite!(src, x, y, blend, opacity)
    end

    @[AlwaysInline]
    private def blend_channel(mode : Blend, s : Int32, d : Int32) : Int32
      case mode
      in Blend::Normal   then s
      in Blend::Multiply then Immagini.div255(s &* d)
      in Blend::Screen   then s &+ d &- Immagini.div255(s &* d)
      in Blend::Overlay
        d < 128 ? Immagini.div255(2 &* s &* d) : 255 &- Immagini.div255(2 &* (255 &- s) &* (255 &- d))
      in Blend::Darken     then Math.min(s, d)
      in Blend::Lighten    then Math.max(s, d)
      in Blend::Add        then Math.min(s &+ d, 255)
      in Blend::Difference then (s &- d).abs
      end
    end
  end
end
