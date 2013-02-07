require "fileutils"
require "find"
require "open-uri"
require "shellwords"
require "syslog"
require "timeout"
require "uri"

$stdout.sync = true
Syslog.open("slug-compiler", Syslog::LOG_CONS, Syslog::LOG_USER)

module SlugCompiler
  class CompileError < RuntimeError; end
  class CompileFail < RuntimeError; end

  module_function

  def run(build_dir, buildpack_url, cache_dir)
    @compile_id = rand(2**64).to_s(36) # because UUIDs need a gem

    buildpack_dir = fetch_buildpack(buildpack_url)
    config = buildpack_config(buildpack_url)
    buildpack_name = detect(build_dir, buildpack_dir)
    compile(build_dir, buildpack_dir, cache_dir, config)

    prune(build_dir)
    process_types = parse_procfile(build_dir)
    slug = archive(build_dir)
    log_size(build_dir, cache_dir, slug)

    slug
  ensure
    FileUtils.rm_rf(buildpack_dir) if buildpack_dir
  end

  def fetch_buildpack(buildpack_url)
    buildpack_dir = "/tmp/buildpack_#{@compile_id}"

    log("fetch_buildpack") do
      Timeout.timeout((ENV["BUILDPACK_FETCH_TIMEOUT"] || 90).to_i) do
        FileUtils.mkdir_p(buildpack_dir)
        if buildpack_url =~ /^https?:\/\/.*\.(tgz|tar\.gz)($|\?)/
          print("-----> Fetching buildpack... ")
          fetch_tar(buildpack_url, buildpack_dir) rescue fetch_tar(buildpack_url, buildpack_dir)
        elsif File.directory?(buildpack_url)
          print("-----> Copying buildpack... ")
          FileUtils.cp_r(buildpack_url + "/.", buildpack_dir)
        else
          print("-----> Cloning buildpack... ")
          url, treeish = buildpack_url.split("#")
          clear_var("GIT_DIR") do
            system(["git", "clone", Shellwords.escape(url), buildpack_dir],
                   [:out, :err] => "/dev/null") or raise("Couldn't clone")
            system(["git", "checkout", Shellwords.escape(treeish)],
                   [:out, :err] => "/dev/null", :chdir => buildpack_dir) if treeish
          end
        end
      end

      bins = ["compile", "detect", "release"].map { |b|"#{buildpack_dir}/bin/#{b}" }
      FileUtils.chmod(0755, bins.select{|b| File.exists?(b)})
      puts("done")
    end

    buildpack_dir
  rescue StandardError, Timeout::Error => e
    puts("failed")
    log_error("error fetching buildpack", e)
    raise(CompileError, "error fetching buildpack")
  end

  def fetch_tar(url, dir)
    IO.popen("tar xz -C #{dir}", "w") do |tar|
      IO.copy_stream(open(url), tar)
    end
  end

  def buildpack_config(buildpack_url)
    config = {}
    if query = (buildpack_url && URI.parse(buildpack_url).query)
      query.split("&").each do |kv|
        next if kv.empty?
        k, v = kv.split("=", 2)
        config[k] = URI.unescape(v || "")
      end
    end
    config
  end

  def detect(build_dir, buildpack_dir)
    buildpack_name = `#{File.join(buildpack_dir, "bin", "detect")} #{build_dir} 2>1`.strip
    puts("-----> #{buildpack_name} app detected")
    return buildpack_name
  rescue
    raise(CompileFail, "no compatible app detected")
  end

  def compile(build_dir, buildpack_dir, cache_dir, config)
    bin_compile = File.join(buildpack_dir, 'bin', 'compile')
    timeout = (ENV["COMPILE_TIMEOUT"] || 900).to_i
    Timeout.timeout(timeout) do
      pid = spawn(config, bin_compile, build_dir, cache_dir,
                  unsetenv_others: true, err: :out)
      status = Process.wait(pid)
      raise(CompileFail) unless status.zero?
    end
  rescue Timeout::Error
    raise(CompileFail, "timed out; must complete in #{timeout} seconds")
  end

  def prune(build_dir)
    FileUtils.rm_rf(File.join(build_dir, ".git"))
    FileUtils.rm_rf(File.join(build_dir, "tmp"))

    Find.find(build_dir) do |path|
      File.delete(path) if File.basename(path) == ".DS_Store"
    end

    prune_slugignore(build_dir)
  end

  def prune_slugignore(build_dir)
    # general pattern format follows .gitignore:
    # http://www.kernel.org/pub/software/scm/git/docs/gitignore.html
    # blank => nothing; leading # => comment
    # everything else is more or less a shell glob
    slugignore_path = File.join(build_dir, ".slugignore")
    return if !File.exists?(slugignore_path)

    log("process_slugignore") do
      lines = File.read(slugignore_path).split
      total = lines.inject(0) do |total, line|
        line = (line.split(/#/).first || "").strip
        if line.empty?
          total
        else
          globs = if line =~ /\//
                    [File.join(build_dir, line)]
                  else
                    # 1.8.7 and 1.9.2 handle expanding ** differently,
                    # where in 1.9.2 ** doesn't match the empty case. So
                    # try empty ** explicitly
                    ["", "**"].map { |g| File.join(build_dir, g, line) }
                  end

          to_delete = Dir[*globs].uniq.map { |p| File.expand_path(p) }.select { |p| p.match(/^#{build_dir}/) }
          to_delete.each { |p| FileUtils.rm_rf(p) }
          total + to_delete.size
        end
      end
      puts("-----> Deleting #{total} files matching .slugignore patterns.")
    end
  end

  def parse_procfile(build_dir)
    path = File.join(build_dir, "Procfile")
    return unless File.exists?(path)

    File.read(path).split("\n").inject({}) do |ps, line|
      if m = line.match(/^([a-zA-Z0-9_]+):?\s+(.*)/)
        ps[m[1]] = m[2]
      end
      ps
    end
    # TODO: message_procfile
  end

  def archive(build_dir)
    slug = "/tmp/slug_#{@compile_id}.tar.gz"
    log("create_tar_slug") do
      system(["tar", "czf", slug, "--xform" "s,^./,./app/,", "--owner=root",
              "--hard-dereference", "-C", build_dir, "."],
             [:out, :err] => "/dev/null") or raise("couldn't tar")
    end
    return slug
  rescue => e
    log_error("could not archive slug", e)
    raise(CompileError, "could not archive slug")
  end

  def log_size(build_dir, cache_dir, slug)
    log("check_sizes") do
      raw_size = `du -s -x #{build_dir}`.split(" ").first.to_i*1024
      cache_size = `du -s -x #{cache_dir}`.split(" ").first.to_i*1024 if File.exists? cache_dir
      slug_size = File.size(slug)
      log("check_sizes at=emit raw_size=#{raw_size} slug_size=#{slug_size} cache_size=#{cache_size}")
      puts(sprintf("-----> Compiled slug size: %1.0fK", slug_size / 1024))
    end
  end

  # utils

  def clear_var(k)
    v = ENV.delete(k)
    begin
      yield
    ensure
      ENV[k] = v
    end
  end

  def log(msg, &block)
    if block
      start = Time.now
      res = nil
      log("slugc #{msg} at=start")
      begin
        res = yield
      rescue => e
        log_error("#{msg} elapsed=#{Time.now - start}", e)
        raise(e)
      end
      log("slugc #{msg} at=finish elapsed=#{Time.now - start}")
      res
    else
      Syslog.log(Syslog::LOG_INFO, msg)
    end
  end

  def log_error(line, e)
    Syslog.log(Syslog::LOG_ERR, "slugc #{line} at=error " \
               "class='#{e.class}' message='#{e.message}'")
  end
end
