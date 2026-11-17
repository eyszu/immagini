require "compress/zlib"
require "digest/crc32"

module Immagini
  module Codecs
    # PNG codec. Decoding supports every standard color type and bit depth
    # (1/2/4/8/16-bit gray, RGB, palette, gray+alpha, RGBA), tRNS transparency
    # and Adam7 interlacing. 16-bit samples are reduced to 8 bits. Gamma and
    # ICC chunks are ignored.
    #
    # Encoding writes 8-bit gray, gray+alpha, RGB or RGBA, picking the smallest
    # layout that represents the image losslessly.
    module PNG
      SIGNATURE = Bytes[137_u8, 80_u8, 78_u8, 71_u8, 13_u8, 10_u8, 26_u8, 10_u8]

      T_IHDR = 0x49484452_u32
      T_PLTE = 0x504C5445_u32
      T_IDAT = 0x49444154_u32
      T_IEND = 0x49454E44_u32
      T_TRNS = 0x74524E53_u32

      # Per-row prediction filter used when encoding.
      enum Filter
        None
        Sub
        Up
        Average
        Paeth
        # Tries all five per row and keeps the one with the smallest sum of
        # absolute residuals (libpng's heuristic).
        Adaptive
      end

      # Adam7 pass geometry: x start, y start, x step, y step.
      ADAM7_X0 = {0, 4, 0, 2, 0, 1, 0}
      ADAM7_Y0 = {0, 0, 4, 0, 2, 0, 1}
      ADAM7_DX = {8, 8, 4, 4, 2, 2, 1}
      ADAM7_DY = {8, 8, 8, 4, 4, 2, 2}

      # ------------------------------------------------------------------
      # Decoder
      # ------------------------------------------------------------------

      def self.decode(data : Bytes) : Image
        unless data.size >= 8 && data[0, 8] == SIGNATURE
          raise DecodeError.new("not a PNG file")
        end

        pos = 8
        width = height = depth = ctype = interlace = 0
        have_ihdr = false
        palette = Bytes.new(256 * 4)
        256.times { |i| palette[i * 4 + 3] = 255_u8 }
        trns : Bytes? = nil
        idat = IO::Memory.new

        while pos + 12 <= data.size
          len = be32(data, pos).to_i64
          type = be32(data, pos + 4)
          body = pos + 8
          if body.to_i64 + len + 4 > data.size
            raise DecodeError.new("truncated PNG chunk")
          end
          len = len.to_i32

          if type == T_IHDR || type == T_PLTE || type == T_IDAT
            crc = Digest::CRC32.checksum(data[pos + 4, len + 4])
            raise DecodeError.new("PNG chunk CRC mismatch") unless crc == be32(data, body + len)
          end

          case type
          when T_IHDR
            raise DecodeError.new("bad IHDR length") unless len == 13
            width = be32(data, body).to_i64
            height = be32(data, body + 4).to_i64
            raise DecodeError.new("invalid PNG dimensions") unless Image.valid_dimensions?(width, height)
            width = width.to_i32
            height = height.to_i32
            depth = data[body + 8].to_i32
            ctype = data[body + 9].to_i32
            interlace = data[body + 12].to_i32
            raise UnsupportedError.new("unknown PNG compression/filter method") unless data[body + 10] == 0 && data[body + 11] == 0
            raise DecodeError.new("bad PNG interlace method") unless interlace == 0 || interlace == 1
            valid = case ctype
                    when 0       then {1, 2, 4, 8, 16}.includes?(depth)
                    when 3       then {1, 2, 4, 8}.includes?(depth)
                    when 2, 4, 6 then depth == 8 || depth == 16
                    else              false
                    end
            raise DecodeError.new("invalid PNG color type #{ctype} / depth #{depth}") unless valid
            have_ihdr = true
          when T_PLTE
            raise DecodeError.new("bad PLTE length") if len % 3 != 0 || len > 768
            (len // 3).times do |i|
              palette[i * 4] = data[body + i * 3]
              palette[i * 4 + 1] = data[body + i * 3 + 1]
              palette[i * 4 + 2] = data[body + i * 3 + 2]
            end
          when T_TRNS
            trns = data[body, len]
          when T_IDAT
            raise DecodeError.new("IDAT before IHDR") unless have_ihdr
            idat.write(data[body, len])
          when T_IEND
            break
          end
          pos = body + len + 4
        end

        raise DecodeError.new("missing IHDR") unless have_ihdr
        raise DecodeError.new("missing image data") if idat.size == 0

        if ctype == 3 && (t = trns)
          Math.min(t.size, 256).times { |i| palette[i * 4 + 3] = t[i] }
        end

        channels = case ctype
                   when 0, 3 then 1
                   when 2    then 3
                   when 4    then 2
                   else           4
                   end
        bits_pp = channels * depth
        bpp = (bits_pp + 7) // 8

        # Size of the decompressed stream.
        raw_size = 0_i64
        if interlace == 0
          raw_size = ((width.to_i64 * bits_pp + 7) // 8 + 1) * height
        else
          7.times do |p|
            pw, ph = pass_size(p, width, height)
            next if pw == 0 || ph == 0
            raw_size += ((pw.to_i64 * bits_pp + 7) // 8 + 1) * ph
          end
        end
        raise DecodeError.new("PNG image too large") if raw_size > Int32::MAX

        raw = Bytes.new(raw_size.to_i32)
        begin
          Compress::Zlib::Reader.open(IO::Memory.new(idat.to_slice)) do |z|
            z.read_fully(raw)
          end
        rescue IO::EOFError
          raise DecodeError.new("truncated PNG image data")
        rescue ex : Compress::Zlib::Error | Compress::Deflate::Error
          raise DecodeError.new("corrupt PNG image data: #{ex.message}")
        end

        result = Bytes.new(width * height * 4)
        ex = Expander.new(ctype, depth, palette, trns)
        rp = raw.to_unsafe
        op = result.to_unsafe

        if interlace == 0
          row_bytes = (width * bits_pp + 7) // 8
          unfilter(rp, height, row_bytes, bpp)
          height.times do |y|
            ex.row(rp + y * (row_bytes + 1) + 1, width, op + y * width * 4, 4)
          end
        else
          offset = 0
          7.times do |p|
            pw, ph = pass_size(p, width, height)
            next if pw == 0 || ph == 0
            row_bytes = (pw * bits_pp + 7) // 8
            base = rp + offset
            unfilter(base, ph, row_bytes, bpp)
            ph.times do |r|
              y = ADAM7_Y0[p] + r * ADAM7_DY[p]
              ex.row(base + r * (row_bytes + 1) + 1, pw,
                op + (y * width + ADAM7_X0[p]) * 4, ADAM7_DX[p] * 4)
            end
            offset += (row_bytes + 1) * ph
          end
        end

        Image.new(width, height, result)
      end

      # Reads just the dimensions without decoding pixels.
      def self.dimensions(data : Bytes) : {Int32, Int32}
        unless data.size >= 24 && data[0, 8] == SIGNATURE && be32(data, 12) == T_IHDR
          raise DecodeError.new("not a PNG file")
        end
        {be32(data, 16).to_i32, be32(data, 20).to_i32}
      end

      private def self.pass_size(p : Int32, width : Int32, height : Int32) : {Int32, Int32}
        x0, y0, dx, dy = ADAM7_X0[p], ADAM7_Y0[p], ADAM7_DX[p], ADAM7_DY[p]
        pw = width > x0 ? (width - x0 + dx - 1) // dx : 0
        ph = height > y0 ? (height - y0 + dy - 1) // dy : 0
        {pw, ph}
      end

      @[AlwaysInline]
      private def self.be32(d : Bytes, i : Int32) : UInt32
        (d[i].to_u32 << 24) | (d[i + 1].to_u32 << 16) | (d[i + 2].to_u32 << 8) | d[i + 3].to_u32
      end

      @[AlwaysInline]
      private def self.paeth(a : Int32, b : Int32, c : Int32) : Int32
        p = a &+ b &- c
        pa = (p &- a).abs
        pb = (p &- b).abs
        pc = (p &- c).abs
        pa <= pb && pa <= pc ? a : (pb <= pc ? b : c)
      end

      # Reverses the per-row filters in place. Each row is `1 + row_bytes`
      # bytes: a filter-type byte followed by the filtered data.
      private def self.unfilter(buf : Pointer(UInt8), rows : Int32, row_bytes : Int32, bpp : Int32) : Nil
        zero = Bytes.new(row_bytes)
        prev = zero.to_unsafe
        stride = row_bytes + 1
        rows.times do |r|
          line = buf + r * stride
          type = line[0]
          cur = line + 1
          case type
          when 0
            # none
          when 1 # Sub
            i = bpp
            while i < row_bytes
              cur[i] = cur[i] &+ cur[i - bpp]
              i += 1
            end
          when 2 # Up
            i = 0
            while i < row_bytes
              cur[i] = cur[i] &+ prev[i]
              i += 1
            end
          when 3 # Average
            i = 0
            while i < bpp && i < row_bytes
              cur[i] = cur[i] &+ (prev[i] >> 1)
              i += 1
            end
            while i < row_bytes
              cur[i] = cur[i] &+ ((cur[i - bpp].to_i32 &+ prev[i].to_i32) >> 1).to_u8!
              i += 1
            end
          when 4 # Paeth
            i = 0
            while i < bpp && i < row_bytes
              cur[i] = cur[i] &+ prev[i]
              i += 1
            end
            while i < row_bytes
              cur[i] = cur[i] &+ paeth(cur[i - bpp].to_i32, prev[i].to_i32, prev[i - bpp].to_i32).to_u8!
              i += 1
            end
          else
            raise DecodeError.new("invalid PNG filter type #{type}")
          end
          prev = cur
        end
      end

      # Converts unfiltered scanlines of any color type/depth to RGBA8.
      private class Expander
        @tg = -1 # tRNS gray key (raw sample value)
        @tr = -1
        @tb = -1
        @tgg = -1

        def initialize(@ctype : Int32, @depth : Int32, @palette : Bytes, trns : Bytes?)
          if t = trns
            if @ctype == 0 && t.size >= 2
              @tg = (t[0].to_i32 << 8) | t[1].to_i32
            elsif @ctype == 2 && t.size >= 6
              @tr = (t[0].to_i32 << 8) | t[1].to_i32
              @tgg = (t[2].to_i32 << 8) | t[3].to_i32
              @tb = (t[4].to_i32 << 8) | t[5].to_i32
            end
          end
        end

        # Expands `n` pixels from `src` into `dst`, advancing `step` bytes per pixel.
        def row(src : Pointer(UInt8), n : Int32, dst : Pointer(UInt8), step : Int32) : Nil
          case @ctype
          when 6
            if @depth == 8
              if step == 4
                dst.copy_from(src, n * 4)
              else
                n.times do
                  dst[0] = src[0]
                  dst[1] = src[1]
                  dst[2] = src[2]
                  dst[3] = src[3]
                  src += 4
                  dst += step
                end
              end
            else
              n.times do
                dst[0] = src[0]
                dst[1] = src[2]
                dst[2] = src[4]
                dst[3] = src[6]
                src += 8
                dst += step
              end
            end
          when 2
            if @depth == 8
              keyed = @tr >= 0
              n.times do
                dst[0] = src[0]
                dst[1] = src[1]
                dst[2] = src[2]
                dst[3] = (keyed && src[0].to_i32 == @tr && src[1].to_i32 == @tgg && src[2].to_i32 == @tb) ? 0_u8 : 255_u8
                src += 3
                dst += step
              end
            else
              keyed = @tr >= 0
              n.times do
                dst[0] = src[0]
                dst[1] = src[2]
                dst[2] = src[4]
                if keyed && ((src[0].to_i32 << 8) | src[1].to_i32) == @tr &&
                   ((src[2].to_i32 << 8) | src[3].to_i32) == @tgg &&
                   ((src[4].to_i32 << 8) | src[5].to_i32) == @tb
                  dst[3] = 0_u8
                else
                  dst[3] = 255_u8
                end
                src += 6
                dst += step
              end
            end
          when 4
            if @depth == 8
              n.times do
                v = src[0]
                dst[0] = v
                dst[1] = v
                dst[2] = v
                dst[3] = src[1]
                src += 2
                dst += step
              end
            else
              n.times do
                v = src[0]
                dst[0] = v
                dst[1] = v
                dst[2] = v
                dst[3] = src[2]
                src += 4
                dst += step
              end
            end
          when 0
            gray_row(src, n, dst, step)
          else # 3, palette
            pal = @palette.to_unsafe
            if @depth == 8
              n.times do
                (dst).copy_from(pal + src.value.to_i32 * 4, 4)
                src += 1
                dst += step
              end
            else
              mask = (1 << @depth) - 1
              n.times do |i|
                bit = i * @depth
                idx = (src[bit >> 3].to_i32 >> (8 - @depth - (bit & 7))) & mask
                dst.copy_from(pal + idx * 4, 4)
                dst += step
              end
            end
          end
        end

        private def gray_row(src : Pointer(UInt8), n : Int32, dst : Pointer(UInt8), step : Int32) : Nil
          case @depth
          when 8
            n.times do
              v = src.value
              dst[0] = v
              dst[1] = v
              dst[2] = v
              dst[3] = @tg == v.to_i32 ? 0_u8 : 255_u8
              src += 1
              dst += step
            end
          when 16
            n.times do
              v = src[0]
              raw = (src[0].to_i32 << 8) | src[1].to_i32
              dst[0] = v
              dst[1] = v
              dst[2] = v
              dst[3] = @tg == raw ? 0_u8 : 255_u8
              src += 2
              dst += step
            end
          else
            mask = (1 << @depth) - 1
            scale = 255 // mask
            n.times do |i|
              bit = i * @depth
              raw = (src[bit >> 3].to_i32 >> (8 - @depth - (bit & 7))) & mask
              v = (raw * scale).to_u8!
              dst[0] = v
              dst[1] = v
              dst[2] = v
              dst[3] = @tg == raw ? 0_u8 : 255_u8
              dst += step
            end
          end
        end
      end

      # ------------------------------------------------------------------
      # Encoder
      # ------------------------------------------------------------------

      def self.encode(img : Image, io : IO, compression : Int32 = 6, filter : Filter = Filter::Adaptive) : Nil
        unless 0 <= compression <= 9
          raise ArgumentError.new("PNG compression must be 0..9, got #{compression}")
        end
        w = img.width
        h = img.height

        # Choose the narrowest lossless layout.
        opaque = true
        gray = true
        p = img.pixels.to_unsafe
        (w * h).times do
          opaque = false if p[3] != 255_u8
          gray = false if p[0] != p[1] || p[1] != p[2]
          break if !opaque && !gray
          p += 4
        end
        ctype, channels = if gray && opaque
                            {0, 1}
                          elsif gray
                            {4, 2}
                          elsif opaque
                            {2, 3}
                          else
                            {6, 4}
                          end

        io.write(SIGNATURE)
        ihdr = Bytes.new(13)
        IO::ByteFormat::BigEndian.encode(w.to_u32, ihdr[0, 4])
        IO::ByteFormat::BigEndian.encode(h.to_u32, ihdr[4, 4])
        ihdr[8] = 8_u8
        ihdr[9] = ctype.to_u8
        write_chunk(io, T_IHDR, ihdr)

        idat = IDATWriter.new(io)
        z = Compress::Zlib::Writer.new(idat, level: compression)

        row_bytes = w * channels
        bpp = channels
        cur_buf = Bytes.new(row_bytes)
        prev_buf = Bytes.new(row_bytes)
        cur = cur_buf.to_unsafe
        prev = prev_buf.to_unsafe
        cand = Array.new(5) { Bytes.new(row_bytes + 1) }
        cand_ptr = cand.map(&.to_unsafe)

        h.times do |y|
          pack_row(img.row_ptr(y), w, ctype, cur)
          if filter == Filter::Adaptive
            best = 0
            best_cost = Int64::MAX
            5.times do |t|
              apply_filter(t, cur, prev, row_bytes, bpp, cand_ptr[t])
              cost = filter_cost(cand_ptr[t] + 1, row_bytes, best_cost)
              if cost < best_cost
                best_cost = cost
                best = t
              end
            end
            z.write(cand[best])
          else
            t = filter.value
            apply_filter(t, cur, prev, row_bytes, bpp, cand_ptr[0])
            z.write(cand[0])
          end
          cur, prev = prev, cur
        end

        z.close
        idat.finish
        write_chunk(io, T_IEND, Bytes.empty)
      end

      # Packs one RGBA row into the chosen channel layout.
      private def self.pack_row(src : Pointer(UInt8), w : Int32, ctype : Int32, dst : Pointer(UInt8)) : Nil
        case ctype
        when 6
          dst.copy_from(src, w * 4)
        when 2
          w.times do
            dst[0] = src[0]
            dst[1] = src[1]
            dst[2] = src[2]
            src += 4
            dst += 3
          end
        when 0
          w.times do
            dst.value = src[0]
            src += 4
            dst += 1
          end
        else # 4
          w.times do
            dst[0] = src[0]
            dst[1] = src[3]
            src += 4
            dst += 2
          end
        end
      end

      # Writes `[type, filtered row...]` into `dst`.
      private def self.apply_filter(type : Int32, cur : Pointer(UInt8), prev : Pointer(UInt8),
                                    n : Int32, bpp : Int32, dst : Pointer(UInt8)) : Nil
        dst[0] = type.to_u8
        d = dst + 1
        case type
        when 0
          d.copy_from(cur, n)
        when 1
          i = 0
          while i < n
            d[i] = i < bpp ? cur[i] : cur[i] &- cur[i - bpp]
            i += 1
          end
        when 2
          i = 0
          while i < n
            d[i] = cur[i] &- prev[i]
            i += 1
          end
        when 3
          i = 0
          while i < n
            if i < bpp
              d[i] = cur[i] &- (prev[i] >> 1)
            else
              d[i] = cur[i] &- ((cur[i - bpp].to_i32 &+ prev[i].to_i32) >> 1).to_u8!
            end
            i += 1
          end
        else
          i = 0
          while i < n
            if i < bpp
              d[i] = cur[i] &- prev[i]
            else
              d[i] = cur[i] &- paeth(cur[i - bpp].to_i32, prev[i].to_i32, prev[i - bpp].to_i32).to_u8!
            end
            i += 1
          end
        end
      end

      # Sum of residuals taken as signed bytes; bails out early once `limit` is exceeded.
      private def self.filter_cost(d : Pointer(UInt8), n : Int32, limit : Int64) : Int64
        sum = 0_i64
        i = 0
        while i < n
          v = d[i].to_i32
          sum &+= v < 128 ? v : 256 &- v
          return sum if sum >= limit
          i += 1
        end
        sum
      end

      protected def self.write_chunk(io : IO, type : UInt32, data : Bytes) : Nil
        tb = Bytes.new(4)
        IO::ByteFormat::BigEndian.encode(type, tb)
        io.write_bytes(data.size.to_u32, IO::ByteFormat::BigEndian)
        io.write(tb)
        io.write(data)
        # zlib's crc32() returns 0 for a NULL buffer, so an empty chunk body
        # (IEND) must not go through `update`.
        crc = Digest::CRC32.checksum(tb)
        crc = Digest::CRC32.update(data, crc) unless data.empty?
        io.write_bytes(crc, IO::ByteFormat::BigEndian)
      end

      # Buffers compressed output and emits it as fixed-size IDAT chunks.
      private class IDATWriter < IO
        CHUNK = 1 << 17

        def initialize(@io : IO)
          @buf = Bytes.new(CHUNK)
          @len = 0
        end

        def read(slice : Bytes) : NoReturn
          raise IO::Error.new("write-only IO")
        end

        def write(slice : Bytes) : Nil
          src = slice
          while src.size > 0
            n = Math.min(CHUNK - @len, src.size)
            (@buf.to_unsafe + @len).copy_from(src.to_unsafe, n)
            @len += n
            src = src[n..]
            emit if @len == CHUNK
          end
        end

        def finish : Nil
          emit if @len > 0
        end

        private def emit : Nil
          PNG.write_chunk(@io, T_IDAT, @buf[0, @len])
          @len = 0
        end
      end
    end
  end
end
