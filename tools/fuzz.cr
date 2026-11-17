require "../src/immagini"
# Mutate valid files and make sure the decoders only ever raise Immagini errors
# (never crash, never hang, never raise something else).
files = %w(rgb.png rgba.png interlaced.png pal4.png gray.png rgb.bmp rgba.bmp rgb.ppm q90_420.jpg q90_444.jpg gray.jpg restart.jpg)
rng = Random.new((ARGV[0]? || "1234").to_u64)
ok = bad = other = 0
sites = Hash(String, Int32).new(0)
t0 = Time.monotonic
files.each do |f|
  orig = File.read("spec/fixtures/#{f}").to_slice
  8000.times do |i|
    d = orig.dup
    case i % 3
    when 0 then 1.upto(1 + rng.rand(4)) { d[rng.rand(d.size)] = rng.rand(256).to_u8 }
    when 1 then d = d[0, rng.rand(d.size)].dup
    else
      pos = rng.rand(d.size)
      n = Math.min(rng.rand(32), d.size - pos)
      n.times { |k| d[pos + k] = 0xFF_u8 }
    end
    begin
      Immagini::Image.decode(d)
      ok += 1
    rescue Immagini::Error | ArgumentError
      bad += 1
    rescue ex
      other += 1
      puts "UNEXPECTED #{f} iter #{i}: #{ex.class}: #{ex.message}"
      File.write("/tmp/cr/fail_#{other}.bin", d) if other < 3
      sites[ex.backtrace.find(&.starts_with?("src/")) || "?"] += 1
    end
  end
end
sites.each { |k, v| puts "  #{v}x #{k}" }
puts "decoded=#{ok} rejected=#{bad} unexpected=#{other} in #{(Time.monotonic - t0).total_seconds.round(1)}s"
