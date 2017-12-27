# Queued DownLoader with Timeline backup and Cache
require 'rubygems'
require 'open-uri'
require 'digest/md5'
require 'fileutils'
require 'zlib'
require 'thread'
require 'time'
require 'sequel'

THEME = ARGV[0] || File.basename(File.absolute_path('.'))
N_THREADS = 12
Q_SIZE = 2000
#途中経過の表示タイミング
WAIT = 10
#タイル総数 目録より取得して手動で設定する
ALL = 50749203 
CONTINUE = nil
#タイルダウンロード試行回数をオーバーした場合はエラーに出力する
TRYCOUNT = 5
CACHE_DB_PATH = 'md5sum_cache.sqlite3'

#初期設定
$threads = Array.new(N_THREADS)
$status = {:skip => 0, :ok => 0, :ng => 0, :path => nil, :cache_skip => 0}
$keys = %w{skip ok ng cache_skip}
$q = SizedQueue.new(Q_SIZE)
$db = Sequel.sqlite('md5sum_cache.sqlite3')
unless $db.tables.include?(:cache)
  $db.create_table :cache do
    primary_key String :zxy
    index :zxy, :unique => true
    String :md5
  end
end

#ダウンロード用スレッド処理
$threads.size.times {|i|
  $threads[i] = Thread.new(i) do
    while o = $q.pop
      retrycount = 0
      buf = nil
      begin
        buf = open(o[:url]).read
      rescue
        retrycount += 1
        if (retrycount <= TRYCOUNT)
          print "download url: #{o[:url]}\n"
          print $!, " -- retrying...\n"
          sleep rand
          retry
        else
          # リトライカウントをオーバーした場合は
          # 標準エラーに出力してダウンロード試行を止める。
          # bufにダミー文字列を代入して後のmd5チェックで
          # NGにカウントされることを期待する。
          STDERR.print "#{o[:url]}\n"
          buf = "dummy"
        end
      end
      buf_md5 = Digest::MD5.hexdigest(buf)
      if o[:md5] != buf_md5
        $status[:ng] += 1
      else
        [File.dirname(o[:path])].each{|it|
          FileUtils.mkdir_p(it) unless File.directory?(it)
        }
        if(File.exist?(o[:path]))
          bk_path = "bak/#{o[:path]}"
          bk_path.insert(bk_path.rindex('.'),
            ".#{File.mtime(o[:path]).iso8601.split('T')[0].gsub('-', '')}")
          [File.dirname(bk_path)].each {|it|
            FileUtils.mkdir_p(it) unless File.directory?(it)
          }
          FileUtils.cp(o[:path], bk_path, :preserve => true)
        end
        File.open("#{o[:path]}", 'wb') {|w| w.print buf}
        File.utime(o[:date], o[:date], o[:path])
        $cache_updates << {:zxy => o[:zxy], :md5 => buf_md5}
        $status[:ok] += 1
      end
    end
  end
}

watcher = Thread.new do
  printheader = 10
  watchline = 0
  while $threads.reduce(false) {|any_alive, t| any_alive or t.alive?}
    last_status = $status.clone
    sleep WAIT
    if(watchline == 0)
      print "time path qsize #{$keys.map{|k| k}} count(ok) success% cache_update\n"
    end
    print "#{Time.now.iso8601[11..18]} #{$status[:path]} #{$q.size} "
    print "#{$keys.map{|k| ($status[k.to_sym] - last_status[k.to_sym]) / WAIT}}/s "
#    print "#{$keys.map{|k| $status[k.to_sym]}} "
    print "#{$count}(#{$status[:ok]}) #{(100.0 * $count / ALL).to_i}% (#{$cache_updates.size})\n"
    begin
      $db.transaction do
        $cache_updates.each {|r|
          if 1 != $db[:cache].where(:zxy => r[:zxy]).update(:md5 => r[:md5])
            $db[:cache].insert(:zxy => r[:zxy], :md5 => r[:md5])
          end
        }
      end
    rescue
      print $!, " -- retrying...\n"
      sleep rand
      retry
    end
    $cache_updates = []
    watchline += 1
    if(watchline >= printheader)
      watchline = 0
    end
  end
end

# 目録ファイルからタイル情報を読み込みQUEUEを作成する
# すでにダウンロード済みのタイルはスキップする
# 　タイル毎にmokuroku.csv.gzのmd5とCACHE_DB_PATHのmd5を比較して
# 　同じ値であればスキップ
# 　目録とCACHE_DBのmd5の値が違う場合は実ファイルのmd5をチェックして
# 　変更があればCACHE_DBを更新
$cache_updates = []
$count = 0
Zlib::GzipReader.open('mokuroku.csv.gz').each_line {|l|
  $count += 1
  (path, date, size, md5) = l.strip.split(',')
  date = date.to_i
  url = "https://cyberjapandata.gsi.go.jp/xyz/#{THEME}/#{path}"
  zxy = path.split('.')[0]
  next if /\{z\}/.match(path)
  $status[:path] = path
  if(CONTINUE && $count < CONTINUE)
    $status[:skip] += 1
    next
  end
  cache_md5 = nil
  begin
    cache_md5 = $db[:cache].where(:zxy => zxy).select(:md5).first
  rescue
    print $!, " -- retrying...\n"
    sleep rand
    retry
  end
  cache_md5 = cache_md5 ? cache_md5[:md5] : nil
  if cache_md5 == md5
    $status[:skip] += 1
    $status[:cache_skip] += 1
    next
  end
  if File.exist?(path)
    local_md5 = Digest::MD5.file(path).to_s
    if local_md5 == md5
      $cache_updates << {:zxy => zxy, :md5 => local_md5} ## 初期が終わったら不要
      $status[:skip] += 1
      next
    end
  end
  $q.push({:url => url, :date => date, :md5 => md5, :path => path, :zxy => zxy})
}
$db.disconnect

$threads.size.times {|i| $q.push(nil)}

$threads.each {|t| t.join}
watcher.join
