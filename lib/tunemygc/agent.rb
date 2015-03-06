# encoding: utf-8

require "tunemygc/tunemygc_ext"
require "tunemygc/interposer"
require "tunemygc/snapshotter"
require "logger"

module TuneMyGc
  MUTEX = Mutex.new

  attr_accessor :logger, :interposer, :snapshotter

  def booted
    TuneMyGc.interposer.install
  end

  def processing_started
    snapshot(:PROCESSING_STARTED)
  end

  def processing_ended
    snapshot(:PROCESSING_ENDED)
    interposer.check_uninstall
  end

  def snapshot(stage, meta = nil)
    snapshotter.take(stage, meta)
  end

  def raw_snapshot(snapshot)
    snapshotter.take_raw(snapshot)
  end

  def log(message)
    puts "[TuneMyGC, pid: #{Process.pid}] #{message}"
    logger.info "[TuneMyGC, pid: #{Process.pid}] #{message}"
  end

  def spy
    TuneMyGc::Spies.current
  end

  def reccommendations
    MUTEX.synchronize do
      require "tunemygc/syncer"
      syncer = TuneMyGc::Syncer.new
      config = syncer.sync(snapshotter)
      require "tunemygc/configurator"
      TuneMyGc::Configurator.new(config).configure
    end
  rescue Exception => e
    log "Config reccommendation error (#{e.message})"
  end

  extend self

  MUTEX.synchronize do
    begin
      require 'mono_logger'
      self.logger = MonoLogger.new($stdout)
    rescue LoadError
      self.logger = Logger.new($stdout)
    end
    self.interposer = TuneMyGc::Interposer.new
    self.snapshotter = TuneMyGc::Snapshotter.new
  end
end
