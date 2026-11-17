module Immagini
  # Row-band parallelism.
  #
  # Compiled normally (no `-Dpreview_mt`) every call runs inline on the calling
  # fiber, so there is zero scheduling overhead. With `-Dpreview_mt` the work is
  # split into bands that run on Crystal's worker threads.
  #
  # The thread count defaults to the CPU count and can be capped with
  # `IMMAGINI_THREADS` or `Immagini::Parallel.threads = n`.
  module Parallel
    @@threads : Int32 = 0

    def self.threads : Int32
      {% if flag?(:preview_mt) %}
        if @@threads <= 0
          env = ENV["IMMAGINI_THREADS"]?.try(&.to_i?)
          @@threads = (env && env > 0) ? env : System.cpu_count.to_i32
        end
        @@threads
      {% else %}
        1
      {% end %}
    end

    def self.threads=(n : Int32)
      @@threads = n
    end

    # Calls the block with `(from, to)` half-open ranges that cover `0...count`.
    # `min_band` keeps tiny jobs on one thread. The block must only write to
    # data that belongs to its own range.
    def self.bands(count : Int32, min_band : Int32 = 32, &block : Int32, Int32 ->) : Nil
      {% if flag?(:preview_mt) %}
        n = Math.min(threads, count // Math.max(min_band, 1))
        if n > 1
          done = Channel(Nil).new
          step = (count + n - 1) // n
          started = 0
          from = 0
          while from < count
            to = Math.min(from + step, count)
            start_band(block, from, to, done)
            started += 1
            from = to
          end
          started.times { done.receive }
          return
        end
      {% end %}
      block.call(0, count)
    end

    # Runs one band on its own fiber. This is a separate method on purpose:
    # Crystal closures capture variables by reference and a `while` body is not
    # a fresh scope, so spawning from inside the loop would make every fiber
    # see the same (last) `from`/`to`.
    private def self.start_band(block : Int32, Int32 ->, lo : Int32, hi : Int32, done : Channel(Nil)) : Nil
      spawn do
        begin
          block.call(lo, hi)
        ensure
          done.send(nil)
        end
      end
    end
  end
end
