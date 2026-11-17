module Immagini
  module Codecs
    # Netpbm codec: P1/P4 (bitmap), P2/P5 (graymap), P3/P6 (pixmap), with
    # `maxval` up to 65535 (scaled to 8 bits). Writes P6, or P5 when
    # `grayscale: true`. Alpha is not representable and is composited onto the
    # background color when writing.
    module PNM
      def self.decode(data : Bytes) : Image
        unless data.size >= 3 && data[0] == 'P'.ord && data[1] >= '1'.ord && data[1] <= '6'.ord
          raise DecodeError.new("not a PNM file")
        end
        kind = (data[1] - '0'.ord).to_i32
        pos = 2

        width, pos = read_int(data, pos)
        height, pos = read_int(data, pos)
        maxval = 1
        unless kind == 1 || kind == 4
          maxval, pos = read_int(data, pos)
          raise DecodeError.new("invalid PNM maxval #{maxval}") if maxval < 1 || maxval > 65535
        end
        unless Image.valid_dimensions?(width, height)
          raise DecodeError.new("invalid PNM dimensions #{width}x#{height}")
        end

        binary = kind >= 4
        pos += 1 if binary # exactly one whitespace byte follows the header
        result = Bytes.new(width * height * 4)
        op = result.to_unsafe
        n = width * height

        case kind
        when 4
          row_bytes = (width + 7) // 8
          raise DecodeError.new("truncated PNM data") if pos + row_bytes.to_i64 * height > data.size
          height.times do |y|
            width.times do |x|
              bit = (data[pos + y * row_bytes + (x >> 3)] >> (7 - (x & 7))) & 1
              v = bit == 1 ? 0_u8 : 255_u8 # 1 = black
              p = op + (y * width + x) * 4
              p[0] = v
              p[1] = v
              p[2] = v
              p[3] = 255_u8
            end
          end
        when 1
          n.times do |i|
            # P1 digits may be packed without separators.
            pos = skip_ws(data, pos)
            raise DecodeError.new("truncated PNM data") if pos >= data.size
            c = data[pos]
            raise DecodeError.new("invalid PNM bitmap digit") unless c == '0'.ord || c == '1'.ord
            pos += 1
            v = c == '1'.ord ? 0_u8 : 255_u8
            p = op + i * 4
            p[0] = v
            p[1] = v
            p[2] = v
            p[3] = 255_u8
          end
        else
          channels = (kind == 2 || kind == 5) ? 1 : 3
          wide = maxval > 255
          if binary
            need = n.to_i64 * channels * (wide ? 2 : 1)
            raise DecodeError.new("truncated PNM data") if pos + need > data.size
          end
          p = op
          n.times do
            3.times do |c|
              if c > 0 && channels == 1
                p[c] = p[0]
                next
              end
              v = 0
              if binary
                if wide
                  v = (data[pos].to_i32 << 8) | data[pos + 1].to_i32
                  pos += 2
                else
                  v = data[pos].to_i32
                  pos += 1
                end
              else
                v, pos = read_int(data, pos)
              end
              p[c] = scale(v, maxval)
            end
            p[3] = 255_u8
            p += 4
          end
        end

        Image.new(width, height, result)
      end

      private def self.scale(v : Int32, maxval : Int32) : UInt8
        return 255_u8 if v >= maxval
        maxval == 255 ? v.to_u8! : ((v * 255 + maxval // 2) // maxval).to_u8!
      end

      private def self.space?(c : UInt8) : Bool
        c == 32 || (c >= 9 && c <= 13)
      end

      # Skips whitespace and `#` comments (which run to end of line).
      private def self.skip_ws(d : Bytes, pos : Int32) : Int32
        while pos < d.size
          c = d[pos]
          if c == '#'.ord
            while pos < d.size && d[pos] != '\n'.ord && d[pos] != '\r'.ord
              pos += 1
            end
          elsif space?(c)
            pos += 1
          else
            break
          end
        end
        pos
      end

      # Reads a decimal integer, skipping whitespace and `#` comments.
      private def self.read_int(d : Bytes, pos : Int32) : {Int32, Int32}
        pos = skip_ws(d, pos)
        raise DecodeError.new("truncated PNM header") if pos >= d.size
        v = 0_i64
        digits = 0
        while pos < d.size && d[pos] >= '0'.ord && d[pos] <= '9'.ord
          v = v * 10 + (d[pos] - '0'.ord)
          raise DecodeError.new("PNM number too large") if v > Int32::MAX
          pos += 1
          digits += 1
        end
        raise DecodeError.new("invalid PNM number") if digits == 0
        {v.to_i32, pos}
      end

      def self.encode(img : Image, io : IO, grayscale : Bool = false, background : Color = Color::WHITE) : Nil
        src_img = img.opaque? ? img : img.flatten(background)
        w = src_img.width
        h = src_img.height
        io << (grayscale ? "P5" : "P6") << '\n' << w << ' ' << h << "\n255\n"
        if grayscale
          io.write(src_img.to_gray)
        else
          io.write(src_img.to_rgb)
        end
      end
    end
  end
end
