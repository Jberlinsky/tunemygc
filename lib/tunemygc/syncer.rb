# encoding: utf-8

require 'tunemygc/network'

module TuneMyGc
  class Syncer
    ENVIRONMENT = [ENV['RUBY_GC_TOKEN'], RUBY_VERSION, TuneMyGc.rails_version, ENV.select {|k,v| k =~ /RUBY_GC_/ }, TuneMyGc::VERSION, GC::OPTS, GC::INTERNAL_CONSTANTS].freeze

    attr_reader :uri, :client

    def initialize(host = TuneMyGc::HOST)
      @uri = URI("http://#{host}/ruby")
      @client = Net::HTTP.new(@uri.host, @uri.port)
      @client.use_ssl = (uri.port == 443)
      @client.read_timeout = NETWORK_TIMEOUT
    end

    def sync(snapshotter)
      if sync_required?(snapshotter)
        response = nil
        timeout do
          response = sync_with_tuner(snapshotter)
        end
        timeout do
          process_config_callback(response)
        end if response
      else
        TuneMyGc.log "Nothing to sync, discarding #{snapshotter.size} snapshots"
        snapshotter.clear
      end
    end

    def sync_required?(snapshotter)
      return true if ENV['RUBY_GC_SYNC_ALWAYS']
      snapshotter.unit_of_work
    end

    def environment(snapshotter)
      ENVIRONMENT.dup.concat([snapshotter.stat_keys, TuneMyGc.spy.underscore, Socket.gethostname, Process.ppid, Process.pid])
    end

    private
    def timeout(&block)
      Timeout.timeout(NETWORK_TIMEOUT + 1){ block.call }
    end

    def sync_with_tuner(snapshotter)
binding.pry
      snapshots = 0
      # Fallback to Timeout if Net::HTTP read timeout fails
      snapshots = snapshotter.size
      TuneMyGc.log "Syncing #{snapshots} snapshots"
      payload = [environment(snapshotter)]
      debug = ENV["RUBY_GC_TUNE_DEBUG"]
      TuneMyGc.log "=== Snapshots ===" if debug
      while !snapshotter.empty?
        snapshot = snapshotter.deq
        TuneMyGc.log(snapshot) if debug
        payload << snapshot
      end
      data = ActiveSupport::JSON.encode(payload)
      response = client.post(uri.path, data, TuneMyGc::HEADERS)
      snapshotter.unit_of_work = false
      if Net::HTTPNotFound === response
        TuneMyGc.log "Invalid application token. Please generate one with 'bundle exec tunemygc <a_valid_email_address>' and set the RUBY_GC_TOKEN environment variable"
        return false
      elsif Net::HTTPNotImplemented === response
        TuneMyGc.log "Ruby version #{RUBY_VERSION} or Rails version #{TuneMyGc.rails_version} not supported. Failed to sync #{snapshots} snapshots"
        return false
      elsif Net::HTTPUpgradeRequired === response
        TuneMyGc.log "Agent version #{response.body} required - please upgrade. Failed to sync #{snapshots} snapshots"
        return false
      elsif Net::HTTPPreconditionFailed === response
        TuneMyGc.log "The GC is already tuned by environment variables (#{response.body}) - we respect that, doing nothing. Failed to sync #{snapshots} snapshots"
        return false
      elsif Net::HTTPBadRequest === response
        TuneMyGc.log "Invalid payload (#{response.body}). Failed to sync #{snapshots} snapshots"
        return false
      elsif Net::HTTPInternalServerError === response
        TuneMyGc.log "An internal error occurred (#{response.body}). Failed to sync #{snapshots} snapshots"
        return false
      elsif Net::HTTPSuccess === response
        response
      else
        TuneMyGc.log "Unknown error: #{response.body}"
        return false
      end
    rescue Exception => e
      TuneMyGc.log "Failed to sync #{snapshots} snapshots (error: #{e})"
      return false
    ensure
      # Prefer to loose data points than accumulate buffers indefinitely on error or other conditions
      snapshotter.clear
    end

    def process_config_callback(response)
      report_url = response.body.gsub(/\.json$/, '')
      config = client.get(URI(response.body).path)
      ActiveSupport::JSON.decode(config.body).merge('report' => report_url)
    rescue Exception => e
      TuneMyGc.log "Please visit #{report_url} to view your configuration and other Garbage Collector insights"
      return false
    end
  end
end
