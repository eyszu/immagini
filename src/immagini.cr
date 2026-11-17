require "./immagini/version"
require "./immagini/errors"
require "./immagini/color"
require "./immagini/parallel"
require "./immagini/pixels"
require "./immagini/image"
require "./immagini/codecs/png"
require "./immagini/codecs/bmp"
require "./immagini/codecs/pnm"
require "./immagini/codecs/jpeg"
require "./immagini/format"
require "./immagini/ops/resize"
require "./immagini/ops/geometry"
require "./immagini/ops/color_ops"
require "./immagini/ops/composite"
require "./immagini/ops/filters"

# Immagini: fast, dependency-free image processing.
module Immagini
  # Shorthand for `Image.open`.
  def self.open(path : String | Path, *, auto_orient : Bool = false) : Image
    Image.open(path, auto_orient: auto_orient)
  end
end
