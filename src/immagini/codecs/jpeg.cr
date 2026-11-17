module Immagini
  module Codecs
    # Baseline JPEG codec (ITU T.81 sequential DCT, Huffman coding, 8-bit).
    #
    # Decoder: baseline and extended-sequential frames, 1 (gray) or 3
    # (YCbCr / Adobe RGB) components, any sampling factors, restart intervals,
    # interleaved and non-interleaved scans, "fancy" (triangle) chroma
    # upsampling for 2:1 ratios like libjpeg. Not supported: progressive,
    # lossless, arithmetic coding, 12-bit, CMYK/YCCK.
    #
    # Encoder: baseline, standard Annex K tables scaled by quality, optional
    # chroma subsampling (4:4:4, 4:2:2, 4:2:0) or grayscale, streaming per MCU
    # row so memory stays O(width).
    module JPEG
      enum Subsampling
        S444
        S422
        S420
        # One luma component only.
        Gray
      end

      # Zig-zag scan order: position in the coded stream -> natural (row-major) index.
      ZIGZAG = [
        0, 1, 8, 16, 9, 2, 3, 10,
        17, 24, 32, 25, 18, 11, 4, 5,
        12, 19, 26, 33, 40, 48, 41, 34,
        27, 20, 13, 6, 7, 14, 21, 28,
        35, 42, 49, 56, 57, 50, 43, 36,
        29, 22, 15, 23, 30, 37, 44, 51,
        58, 59, 52, 45, 38, 31, 39, 46,
        53, 60, 61, 54, 47, 55, 62, 63,
      ]

      # Annex K.1 quantization tables, natural order.
      STD_LUMA_Q = [
        16, 11, 10, 16, 24, 40, 51, 61,
        12, 12, 14, 19, 26, 58, 60, 55,
        14, 13, 16, 24, 40, 57, 69, 56,
        14, 17, 22, 29, 51, 87, 80, 62,
        18, 22, 37, 56, 68, 109, 103, 77,
        24, 35, 55, 64, 81, 104, 113, 92,
        49, 64, 78, 87, 103, 121, 120, 101,
        72, 92, 95, 98, 112, 100, 103, 99,
      ]

      STD_CHROMA_Q = [
        17, 18, 24, 47, 99, 99, 99, 99,
        18, 21, 26, 66, 99, 99, 99, 99,
        24, 26, 56, 99, 99, 99, 99, 99,
        47, 66, 99, 99, 99, 99, 99, 99,
        99, 99, 99, 99, 99, 99, 99, 99,
        99, 99, 99, 99, 99, 99, 99, 99,
        99, 99, 99, 99, 99, 99, 99, 99,
        99, 99, 99, 99, 99, 99, 99, 99,
      ]

      # Annex K.3 Huffman tables: code counts per length 1..16, then symbols.
      DC_LUMA_BITS   = [0, 1, 5, 1, 1, 1, 1, 1, 1, 0, 0, 0, 0, 0, 0, 0] of UInt8
      DC_LUMA_VALS   = (0..11).map(&.to_u8)
      DC_CHROMA_BITS = [0, 3, 1, 1, 1, 1, 1, 1, 1, 1, 1, 0, 0, 0, 0, 0] of UInt8
      DC_CHROMA_VALS = (0..11).map(&.to_u8)

      AC_LUMA_BITS = [0, 2, 1, 3, 3, 2, 4, 3, 5, 5, 4, 4, 0, 0, 1, 0x7d] of UInt8
      AC_LUMA_VALS = [
        0x01, 0x02, 0x03, 0x00, 0x04, 0x11, 0x05, 0x12,
        0x21, 0x31, 0x41, 0x06, 0x13, 0x51, 0x61, 0x07,
        0x22, 0x71, 0x14, 0x32, 0x81, 0x91, 0xa1, 0x08,
        0x23, 0x42, 0xb1, 0xc1, 0x15, 0x52, 0xd1, 0xf0,
        0x24, 0x33, 0x62, 0x72, 0x82, 0x09, 0x0a, 0x16,
        0x17, 0x18, 0x19, 0x1a, 0x25, 0x26, 0x27, 0x28,
        0x29, 0x2a, 0x34, 0x35, 0x36, 0x37, 0x38, 0x39,
        0x3a, 0x43, 0x44, 0x45, 0x46, 0x47, 0x48, 0x49,
        0x4a, 0x53, 0x54, 0x55, 0x56, 0x57, 0x58, 0x59,
        0x5a, 0x63, 0x64, 0x65, 0x66, 0x67, 0x68, 0x69,
        0x6a, 0x73, 0x74, 0x75, 0x76, 0x77, 0x78, 0x79,
        0x7a, 0x83, 0x84, 0x85, 0x86, 0x87, 0x88, 0x89,
        0x8a, 0x92, 0x93, 0x94, 0x95, 0x96, 0x97, 0x98,
        0x99, 0x9a, 0xa2, 0xa3, 0xa4, 0xa5, 0xa6, 0xa7,
        0xa8, 0xa9, 0xaa, 0xb2, 0xb3, 0xb4, 0xb5, 0xb6,
        0xb7, 0xb8, 0xb9, 0xba, 0xc2, 0xc3, 0xc4, 0xc5,
        0xc6, 0xc7, 0xc8, 0xc9, 0xca, 0xd2, 0xd3, 0xd4,
        0xd5, 0xd6, 0xd7, 0xd8, 0xd9, 0xda, 0xe1, 0xe2,
        0xe3, 0xe4, 0xe5, 0xe6, 0xe7, 0xe8, 0xe9, 0xea,
        0xf1, 0xf2, 0xf3, 0xf4, 0xf5, 0xf6, 0xf7, 0xf8,
        0xf9, 0xfa,
      ] of UInt8

      AC_CHROMA_BITS = [0, 2, 1, 2, 4, 4, 3, 4, 7, 5, 4, 4, 0, 1, 2, 0x77] of UInt8
      AC_CHROMA_VALS = [
        0x00, 0x01, 0x02, 0x03, 0x11, 0x04, 0x05, 0x21,
        0x31, 0x06, 0x12, 0x41, 0x51, 0x07, 0x61, 0x71,
        0x13, 0x22, 0x32, 0x81, 0x08, 0x14, 0x42, 0x91,
        0xa1, 0xb1, 0xc1, 0x09, 0x23, 0x33, 0x52, 0xf0,
        0x15, 0x62, 0x72, 0xd1, 0x0a, 0x16, 0x24, 0x34,
        0xe1, 0x25, 0xf1, 0x17, 0x18, 0x19, 0x1a, 0x26,
        0x27, 0x28, 0x29, 0x2a, 0x35, 0x36, 0x37, 0x38,
        0x39, 0x3a, 0x43, 0x44, 0x45, 0x46, 0x47, 0x48,
        0x49, 0x4a, 0x53, 0x54, 0x55, 0x56, 0x57, 0x58,
        0x59, 0x5a, 0x63, 0x64, 0x65, 0x66, 0x67, 0x68,
        0x69, 0x6a, 0x73, 0x74, 0x75, 0x76, 0x77, 0x78,
        0x79, 0x7a, 0x82, 0x83, 0x84, 0x85, 0x86, 0x87,
        0x88, 0x89, 0x8a, 0x92, 0x93, 0x94, 0x95, 0x96,
        0x97, 0x98, 0x99, 0x9a, 0xa2, 0xa3, 0xa4, 0xa5,
        0xa6, 0xa7, 0xa8, 0xa9, 0xaa, 0xb2, 0xb3, 0xb4,
        0xb5, 0xb6, 0xb7, 0xb8, 0xb9, 0xba, 0xc2, 0xc3,
        0xc4, 0xc5, 0xc6, 0xc7, 0xc8, 0xc9, 0xca, 0xd2,
        0xd3, 0xd4, 0xd5, 0xd6, 0xd7, 0xd8, 0xd9, 0xda,
        0xe2, 0xe3, 0xe4, 0xe5, 0xe6, 0xe7, 0xe8, 0xe9,
        0xea, 0xf2, 0xf3, 0xf4, 0xf5, 0xf6, 0xf7, 0xf8,
        0xf9, 0xfa,
      ] of UInt8

      # Reads the EXIF orientation tag (1..8) from a JPEG without decoding it.
      # Returns 1 (upright) when absent or malformed.
      def self.orientation(data : Bytes) : Int32
        return 1 unless data.size > 4 && data[0] == 0xFF && data[1] == 0xD8
        pos = 2
        while pos + 4 <= data.size
          break unless data[pos] == 0xFF
          m = data[pos + 1]
          if m == 0xFF
            pos += 1
            next
          end
          break if m == 0xDA || m == 0xD9
          if m == 0x01 || (m >= 0xD0 && m <= 0xD8)
            pos += 2
            next
          end
          len = (data[pos + 2].to_i32 << 8) | data[pos + 3].to_i32
          if m == 0xE1 && len >= 16 && pos + 4 + len - 2 <= data.size &&
             data[pos + 4] == 'E'.ord && data[pos + 5] == 'x'.ord && data[pos + 6] == 'i'.ord &&
             data[pos + 7] == 'f'.ord && data[pos + 8] == 0 && data[pos + 9] == 0
            o = exif_orientation(data[pos + 10, len - 8])
            return o if o
          end
          pos += 2 + len
        end
        1
      end

      private def self.exif_orientation(t : Bytes) : Int32?
        return nil if t.size < 8
        little = if t[0] == 'I'.ord && t[1] == 'I'.ord
                   true
                 elsif t[0] == 'M'.ord && t[1] == 'M'.ord
                   false
                 else
                   return nil
                 end
        rd16 = ->(i : Int32) { little ? (t[i].to_i32 | (t[i + 1].to_i32 << 8)) : ((t[i].to_i32 << 8) | t[i + 1].to_i32) }
        rd32 = ->(i : Int32) {
          little ? (t[i].to_i64 | (t[i + 1].to_i64 << 8) | (t[i + 2].to_i64 << 16) | (t[i + 3].to_i64 << 24)) : ((t[i].to_i64 << 24) | (t[i + 1].to_i64 << 16) | (t[i + 2].to_i64 << 8) | t[i + 3].to_i64)
        }
        return nil unless rd16.call(2) == 42
        ifd = rd32.call(4)
        return nil if ifd + 2 > t.size
        ifd = ifd.to_i32
        count = rd16.call(ifd)
        count.times do |i|
          e = ifd + 2 + i * 12
          break if e + 12 > t.size
          if rd16.call(e) == 0x0112 && rd16.call(e + 2) == 3
            v = rd16.call(e + 8)
            return v if v >= 1 && v <= 8
            return nil
          end
        end
        nil
      end
    end
  end
end

require "./jpeg_decoder"
require "./jpeg_encoder"
