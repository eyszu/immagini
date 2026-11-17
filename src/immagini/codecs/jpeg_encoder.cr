module Immagini
  module Codecs
    module JPEG
      # Encodes `img` as baseline JPEG. Transparent pixels must already have
      # been flattened (the public `Image#write`/`Image#save` do it).
      def self.encode(img : Image, io : IO, quality : Int32 = 90,
                      subsampling : Subsampling = Subsampling::S420,
                      background : Color = Color::WHITE) : Nil
        unless 1 <= quality <= 100
          raise ArgumentError.new("JPEG quality must be 1..100, got #{quality}")
        end
        if img.width > 65535 || img.height > 65535
          raise ArgumentError.new("JPEG dimensions are limited to 65535x65535")
        end
        src = img.opaque? ? img : img.flatten(background)
        Encoder.new(src, quality, subsampling).write(io)
      end

      # Codes for the Huffman encoder: per symbol, the code and its bit length.
      private class HuffCodes
        getter codes : Slice(UInt32)
        getter sizes : Slice(UInt8)

        def initialize(bits : Array(UInt8), vals : Array(UInt8))
          @codes = Slice(UInt32).new(256)
          @sizes = Slice(UInt8).new(256)
          code = 0_u32
          k = 0
          16.times do |l|
            bits[l].times do
              sym = vals[k]
              @codes[sym] = code
              @sizes[sym] = (l + 1).to_u8
              code += 1
              k += 1
            end
            code <<= 1
          end
        end
      end

      # Buffered bit sink that applies 0xFF byte stuffing.
      private class BitWriter
        def initialize(@io : IO)
          @buf = Bytes.new(1 << 16)
          @len = 0
          @acc = 0_u64
          @nbits = 0
        end

        @[AlwaysInline]
        def put(code : UInt32, size : Int32) : Nil
          return if size == 0
          @acc = (@acc << size) | code.to_u64
          @nbits += size
          while @nbits >= 8
            b = ((@acc >> (@nbits - 8)) & 0xFF).to_u8!
            @buf[@len] = b
            @len += 1
            if b == 0xFF_u8
              @buf[@len] = 0_u8
              @len += 1
            end
            @nbits -= 8
          end
          flush_buffer if @len >= @buf.size - 4
        end

        # Pads the last byte with 1-bits.
        def align : Nil
          put(((1_u32 << (8 - @nbits)) - 1), 8 - @nbits) if @nbits > 0
        end

        def flush_buffer : Nil
          @io.write(@buf[0, @len])
          @len = 0
        end

        def raw(bytes : Bytes) : Nil
          flush_buffer
          @io.write(bytes)
        end
      end

      private class Encoder
        # AAN scale factors for the float DCT.
        AAN = [1.0, 1.387039845, 1.306562965, 1.175875602, 1.0, 0.785694958, 0.541196100, 0.275899379]

        @lq : Array(Int32)
        @cq : Array(Int32)
        @lrecip : Slice(Float32)
        @crecip : Slice(Float32)
        @gray : Bool
        @hmax : Int32
        @vmax : Int32
        @dc_luma : HuffCodes
        @ac_luma : HuffCodes
        @dc_chroma : HuffCodes
        @ac_chroma : HuffCodes
        @zz : Pointer(Int32)
        @blk : Slice(Float32)
        @qv : Slice(Int32)

        def initialize(@img : Image, quality : Int32, @sub : Subsampling)
          scale = quality < 50 ? 5000 // quality : 200 - quality * 2
          @lq = STD_LUMA_Q.map { |v| ((v * scale + 50) // 100).clamp(1, 255) }
          @cq = STD_CHROMA_Q.map { |v| ((v * scale + 50) // 100).clamp(1, 255) }
          @lrecip = recip(@lq)
          @crecip = recip(@cq)
          @gray = @sub.gray?
          @hmax = @sub.s422? || @sub.s420? ? 2 : 1
          @vmax = @sub.s420? ? 2 : 1
          @dc_luma = HuffCodes.new(DC_LUMA_BITS, DC_LUMA_VALS)
          @ac_luma = HuffCodes.new(AC_LUMA_BITS, AC_LUMA_VALS)
          @dc_chroma = HuffCodes.new(DC_CHROMA_BITS, DC_CHROMA_VALS)
          @ac_chroma = HuffCodes.new(AC_CHROMA_BITS, AC_CHROMA_VALS)
          @zz = ZIGZAG.to_unsafe
          @blk = Slice(Float32).new(64)
          @qv = Slice(Int32).new(64)
        end

        # Reciprocal of (quant * AAN scale * 8), natural order, as floats.
        private def recip(q : Array(Int32)) : Slice(Float32)
          r = Slice(Float32).new(64)
          8.times do |row|
            8.times do |col|
              i = row * 8 + col
              r[i] = (1.0 / (q[i] * AAN[row] * AAN[col] * 8.0)).to_f32
            end
          end
          r
        end

        def write(io : IO) : Nil
          w = @img.width
          h = @img.height
          result = BitWriter.new(io)
          write_headers(result, w, h)

          mcu_w = 8 * @hmax
          mcu_h = 8 * @vmax
          mcus_x = (w + mcu_w - 1) // mcu_w
          mcus_y = (h + mcu_h - 1) // mcu_h
          pw = mcus_x * mcu_w
          cw = pw // @hmax

          y_strip = Bytes.new(pw * mcu_h)
          cb_strip = Bytes.new(@gray ? 0 : pw * mcu_h)
          cr_strip = Bytes.new(@gray ? 0 : pw * mcu_h)
          cb_small = Bytes.new(@gray ? 0 : cw * 8)
          cr_small = Bytes.new(@gray ? 0 : cw * 8)
          pred_y = pred_cb = pred_cr = 0

          mcus_y.times do |my|
            convert_strip(my * mcu_h, mcu_h, pw, y_strip, cb_strip, cr_strip)
            downsample(cb_strip, cb_small, pw, cw, mcu_h) unless @gray
            downsample(cr_strip, cr_small, pw, cw, mcu_h) unless @gray

            mcus_x.times do |mx|
              @vmax.times do |by|
                @hmax.times do |bx|
                  src = y_strip.to_unsafe + by * 8 * pw + (mx * mcu_w + bx * 8)
                  pred_y = encode_block(result, src, pw, @lrecip, pred_y, @dc_luma, @ac_luma)
                end
              end
              unless @gray
                pred_cb = encode_block(result, cb_small.to_unsafe + mx * 8, cw, @crecip, pred_cb, @dc_chroma, @ac_chroma)
                pred_cr = encode_block(result, cr_small.to_unsafe + mx * 8, cw, @crecip, pred_cr, @dc_chroma, @ac_chroma)
              end
            end
          end

          result.align
          result.flush_buffer
          result.raw(Bytes[0xFF_u8, 0xD9_u8])
        end

        private def marker(result : BitWriter, m : UInt8, payload : Bytes) : Nil
          hdr = Bytes[0xFF_u8, m, ((payload.size + 2) >> 8).to_u8, ((payload.size + 2) & 0xFF).to_u8]
          result.raw(hdr)
          result.raw(payload)
        end

        private def write_headers(result : BitWriter, w : Int32, h : Int32) : Nil
          result.raw(Bytes[0xFF_u8, 0xD8_u8])
          # JFIF APP0: version 1.01, aspect ratio 1:1, no thumbnail.
          marker(result, 0xE0_u8, Bytes[0x4A, 0x46, 0x49, 0x46, 0x00, 0x01, 0x01, 0x00, 0x00, 0x01, 0x00, 0x01, 0x00, 0x00])

          qt = IO::Memory.new
          [{0, @lq}, {1, @cq}].each do |(id, table)|
            next if @gray && id == 1
            qt.write_byte(id.to_u8)
            64.times { |i| qt.write_byte(table[ZIGZAG[i]].to_u8) }
          end
          marker(result, 0xDB_u8, qt.to_slice)

          nc = @gray ? 1 : 3
          sof = IO::Memory.new
          sof.write_byte(8_u8)
          sof.write_bytes(h.to_u16, IO::ByteFormat::BigEndian)
          sof.write_bytes(w.to_u16, IO::ByteFormat::BigEndian)
          sof.write_byte(nc.to_u8)
          sof.write_byte(1_u8)
          sof.write_byte(((@hmax << 4) | @vmax).to_u8)
          sof.write_byte(0_u8)
          unless @gray
            {2, 3}.each do |id|
              sof.write_byte(id.to_u8)
              sof.write_byte(0x11_u8)
              sof.write_byte(1_u8)
            end
          end
          marker(result, 0xC0_u8, sof.to_slice)

          dht = IO::Memory.new
          tables = [{0x00, DC_LUMA_BITS, DC_LUMA_VALS}, {0x10, AC_LUMA_BITS, AC_LUMA_VALS}]
          tables += [{0x01, DC_CHROMA_BITS, DC_CHROMA_VALS}, {0x11, AC_CHROMA_BITS, AC_CHROMA_VALS}] unless @gray
          tables.each do |(id, bits, vals)|
            dht.write_byte(id.to_u8)
            bits.each { |b| dht.write_byte(b) }
            vals.each { |v| dht.write_byte(v) }
          end
          marker(result, 0xC4_u8, dht.to_slice)

          sos = IO::Memory.new
          sos.write_byte(nc.to_u8)
          sos.write_byte(1_u8)
          sos.write_byte(0x00_u8)
          unless @gray
            {2, 3}.each do |id|
              sos.write_byte(id.to_u8)
              sos.write_byte(0x11_u8)
            end
          end
          sos.write_byte(0_u8)
          sos.write_byte(63_u8)
          sos.write_byte(0_u8)
          marker(result, 0xDA_u8, sos.to_slice)
        end

        # RGB -> YCbCr for `rows` image rows starting at `y0`. Samples past the
        # right/bottom edge replicate the nearest real pixel.
        private def convert_strip(y0 : Int32, rows : Int32, pw : Int32,
                                  ys : Bytes, cbs : Bytes, crs : Bytes) : Nil
          w = @img.width
          h = @img.height
          rows.times do |r|
            sy = Math.min(y0 + r, h - 1)
            s = @img.row_ptr(sy)
            yo = ys.to_unsafe + r * pw
            if @gray
              pw.times do |x|
                p = s + Math.min(x, w - 1) * 4
                yo[x] = ((p[0].to_i32 &* 19595 &+ p[1].to_i32 &* 38470 &+ p[2].to_i32 &* 7471 &+ 32768) >> 16).to_u8!
              end
            else
              cbo = cbs.to_unsafe + r * pw
              cro = crs.to_unsafe + r * pw
              pw.times do |x|
                p = s + Math.min(x, w - 1) * 4
                rr = p[0].to_i32
                gg = p[1].to_i32
                bb = p[2].to_i32
                yo[x] = ((rr &* 19595 &+ gg &* 38470 &+ bb &* 7471 &+ 32768) >> 16).to_u8!
                cbo[x] = Immagini.clamp_u8((-11059 &* rr &- 21709 &* gg &+ 32768 &* bb &+ 8421376) >> 16)
                cro[x] = Immagini.clamp_u8((32768 &* rr &- 27439 &* gg &- 5329 &* bb &+ 8421376) >> 16)
              end
            end
          end
        end

        # Box-filters a full-resolution chroma strip down by (hmax, vmax).
        private def downsample(src : Bytes, dst : Bytes, pw : Int32, cw : Int32, rows : Int32) : Nil
          hs = @hmax
          vs = @vmax
          area = hs * vs
          half = area // 2
          (rows // vs).times do |cy|
            d = dst.to_unsafe + cy * cw
            cw.times do |cx|
              sum = 0
              vs.times do |dy|
                s = src.to_unsafe + (cy * vs + dy) * pw + cx * hs
                hs.times { |dx| sum &+= s[dx].to_i32 }
              end
              d[cx] = ((sum &+ half) // area).to_u8!
            end
          end
        end

        # Forward 8x8 DCT (AAN, float) of the block at `src`, quantized and
        # Huffman-coded. Returns the new DC predictor.
        private def encode_block(result : BitWriter, src : Pointer(UInt8), stride : Int32,
                                 recip : Slice(Float32), pred : Int32,
                                 dc : HuffCodes, ac : HuffCodes) : Int32
          d = @blk.to_unsafe
          8.times do |r|
            s = src + r * stride
            o = d + r * 8
            8.times { |c| o[c] = s[c].to_f32 - 128.0_f32 }
          end
          fdct(d)

          q = @qv.to_unsafe
          rp = recip.to_unsafe
          64.times do |i|
            q[i] = (d[i] * rp[i] + 16384.5_f32).to_i32! - 16384
          end

          zz = @zz
          # DC
          diff = q[0] &- pred
          nbits = bit_length(diff < 0 ? -diff : diff)
          result.put(dc.codes.unsafe_fetch(nbits), dc.sizes.unsafe_fetch(nbits).to_i32)
          result.put((diff < 0 ? diff &- 1 : diff).to_u32! & ((1_u32 << nbits) - 1), nbits) if nbits > 0

          # AC
          run = 0
          k = 1
          while k < 64
            v = q[zz[k]]
            if v == 0
              run += 1
            else
              while run > 15
                result.put(ac.codes.unsafe_fetch(0xF0), ac.sizes.unsafe_fetch(0xF0).to_i32)
                run -= 16
              end
              nb = bit_length(v < 0 ? -v : v)
              sym = (run << 4) | nb
              result.put(ac.codes.unsafe_fetch(sym), ac.sizes.unsafe_fetch(sym).to_i32)
              result.put((v < 0 ? v &- 1 : v).to_u32! & ((1_u32 << nb) - 1), nb)
              run = 0
            end
            k += 1
          end
          result.put(ac.codes.unsafe_fetch(0), ac.sizes.unsafe_fetch(0).to_i32) if run > 0
          q[0]
        end

        @[AlwaysInline]
        private def bit_length(v : Int32) : Int32
          32 - v.leading_zeros_count
        end

        # In-place float AAN forward DCT (output scaled; undone by `recip`).
        private def fdct(d : Pointer(Float32)) : Nil
          2.times do |pass|
            step = pass == 0 ? 1 : 8 # element stride within a 1-D transform
            jump = pass == 0 ? 8 : 1 # distance between transforms
            8.times do |i|
              p = d + i * jump
              t0 = p[0] + p[7 * step]
              t7 = p[0] - p[7 * step]
              t1 = p[step] + p[6 * step]
              t6 = p[step] - p[6 * step]
              t2 = p[2 * step] + p[5 * step]
              t5 = p[2 * step] - p[5 * step]
              t3 = p[3 * step] + p[4 * step]
              t4 = p[3 * step] - p[4 * step]

              t10 = t0 + t3
              t13 = t0 - t3
              t11 = t1 + t2
              t12 = t1 - t2
              p[0] = t10 + t11
              p[4 * step] = t10 - t11
              z1 = (t12 + t13) * 0.707106781_f32
              p[2 * step] = t13 + z1
              p[6 * step] = t13 - z1

              t10 = t4 + t5
              t11 = t5 + t6
              t12 = t6 + t7
              z5 = (t10 - t12) * 0.382683433_f32
              z2 = 0.541196100_f32 * t10 + z5
              z4 = 1.306562965_f32 * t12 + z5
              z3 = t11 * 0.707106781_f32
              z11 = t7 + z3
              z13 = t7 - z3
              p[5 * step] = z13 + z2
              p[3 * step] = z13 - z2
              p[step] = z11 + z4
              p[7 * step] = z11 - z4
            end
          end
        end
      end
    end
  end
end
