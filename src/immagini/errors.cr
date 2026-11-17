module Immagini
  # Base class of every error raised by Immagini (argument errors excepted:
  # those stay `ArgumentError`/`IndexError`, as in the standard library).
  class Error < Exception
  end

  # The input could not be identified as one of the supported formats.
  class UnknownFormatError < Error
  end

  # The input is (or claims to be) a supported format but is corrupt/truncated.
  class DecodeError < Error
  end

  # The input is valid, but uses a feature this library does not implement
  # (for example progressive JPEG).
  class UnsupportedError < Error
  end
end
