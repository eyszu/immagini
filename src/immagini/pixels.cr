module Immagini
  # Low-level helpers that work directly on RGBA8 memory.
  module Pixels
    # True when every alpha byte in `count` pixels is 255.
    def self.opaque?(ptr : Pointer(UInt8), count : Int32) : Bool
      p = ptr + 3
      i = 0
      while i < count
        return false if p.value != 255_u8
        p += 4
        i += 1
      end
      true
    end

    # c = round(c * a / 255) for every pixel.
    def self.premultiply!(ptr : Pointer(UInt8), count : Int32) : Nil
      p = ptr
      i = 0
      while i < count
        a = p[3].to_i32
        if a != 255
          p[0] = Immagini.div255(p[0].to_i32 &* a).to_u8!
          p[1] = Immagini.div255(p[1].to_i32 &* a).to_u8!
          p[2] = Immagini.div255(p[2].to_i32 &* a).to_u8!
        end
        p += 4
        i += 1
      end
    end

    # Inverse of `premultiply!` (transparent pixels become 0,0,0,0).
    def self.unpremultiply!(ptr : Pointer(UInt8), count : Int32) : Nil
      p = ptr
      i = 0
      while i < count
        a = p[3].to_i32
        if a == 0
          p[0] = 0_u8
          p[1] = 0_u8
          p[2] = 0_u8
        elsif a != 255
          h = a >> 1
          p[0] = Math.min((p[0].to_i32 &* 255 &+ h) // a, 255).to_u8!
          p[1] = Math.min((p[1].to_i32 &* 255 &+ h) // a, 255).to_u8!
          p[2] = Math.min((p[2].to_i32 &* 255 &+ h) // a, 255).to_u8!
        end
        p += 4
        i += 1
      end
    end

    # Fixed-point 1-D kernel: integer taps that sum to exactly `1 << bits`.
    # `weights` are normalised to sum 1 first (the input array is not modified).
    def self.quantize_kernel(weights : Array(Float64), bits : Int32) : Array(Int32)
      sum = weights.sum
      one = 1 << bits
      result = weights.map { |w| ((sum != 0 ? w / sum : w) * one).round.to_i32 }
      # put the rounding residual on the tap with the largest magnitude so a
      # flat region is reproduced exactly
      residual = one - result.sum
      if residual != 0
        big = 0
        result.each_with_index { |v, i| big = i if v.abs > result[big].abs }
        result[big] += residual
      end
      result
    end
  end
end
