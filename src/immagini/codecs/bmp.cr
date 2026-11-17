module Immagini
  module Codecs
    # Windows BMP codec.
    #
    # Decoding: 1/4/8-bit palette, 16-bit (555 or bit-fields), 24-bit and
    # 32-bit (BI_RGB or BI_BITFIELDS with optional alpha), bottom-up or
    # top-down, OS/2 core and BITMAPINFO/V4/V5 headers. RLE compression is not
    # supported.
    #
    # Encoding: 24-bit BI_RGB for opaque images; 32-bit BGRA with a V4 header
    # (alpha bit-field) when any pixel is translucent.
    module BMP
      private def self.u16(d : Bytes, i : Int32) : Int32
        d[i].to_i32 | (d[i + 1].to_i32 << 8)
      end

      private def self.u32(d : Bytes, i : Int32) : UInt32
        d[i].to_u32 | (d[i + 1].to_u32 << 8) | (d[i + 2].to_u32 << 16) | (d[i + 3].to_u32 << 24)
      end

      private def self.i32(d : Bytes, i : Int32) : Int32
        u32(d, i).to_i32!
      end

      def self.decode(data : Bytes) : Image
        raise DecodeError.new("not a BMP file") unless data.size >= 26 && data[0] == 'B'.ord && data[1] == 'M'.ord

        data_offset = u32(data, 10).to_i64
        hsize_raw = u32(data, 14)
        raise DecodeError.new("unsupported BMP header size #{hsize_raw}") if hsize_raw > data.size
        hsize = hsize_raw.to_i32
        core = hsize == 12
        raise DecodeError.new("unsupported BMP header size #{hsize}") unless core || hsize >= 40
        raise DecodeError.new("truncated BMP header") if data.size < 14 + hsize

        if core
          width = u16(data, 18)
          height = u16(data, 20)
          bpp = u16(data, 24)
          compression = 0_u32
          colors_used = 0
        else
          width = i32(data, 18)
          height = i32(data, 22)
          bpp = u16(data, 28)
          compression = u32(data, 30)
          colors_used = u32(data, 46).to_i32!
        end

        top_down = height < 0
        raise DecodeError.new("invalid BMP dimensions") if height == Int32::MIN || width == Int32::MIN
        height = -height if top_down
        unless Image.valid_dimensions?(width, height)
          raise DecodeError.new("invalid BMP dimensions #{width}x#{height}")
        end
        raise UnsupportedError.new("RLE-compressed BMP is not supported") if compression == 1 || compression == 2
        unless {0_u32, 3_u32, 6_u32}.includes?(compression)
          raise UnsupportedError.new("unsupported BMP compression #{compression}")
        end
        unless {1, 4, 8, 16, 24, 32}.includes?(bpp)
          raise DecodeError.new("unsupported BMP bit depth #{bpp}")
        end

        # Channel masks for 16/32-bit.
        rmask = gmask = bmask = amask = 0_u32
        if compression == 3 || compression == 6
          if hsize >= 52
            rmask, gmask, bmask = u32(data, 54), u32(data, 58), u32(data, 62)
            amask = u32(data, 66) if hsize >= 56
          elsif data.size >= 14 + hsize + 12
            rmask, gmask, bmask = u32(data, 14 + hsize), u32(data, 18 + hsize), u32(data, 22 + hsize)
            amask = u32(data, 26 + hsize) if compression == 6 && data.size >= 14 + hsize + 16
          end
        elsif bpp == 16
          rmask, gmask, bmask = 0x7C00_u32, 0x03E0_u32, 0x001F_u32
        elsif bpp == 32
          rmask, gmask, bmask = 0x00FF0000_u32, 0x0000FF00_u32, 0x000000FF_u32
        end

        # Palette (BGRX quads, or BGR triples for OS/2 core).
        palette = Bytes.new(256 * 4)
        if bpp <= 8
          n = colors_used > 0 ? colors_used : (1 << bpp)
          n = Math.min(n, 1 << bpp)
          pos = 14 + hsize
          entry = core ? 3 : 4
          raise DecodeError.new("truncated BMP palette") if pos + n * entry > data.size
          n.times do |i|
            palette[i * 4] = data[pos + i * entry + 2]
            palette[i * 4 + 1] = data[pos + i * entry + 1]
            palette[i * 4 + 2] = data[pos + i * entry]
            palette[i * 4 + 3] = 255_u8
          end
        end

        stride = ((width.to_i64 * bpp + 31) // 32 * 4)
        if data_offset + stride * height > data.size
          raise DecodeError.new("truncated BMP pixel data")
        end

        result = Bytes.new(width * height * 4)
        op = result.to_unsafe
        dp = data.to_unsafe

        # Pre-compute mask shifts/scales for bit-field formats.
        has_alpha_mask = amask != 0
        rs, rn = mask_info(rmask)
        gs, gn = mask_info(gmask)
        bs, bn = mask_info(bmask)
        as_, an = mask_info(amask)

        # 32-bit BI_RGB has no declared alpha: the 4th byte is "reserved", but
        # many writers fill it in. Use it only if some pixel has it non-zero.
        implicit_alpha = false
        if bpp == 32 && !has_alpha_mask && compression == 0
          height.times do |row|
            q = dp + data_offset + row.to_i64 * stride + 3
            width.times do
              if q.value != 0_u8
                implicit_alpha = true
                break
              end
              q += 4
            end
            break if implicit_alpha
          end
        end

        height.times do |row|
          y = top_down ? row : height - 1 - row
          src = dp + data_offset + row.to_i64 * stride
          dst = op + y * width * 4
          case bpp
          when 24
            width.times do
              dst[0] = src[2]
              dst[1] = src[1]
              dst[2] = src[0]
              dst[3] = 255_u8
              src += 3
              dst += 4
            end
          when 32
            if rmask == 0x00FF0000_u32 && gmask == 0x0000FF00_u32 && bmask == 0x000000FF_u32
              width.times do
                dst[0] = src[2]
                dst[1] = src[1]
                dst[2] = src[0]
                dst[3] = ((has_alpha_mask && amask == 0xFF000000_u32) || implicit_alpha) ? src[3] : 255_u8
                src += 4
                dst += 4
              end
            else
              width.times do
                v = src[0].to_u32 | (src[1].to_u32 << 8) | (src[2].to_u32 << 16) | (src[3].to_u32 << 24)
                dst[0] = extract(v, rmask, rs, rn)
                dst[1] = extract(v, gmask, gs, gn)
                dst[2] = extract(v, bmask, bs, bn)
                dst[3] = has_alpha_mask ? extract(v, amask, as_, an) : 255_u8
                src += 4
                dst += 4
              end
            end
          when 16
            width.times do
              v = src[0].to_u32 | (src[1].to_u32 << 8)
              dst[0] = extract(v, rmask, rs, rn)
              dst[1] = extract(v, gmask, gs, gn)
              dst[2] = extract(v, bmask, bs, bn)
              dst[3] = has_alpha_mask ? extract(v, amask, as_, an) : 255_u8
              src += 2
              dst += 4
            end
          else # 1, 4, 8
            pal = palette.to_unsafe
            mask = (1 << bpp) - 1
            width.times do |x|
              bit = x * bpp
              idx = (src[bit >> 3].to_i32 >> (8 - bpp - (bit & 7))) & mask
              dst.copy_from(pal + idx * 4, 4)
              dst += 4
            end
          end
        end

        Image.new(width, height, result)
      end

      private def self.mask_info(mask : UInt32) : {Int32, Int32}
        return {0, 0} if mask == 0
        shift = mask.trailing_zeros_count.to_i32
        bits = (~(mask >> shift)).trailing_zeros_count.to_i32
        {shift, bits}
      end

      @[AlwaysInline]
      private def self.extract(v : UInt32, mask : UInt32, shift : Int32, bits : Int32) : UInt8
        return 0_u8 if bits == 0
        x = ((v & mask) >> shift).to_i32
        return x.to_u8! if bits == 8
        (x * 255 // ((1 << bits) - 1)).to_u8!
      end

      def self.encode(img : Image, io : IO, background : Color = Color::WHITE) : Nil
        w = img.width
        h = img.height
        alpha = !img.opaque?
        bpp = alpha ? 32 : 24
        hsize = alpha ? 108 : 40
        stride = (w * bpp + 31) // 32 * 4
        offset = 14 + hsize
        file_size = offset.to_i64 + stride.to_i64 * h
        raise ArgumentError.new("image too large for BMP") if file_size > UInt32::MAX

        hdr = IO::Memory.new(offset)
        hdr.write("BM".to_slice)
        {file_size.to_u32, 0_u32, offset.to_u32, hsize.to_u32}.each { |v| hdr.write_bytes(v, IO::ByteFormat::LittleEndian) }
        hdr.write_bytes(w, IO::ByteFormat::LittleEndian)
        hdr.write_bytes(h, IO::ByteFormat::LittleEndian) # positive = bottom-up
        hdr.write_bytes(1_u16, IO::ByteFormat::LittleEndian)
        hdr.write_bytes(bpp.to_u16, IO::ByteFormat::LittleEndian)
        hdr.write_bytes(alpha ? 3_u32 : 0_u32, IO::ByteFormat::LittleEndian)
        hdr.write_bytes((stride.to_i64 * h).to_u32, IO::ByteFormat::LittleEndian)
        hdr.write_bytes(2835_i32, IO::ByteFormat::LittleEndian) # 72 dpi
        hdr.write_bytes(2835_i32, IO::ByteFormat::LittleEndian)
        hdr.write_bytes(0_u32, IO::ByteFormat::LittleEndian)
        hdr.write_bytes(0_u32, IO::ByteFormat::LittleEndian)
        if alpha
          {0x00FF0000_u32, 0x0000FF00_u32, 0x000000FF_u32, 0xFF000000_u32}.each do |m|
            hdr.write_bytes(m, IO::ByteFormat::LittleEndian)
          end
          hdr.write_bytes(0x73524742_u32, IO::ByteFormat::LittleEndian) # 'sRGB'
          (108 - 40 - 20).times { hdr.write_byte(0_u8) }                # endpoints + gamma
        end
        io.write(hdr.to_slice)

        row = Bytes.new(stride)
        rp = row.to_unsafe
        h.times do |r|
          src = img.row_ptr(h - 1 - r)
          d = rp
          if alpha
            w.times do
              d[0] = src[2]
              d[1] = src[1]
              d[2] = src[0]
              d[3] = src[3]
              src += 4
              d += 4
            end
          else
            w.times do
              d[0] = src[2]
              d[1] = src[1]
              d[2] = src[0]
              src += 4
              d += 3
            end
          end
          io.write(row)
        end
      end
    end
  end
end
