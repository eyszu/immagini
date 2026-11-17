module Immagini
  module Codecs
    module JPEG
      def self.decode(data : Bytes) : Image
        Decoder.new(data).decode
      end

      # Reads just the dimensions without decoding pixels.
      def self.dimensions(data : Bytes) : {Int32, Int32}
        Decoder.new(data).dimensions
      end

      # Canonical Huffman decoding table with a 9-bit direct lookup.
      private class HuffTable
        getter fast : Slice(UInt16)   # (code length << 8) | symbol, 0 = not a short code
        getter maxcode : Slice(Int32) # largest code of each length, -1 if none
        getter mincode : Slice(Int32)
        getter valptr : Slice(Int32)
        getter vals : Bytes

        def initialize(counts : Bytes, @vals : Bytes)
          total = 0
          counts.each { |c| total += c.to_i32 }
          raise DecodeError.new("bad JPEG Huffman table") if total > 256 || total != @vals.size
          @fast = Slice(UInt16).new(512)
          @maxcode = Slice(Int32).new(18, -1)
          @mincode = Slice(Int32).new(18)
          @valptr = Slice(Int32).new(18)
          code = 0
          k = 0
          (1..16).each do |l|
            n = counts[l - 1].to_i32
            @valptr[l] = k
            @mincode[l] = code
            if n > 0
              raise DecodeError.new("oversubscribed JPEG Huffman table") if code + n > (1 << l)
              if l <= 9
                n.times do |i|
                  lo = (code + i) << (9 - l)
                  entry = ((l << 8) | @vals[k + i].to_i32).to_u16
                  (1 << (9 - l)).times { |j| @fast[lo + j] = entry }
                end
              end
              @maxcode[l] = code + n - 1
            end
            code += n
            k += n
            code <<= 1
          end
        end
      end

      # MSB-first bit reader over entropy-coded data. Handles 0xFF00 byte
      # stuffing, stops at markers (feeding zero bits), and tracks whether the
      # decoder consumed bits it had to invent (a truncated scan).
      private class BitReader
        getter pos : Int32
        getter bits : UInt64 = 0_u64
        getter n : Int32 = 0
        @pad_bits = 0
        @marker_hit = false

        def initialize(@data : Bytes, @pos : Int32)
        end

        def truncated? : Bool
          @n < @pad_bits
        end

        def fill : Nil
          while @n <= 56
            byte = 0_u64
            if @marker_hit || @pos >= @data.size
              @pad_bits += 8
            else
              b = @data.unsafe_fetch(@pos)
              if b == 0xFF_u8
                nb = @pos + 1 < @data.size ? @data.unsafe_fetch(@pos + 1) : 0xD9_u8
                if nb == 0_u8
                  @pos += 2
                  byte = 0xFF_u64
                elsif nb == 0xFF_u8
                  @pos += 1
                  next
                else
                  @marker_hit = true
                  @pad_bits += 8
                end
              else
                @pos += 1
                byte = b.to_u64
              end
            end
            @bits |= byte << (56 - @n)
            @n += 8
          end
        end

        @[AlwaysInline]
        def peek(count : Int32) : Int32
          (@bits >> (64 - count)).to_i32!
        end

        @[AlwaysInline]
        def skip(count : Int32) : Nil
          @bits <<= count
          @n -= count
        end

        # Reads `count` (0..16) bits as an unsigned integer.
        @[AlwaysInline]
        def receive(count : Int32) : Int32
          return 0 if count == 0
          fill if @n < count
          v = (@bits >> (64 - count)).to_i32!
          skip(count)
          v
        end

        # Drops buffered bits and consumes the next RSTn marker.
        def restart : Nil
          raise DecodeError.new("truncated JPEG data") if truncated?
          @bits = 0_u64
          @n = 0
          @pad_bits = 0
          p = @pos
          while p + 1 < @data.size
            if @data[p] == 0xFF_u8
              m = @data[p + 1]
              if m >= 0xD0_u8 && m <= 0xD7_u8
                @pos = p + 2
                @marker_hit = false
                return
              end
              raise DecodeError.new("missing JPEG restart marker") unless m == 0_u8 || m == 0xFF_u8
            end
            p += 1
          end
          raise DecodeError.new("missing JPEG restart marker")
        end
      end

      private class Component
        property id = 0
        property h = 1
        property v = 1
        property tq = 0
        property dc_table = 0
        property ac_table = 0
        property pred = 0
        property comp_w = 0 # real (unpadded) sample width/height
        property comp_h = 0
        property stride = 0
        property plane : Bytes = Bytes.empty
      end

      # Constants of the integer IDCT (scaled by 1 << 12).
      C_0_5411961    =   2217
      C_M1_847759065 =  -7567
      C_0_765366865  =   3135
      C_1_175875602  =   4816
      C_0_298631336  =   1223
      C_2_053119869  =   8410
      C_3_072711026  =  12586
      C_1_501321110  =   6149
      C_M0_899976223 =  -3685
      C_M2_562915447 = -10497
      C_M1_961570560 =  -8034
      C_M0_390180644 =  -1597

      private class Decoder
        @qt = Array(Slice(Int32)?).new(4, nil)
        @dc = Array(HuffTable?).new(4, nil)
        @ac = Array(HuffTable?).new(4, nil)
        @components = [] of Component
        @width = 0
        @height = 0
        @hmax = 1
        @vmax = 1
        @mcus_x = 0
        @mcus_y = 0
        @restart = 0
        @adobe = -1
        @frame = false
        @scans = 0
        @zz : Pointer(Int32)

        def initialize(@data : Bytes)
          @zz = ZIGZAG.to_unsafe
        end

        def dimensions : {Int32, Int32}
          walk_markers(stop_at_sof: true)
          raise DecodeError.new("JPEG has no frame header") unless @frame
          {@width, @height}
        end

        def decode : Image
          walk_markers(stop_at_sof: false)
          raise DecodeError.new("JPEG has no frame header") unless @frame
          raise DecodeError.new("JPEG has no image data") if @scans == 0
          build_image
        end

        private def u16(d : Bytes, i : Int32) : Int32
          (d[i].to_i32 << 8) | d[i + 1].to_i32
        end

        private def walk_markers(stop_at_sof : Bool) : Nil
          unless @data.size > 3 && @data[0] == 0xFF && @data[1] == 0xD8
            raise DecodeError.new("not a JPEG file")
          end
          pos = 2
          while true
            pos = find_marker(pos)
            break if pos < 0
            m = @data[pos + 1]
            pos += 2
            case m
            when 0xD8, 0x01, 0xD0, 0xD1, 0xD2, 0xD3, 0xD4, 0xD5, 0xD6, 0xD7
              next
            when 0xD9
              break
            end

            raise DecodeError.new("truncated JPEG data") if pos + 2 > @data.size
            len = u16(@data, pos)
            raise DecodeError.new("bad JPEG segment length") if len < 2 || pos + len > @data.size
            seg = @data[pos + 2, len - 2]

            case m
            when 0xC0, 0xC1
              parse_sof(seg)
              return if stop_at_sof
            when 0xC2, 0xC6, 0xCA, 0xCE
              raise UnsupportedError.new("progressive JPEG is not supported")
            when 0xC3, 0xC5, 0xC7, 0xC9, 0xCB, 0xCD, 0xCF
              raise UnsupportedError.new("lossless/arithmetic-coded JPEG is not supported")
            when 0xC4
              parse_dht(seg)
            when 0xDB
              parse_dqt(seg)
            when 0xDD
              raise DecodeError.new("bad DRI segment") if seg.size < 2
              @restart = u16(seg, 0)
            when 0xEE
              if seg.size >= 12 && seg[0, 5] == "Adobe".to_slice
                @adobe = seg[11].to_i32
              end
            when 0xDA
              raise DecodeError.new("JPEG scan before frame header") unless @frame
              pos = parse_sos(seg, pos + len)
              next
            end
            pos += len
          end
        end

        # Returns the index of the next 0xFF that starts a real marker, or -1.
        private def find_marker(pos : Int32) : Int32
          while pos + 1 < @data.size
            if @data[pos] == 0xFF
              c = @data[pos + 1]
              if c != 0 && c != 0xFF
                return pos
              end
              pos += c == 0xFF ? 1 : 2
            else
              pos += 1
            end
          end
          -1
        end

        private def parse_sof(seg : Bytes) : Nil
          raise DecodeError.new("duplicate JPEG frame header") if @frame
          raise DecodeError.new("bad SOF segment") if seg.size < 6
          raise UnsupportedError.new("only 8-bit JPEG is supported") unless seg[0] == 8
          @height = u16(seg, 1)
          @width = u16(seg, 3)
          nc = seg[5].to_i32
          raise DecodeError.new("JPEG with zero dimension") if @width == 0 || @height == 0
          unless Image.valid_dimensions?(@width, @height)
            raise DecodeError.new("JPEG too large")
          end
          raise UnsupportedError.new("CMYK/YCCK JPEG is not supported") if nc == 4
          raise DecodeError.new("unsupported JPEG component count #{nc}") unless nc == 1 || nc == 3
          raise DecodeError.new("bad SOF segment") if seg.size < 6 + 3 * nc

          nc.times do |i|
            c = Component.new
            c.id = seg[6 + i * 3].to_i32
            hv = seg[7 + i * 3].to_i32
            c.h = hv >> 4
            c.v = hv & 15
            c.tq = seg[8 + i * 3].to_i32
            raise DecodeError.new("bad JPEG sampling factors") if c.h < 1 || c.h > 4 || c.v < 1 || c.v > 4
            raise DecodeError.new("bad JPEG quantization table id") if c.tq > 3
            @components << c
          end
          @hmax = @components.max_of(&.h)
          @vmax = @components.max_of(&.v)
          mcu_w = 8 * @hmax
          mcu_h = 8 * @vmax
          @mcus_x = (@width + mcu_w - 1) // mcu_w
          @mcus_y = (@height + mcu_h - 1) // mcu_h
          @components.each do |c|
            c.stride = @mcus_x * c.h * 8
            rows = @mcus_y * c.v * 8
            raise DecodeError.new("JPEG too large") if c.stride.to_i64 * rows > Int32::MAX
            c.plane = Bytes.new(c.stride * rows)
            c.comp_w = (@width * c.h + @hmax - 1) // @hmax
            c.comp_h = (@height * c.v + @vmax - 1) // @vmax
          end
          @frame = true
        end

        private def parse_dqt(seg : Bytes) : Nil
          i = 0
          while i < seg.size
            pq = seg[i] >> 4
            tq = (seg[i] & 15).to_i32
            i += 1
            raise DecodeError.new("bad JPEG quantization table id") if tq > 3 || pq > 1
            need = pq == 0 ? 64 : 128
            raise DecodeError.new("truncated DQT segment") if i + need > seg.size
            t = Slice(Int32).new(64)
            64.times { |k| t[k] = pq == 0 ? seg[i + k].to_i32 : u16(seg, i + k * 2) }
            @qt[tq] = t
            i += need
          end
        end

        private def parse_dht(seg : Bytes) : Nil
          i = 0
          while i < seg.size
            raise DecodeError.new("truncated DHT segment") if i + 17 > seg.size
            tc = seg[i] >> 4
            th = (seg[i] & 15).to_i32
            raise DecodeError.new("bad JPEG Huffman table id") if tc > 1 || th > 3
            counts = seg[i + 1, 16]
            total = 0
            counts.each { |c| total += c.to_i32 }
            raise DecodeError.new("truncated DHT segment") if i + 17 + total > seg.size
            table = HuffTable.new(counts, seg[i + 17, total])
            if tc == 0
              @dc[th] = table
            else
              @ac[th] = table
            end
            i += 17 + total
          end
        end

        # Decodes one scan and returns the position just after its entropy data.
        private def parse_sos(seg : Bytes, entropy_start : Int32) : Int32
          raise DecodeError.new("bad SOS segment") if seg.size < 1
          ns = seg[0].to_i32
          raise DecodeError.new("bad SOS segment") if ns < 1 || ns > @components.size || seg.size < 4 + 2 * ns
          scan = [] of Component
          ns.times do |i|
            id = seg[1 + i * 2].to_i32
            comp = @components.find { |c| c.id == id } || raise DecodeError.new("SOS references unknown component")
            tbl = seg[2 + i * 2].to_i32
            comp.dc_table = tbl >> 4
            comp.ac_table = tbl & 15
            raise DecodeError.new("bad JPEG Huffman table id") if comp.dc_table > 3 || comp.ac_table > 3
            scan << comp
          end
          ss = seg[1 + ns * 2]
          se = seg[2 + ns * 2]
          ahal = seg[3 + ns * 2]
          unless ss == 0 && se == 63 && ahal == 0
            raise UnsupportedError.new("progressive/spectral-selection JPEG is not supported")
          end

          br = BitReader.new(@data, entropy_start)
          decode_scan(br, scan)
          raise DecodeError.new("truncated JPEG data") if br.truncated?
          @scans += 1
          br.pos
        end

        private def decode_scan(br : BitReader, comps : Array(Component)) : Nil
          comps.each do |c|
            raise DecodeError.new("JPEG missing quantization table") unless @qt[c.tq]
            raise DecodeError.new("JPEG missing DC Huffman table") unless @dc[c.dc_table]
            raise DecodeError.new("JPEG missing AC Huffman table") unless @ac[c.ac_table]
            c.pred = 0
          end

          coef_buf = Slice(Int32).new(64)
          coef = coef_buf.to_unsafe
          count = 0

          if comps.size > 1
            @mcus_y.times do |my|
              @mcus_x.times do |mx|
                if @restart > 0 && count > 0 && count % @restart == 0
                  br.restart
                  comps.each { |c| c.pred = 0 }
                end
                comps.each do |c|
                  dc = @dc[c.dc_table].not_nil!
                  ac = @ac[c.ac_table].not_nil!
                  q = @qt[c.tq].not_nil!.to_unsafe
                  c.v.times do |by|
                    c.h.times do |bx|
                      dst = c.plane.to_unsafe + (my * c.v + by) * 8 * c.stride + (mx * c.h + bx) * 8
                      decode_block(br, c, dc, ac, q, coef, dst)
                    end
                  end
                end
                count += 1
              end
            end
          else
            c = comps[0]
            dc = @dc[c.dc_table].not_nil!
            ac = @ac[c.ac_table].not_nil!
            q = @qt[c.tq].not_nil!.to_unsafe
            bw = (c.comp_w + 7) // 8
            bh = (c.comp_h + 7) // 8
            bh.times do |by|
              bw.times do |bx|
                if @restart > 0 && count > 0 && count % @restart == 0
                  br.restart
                  c.pred = 0
                end
                dst = c.plane.to_unsafe + by * 8 * c.stride + bx * 8
                decode_block(br, c, dc, ac, q, coef, dst)
                count += 1
              end
            end
          end
        end

        @[AlwaysInline]
        private def decode_huff(br : BitReader, t : HuffTable) : Int32
          br.fill if br.n < 32
          e = t.fast.unsafe_fetch(br.peek(9))
          if e != 0
            br.skip((e >> 8).to_i32)
            return (e & 0xFF).to_i32
          end
          l = 10
          while l <= 16
            code = br.peek(l)
            if code <= t.maxcode.unsafe_fetch(l)
              br.skip(l)
              return t.vals.unsafe_fetch(t.valptr.unsafe_fetch(l) + code - t.mincode.unsafe_fetch(l)).to_i32
            end
            l += 1
          end
          raise DecodeError.new("corrupt JPEG Huffman data")
        end

        @[AlwaysInline]
        private def sign_extend(v : Int32, t : Int32) : Int32
          v < (1 << (t - 1)) ? v - (1 << t) + 1 : v
        end

        private def decode_block(br : BitReader, c : Component, dc : HuffTable, ac : HuffTable,
                                 q : Pointer(Int32), coef : Pointer(Int32), dst : Pointer(UInt8)) : Nil
          coef.clear(64)
          t = decode_huff(br, dc)
          raise DecodeError.new("corrupt JPEG DC coefficient") if t > 15
          diff = t == 0 ? 0 : sign_extend(br.receive(t), t)
          c.pred = c.pred &+ diff
          coef[0] = c.pred &* q[0]

          zz = @zz
          k = 1
          while k < 64
            rs = decode_huff(br, ac)
            s = rs & 15
            r = rs >> 4
            if s == 0
              break if r != 15
              k += 16
            else
              k += r
              raise DecodeError.new("corrupt JPEG AC coefficient") if k > 63
              coef[zz[k]] = sign_extend(br.receive(s), s) &* q[k]
              k += 1
            end
          end
          idct(coef, dst, c.stride)
        end

        # One 8-point 1-D IDCT (jidctint-style, 12-bit fixed point). Returns the
        # eight outputs in order, each biased by `bias` before the caller shifts.
        @[AlwaysInline]
        private def idct_1d(s0 : Int32, s1 : Int32, s2 : Int32, s3 : Int32,
                            s4 : Int32, s5 : Int32, s6 : Int32, s7 : Int32, bias : Int32)
          p2 = s2
          p3 = s6
          p1 = (p2 &+ p3) &* C_0_5411961
          t2 = p1 &+ p3 &* C_M1_847759065
          t3 = p1 &+ p2 &* C_0_765366865
          p2 = s0
          p3 = s4
          t0 = (p2 &+ p3) &* 4096
          t1 = (p2 &- p3) &* 4096
          x0 = t0 &+ t3 &+ bias
          x3 = t0 &- t3 &+ bias
          x1 = t1 &+ t2 &+ bias
          x2 = t1 &- t2 &+ bias
          t0 = s7
          t1 = s5
          t2 = s3
          t3 = s1
          p3 = t0 &+ t2
          p4 = t1 &+ t3
          p1 = t0 &+ t3
          p2 = t1 &+ t2
          p5 = (p3 &+ p4) &* C_1_175875602
          t0 = t0 &* C_0_298631336
          t1 = t1 &* C_2_053119869
          t2 = t2 &* C_3_072711026
          t3 = t3 &* C_1_501321110
          p1 = p5 &+ p1 &* C_M0_899976223
          p2 = p5 &+ p2 &* C_M2_562915447
          p3 = p3 &* C_M1_961570560
          p4 = p4 &* C_M0_390180644
          t3 = t3 &+ p1 &+ p4
          t2 = t2 &+ p2 &+ p3
          t1 = t1 &+ p2 &+ p4
          t0 = t0 &+ p1 &+ p3
          {x0 &+ t3, x1 &+ t2, x2 &+ t1, x3 &+ t0, x3 &- t0, x2 &- t1, x1 &- t2, x0 &- t3}
        end

        # 2-D IDCT of dequantized coefficients (natural order) into 8x8 samples.
        private def idct(d : Pointer(Int32), out_ptr : Pointer(UInt8), stride : Int32) : Nil
          tmp = uninitialized StaticArray(Int32, 64)
          v = tmp.to_unsafe

          8.times do |i|
            col = d + i
            if col[8] == 0 && col[16] == 0 && col[24] == 0 && col[32] == 0 &&
               col[40] == 0 && col[48] == 0 && col[56] == 0
              dcterm = col[0] &* 4
              8.times { |r| v[r * 8 + i] = dcterm }
            else
              a, b, c, e, f, g, h, j = idct_1d(col[0], col[8], col[16], col[24], col[32], col[40], col[48], col[56], 512)
              v[i] = a >> 10
              v[8 + i] = b >> 10
              v[16 + i] = c >> 10
              v[24 + i] = e >> 10
              v[32 + i] = f >> 10
              v[40 + i] = g >> 10
              v[48 + i] = h >> 10
              v[56 + i] = j >> 10
            end
          end

          bias = 65536 &+ (128 << 17)
          8.times do |i|
            row = v + i * 8
            o = out_ptr + i * stride
            a, b, c, e, f, g, h, j = idct_1d(row[0], row[1], row[2], row[3], row[4], row[5], row[6], row[7], bias)
            o[0] = Immagini.clamp_u8(a >> 17)
            o[1] = Immagini.clamp_u8(b >> 17)
            o[2] = Immagini.clamp_u8(c >> 17)
            o[3] = Immagini.clamp_u8(e >> 17)
            o[4] = Immagini.clamp_u8(f >> 17)
            o[5] = Immagini.clamp_u8(g >> 17)
            o[6] = Immagini.clamp_u8(h >> 17)
            o[7] = Immagini.clamp_u8(j >> 17)
          end
        end

        # --------------------------------------------------------------
        # Upsampling and color conversion
        # --------------------------------------------------------------

        # A component plane brought to full image resolution: {bytes, stride}.
        private def full_plane(c : Component) : {Bytes, Int32}
          return {c.plane, c.stride} if c.h == @hmax && c.v == @vmax

          w = @width
          h = @height
          result = Bytes.new(w * h)
          src = c.plane.to_unsafe
          cw = c.comp_w
          ch = c.comp_h
          sx2 = @hmax == 2 * c.h
          sy2 = @vmax == 2 * c.v
          sx1 = @hmax == c.h
          sy1 = @vmax == c.v

          if sx2 && sy1
            h.times do |y|
              s = src + y * c.stride
              d = result.to_unsafe + y * w
              ((w + 1) // 2).times do |i|
                near = s[i].to_i32
                left = s[i > 0 ? i - 1 : 0].to_i32
                right = s[i + 1 < cw ? i + 1 : cw - 1].to_i32
                d[2 * i] = ((3 * near + left + 1) >> 2).to_u8!
                d[2 * i + 1] = ((3 * near + right + 2) >> 2).to_u8! if 2 * i + 1 < w
              end
            end
          elsif sx1 && sy2
            h.times do |y|
              cy = y >> 1
              fy = (y & 1) == 0 ? (cy > 0 ? cy - 1 : 0) : (cy + 1 < ch ? cy + 1 : ch - 1)
              bias = (y & 1) == 0 ? 1 : 2
              near = src + cy * c.stride
              far = src + fy * c.stride
              d = result.to_unsafe + y * w
              w.times { |x| d[x] = ((3 * near[x].to_i32 + far[x].to_i32 + bias) >> 2).to_u8! }
            end
          elsif sx2 && sy2
            sums = Slice(Int32).new(cw)
            h.times do |y|
              cy = y >> 1
              fy = (y & 1) == 0 ? (cy > 0 ? cy - 1 : 0) : (cy + 1 < ch ? cy + 1 : ch - 1)
              near = src + cy * c.stride
              far = src + fy * c.stride
              cw.times { |i| sums[i] = 3 * near[i].to_i32 + far[i].to_i32 }
              d = result.to_unsafe + y * w
              ((w + 1) // 2).times do |i|
                this = sums[i]
                last = sums[i > 0 ? i - 1 : 0]
                nxt = sums[i + 1 < cw ? i + 1 : cw - 1]
                d[2 * i] = ((3 * this + last + 8) >> 4).to_u8!
                d[2 * i + 1] = ((3 * this + nxt + 7) >> 4).to_u8! if 2 * i + 1 < w
              end
            end
          else
            # Arbitrary ratios: nearest neighbour.
            xmap = Slice(Int32).new(w) { |x| x * c.h // @hmax }
            h.times do |y|
              s = src + (y * c.v // @vmax) * c.stride
              d = result.to_unsafe + y * w
              w.times { |x| d[x] = s[xmap[x]] }
            end
          end
          {result, w}
        end

        private def build_image : Image
          w = @width
          h = @height
          result = Bytes.new(w * h * 4)
          op = result.to_unsafe

          if @components.size == 1
            p, stride = full_plane(@components[0])
            pp = p.to_unsafe
            h.times do |y|
              s = pp + y * stride
              d = op + y * w * 4
              w.times do |x|
                v = s[x]
                d[0] = v
                d[1] = v
                d[2] = v
                d[3] = 255_u8
                d += 4
              end
            end
            return Image.new(w, h, result)
          end

          y_plane, y_stride = full_plane(@components[0])
          cb_plane, cb_stride = full_plane(@components[1])
          cr_plane, cr_stride = full_plane(@components[2])
          yp = y_plane.to_unsafe
          cbp = cb_plane.to_unsafe
          crp = cr_plane.to_unsafe

          rgb = @adobe == 0 ||
                (@adobe < 0 && @components[0].id == 'R'.ord && @components[1].id == 'G'.ord && @components[2].id == 'B'.ord)

          Parallel.bands(h, 64) do |y0, y1|
            (y0...y1).each do |y|
              ys = yp + y * y_stride
              cbs = cbp + y * cb_stride
              crs = crp + y * cr_stride
              d = op + y * w * 4
              if rgb
                w.times do |x|
                  d[0] = ys[x]
                  d[1] = cbs[x]
                  d[2] = crs[x]
                  d[3] = 255_u8
                  d += 4
                end
              else
                w.times do |x|
                  yy = ys[x].to_i32
                  cb = cbs[x].to_i32 - 128
                  cr = crs[x].to_i32 - 128
                  d[0] = Immagini.clamp_u8(yy &+ ((91881 &* cr &+ 32768) >> 16))
                  d[1] = Immagini.clamp_u8(yy &- ((22554 &* cb &+ 46802 &* cr &+ 32768) >> 16))
                  d[2] = Immagini.clamp_u8(yy &+ ((116130 &* cb &+ 32768) >> 16))
                  d[3] = 255_u8
                  d += 4
                end
              end
            end
          end
          Image.new(w, h, result)
        end
      end
    end
  end
end
