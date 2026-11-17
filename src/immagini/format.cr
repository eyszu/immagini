module Immagini
  # Supported container formats.
  enum Format
    PNG
    JPEG
    BMP
    PNM

    # Sniffs the format from the leading bytes, or nil when unknown.
    def self.detect(data : Bytes) : Format?
      return nil if data.size < 2
      b0, b1 = data[0], data[1]
      if data.size >= 8 && b0 == 0x89 && b1 == 0x50 && data[2] == 0x4E && data[3] == 0x47
        PNG
      elsif b0 == 0xFF && b1 == 0xD8
        JPEG
      elsif b0 == 'B'.ord && b1 == 'M'.ord
        BMP
      elsif b0 == 'P'.ord && b1 >= '1'.ord && b1 <= '6'.ord
        PNM
      end
    end

    # Maps a file extension (with or without the dot) to a format.
    def self.from_extension(ext : String) : Format?
      case ext.lchop('.').downcase
      when "png"                      then PNG
      when "jpg", "jpeg", "jpe"       then JPEG
      when "bmp", "dib"               then BMP
      when "ppm", "pgm", "pnm", "pbm" then PNM
      end
    end

    def mime_type : String
      case self
      in PNG  then "image/png"
      in JPEG then "image/jpeg"
      in BMP  then "image/bmp"
      in PNM  then "image/x-portable-anymap"
      end
    end
  end

  class Image
    # Decodes an image from memory. The format is sniffed unless given.
    #
    # With `auto_orient: true`, JPEG EXIF orientation is applied so the result
    # is displayed upright.
    def self.decode(data : Bytes, format : Format? = nil, *, auto_orient : Bool = false) : Image
      fmt = format || Format.detect(data) || raise UnknownFormatError.new("unrecognised image format")
      case fmt
      in Format::PNG then Codecs::PNG.decode(data)
      in Format::BMP then Codecs::BMP.decode(data)
      in Format::PNM then Codecs::PNM.decode(data)
      in Format::JPEG
        img = Codecs::JPEG.decode(data)
        if auto_orient
          o = Codecs::JPEG.orientation(data)
          img = img.orient(o) if o > 1
        end
        img
      end
    end

    def self.decode(data : String, format : Format? = nil, *, auto_orient : Bool = false) : Image
      decode(data.to_slice, format, auto_orient: auto_orient)
    end

    # Reads everything from `io` and decodes it.
    def self.read(io : IO, format : Format? = nil, *, auto_orient : Bool = false) : Image
      mem = IO::Memory.new
      IO.copy(io, mem)
      decode(mem.to_slice, format, auto_orient: auto_orient)
    end

    # Loads an image file (format sniffed from content, not the extension).
    def self.open(path : String | Path, *, auto_orient : Bool = false) : Image
      File.open(path) do |f|
        bytes = Bytes.new(f.size.to_i32)
        f.read_fully(bytes)
        decode(bytes, auto_orient: auto_orient)
      end
    end

    # Encodes to memory.
    #
    # * `quality` (1-100) and `subsampling` apply to JPEG.
    # * `compression` (0-9) and `filter` apply to PNG.
    # * `grayscale` applies to PNM (writes PGM instead of PPM).
    #
    # JPEG, BMP-24 and PNM have no alpha channel: transparent pixels are
    # composited onto `background` (white by default).
    def encode(format : Format, *, quality : Int32 = 90,
               subsampling : Codecs::JPEG::Subsampling = Codecs::JPEG::Subsampling::S420,
               compression : Int32 = 6,
               filter : Codecs::PNG::Filter = Codecs::PNG::Filter::Adaptive,
               grayscale : Bool = false,
               background : Color = Color::WHITE) : Bytes
      io = IO::Memory.new
      write(io, format, quality: quality, subsampling: subsampling, compression: compression,
        filter: filter, grayscale: grayscale, background: background)
      io.to_slice
    end

    # Encodes to `io`. See `encode` for the options.
    def write(io : IO, format : Format, *, quality : Int32 = 90,
              subsampling : Codecs::JPEG::Subsampling = Codecs::JPEG::Subsampling::S420,
              compression : Int32 = 6,
              filter : Codecs::PNG::Filter = Codecs::PNG::Filter::Adaptive,
              grayscale : Bool = false,
              background : Color = Color::WHITE) : Nil
      case format
      in Format::PNG  then Codecs::PNG.encode(self, io, compression, filter)
      in Format::JPEG then Codecs::JPEG.encode(self, io, quality, subsampling, background)
      in Format::BMP  then Codecs::BMP.encode(self, io, background)
      in Format::PNM  then Codecs::PNM.encode(self, io, grayscale, background)
      end
    end

    # Writes to a file. The format comes from `format` or, if omitted, the
    # file extension (`.png .jpg .jpeg .bmp .ppm .pgm .pnm`). See `encode`
    # for the options; `.pgm` implies `grayscale: true`.
    def save(path : String | Path, format : Format? = nil, *, quality : Int32 = 90,
             subsampling : Codecs::JPEG::Subsampling = Codecs::JPEG::Subsampling::S420,
             compression : Int32 = 6,
             filter : Codecs::PNG::Filter = Codecs::PNG::Filter::Adaptive,
             grayscale : Bool? = nil,
             background : Color = Color::WHITE) : Nil
      ext = File.extname(path.to_s).downcase
      fmt = format || Format.from_extension(ext) ||
            raise UnknownFormatError.new("cannot infer format from #{path.to_s.inspect}; pass format:")
      gray = grayscale.nil? ? ext == ".pgm" : grayscale
      File.open(path, "w") do |f|
        write(f, fmt, quality: quality, subsampling: subsampling, compression: compression,
          filter: filter, grayscale: gray, background: background)
      end
    end
  end
end
