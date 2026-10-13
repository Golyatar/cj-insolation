# frozen_string_literal: true

require 'json'
require 'time'
require 'securerandom'
require 'fileutils'

module CJBridge
  ROOT = File.expand_path('..', __dir__) unless const_defined?(:ROOT, false)
  QUEUE = File.join(ROOT, 'tooling', 'runtime') unless const_defined?(:QUEUE, false)
  COMMANDS = %w[status reload check raycast geometry_test stop].freeze unless const_defined?(:COMMANDS, false)

  def self.write_json(path, data)
    temporary = "#{path}.tmp"
    File.write(temporary, JSON.pretty_generate(data), mode: 'w', encoding: 'UTF-8')
    File.rename(temporary, path)
  end

  def self.status
    {
      protocol: 1, session_id: @session_id, pid: Process.pid,
      running: !@timer.nil?, updated_at: Time.now.utc.iso8601,
      sketchup_version: Sketchup.version, ruby_version: RUBY_VERSION,
      commands: COMMANDS,
      model_entity_count: Sketchup.active_model.entities.length,
      editing_group: !Sketchup.active_model.active_path.nil?
    }
  end

  def self.stop
    UI.stop_timer(@timer) if @timer
    @timer = nil
    write_json(File.join(QUEUE, 'session.json'), status) if @session_id
    true
  end

  def self.ensure_development
    Kernel.load(File.join(ROOT, 'dev', 'session.rb')) unless defined?(CJDevelopment)
  end

  def self.triple(value)
    raise ArgumentError, 'Expected three finite numbers' unless value.is_a?(Array) && value.length == 3 && value.all? { |n| n.is_a?(Numeric) && n.finite? }
    value
  end

  def self.dispatch(command, args)
    case command
    when 'status' then status
    when 'reload'
      ensure_development
      { reloaded: CJDevelopment.reload }
    when 'check'
      ensure_development
      CJDevelopment.check
    when 'geometry_test'
      raise 'Leave group/component edit mode before geometry tests' if Sketchup.active_model.active_path
      ensure_development
      Kernel.load(File.join(ROOT, 'tooling', 'geometric_checks.rb'))
      CJGeometryChecks.run
    when 'raycast'
      origin = Geom::Point3d.new(triple(args.fetch('origin_mm')).map { |n| n.mm })
      direction = Geom::Vector3d.new(triple(args.fetch('direction')))
      raise ArgumentError, 'Direction must not be zero' if direction.length == 0
      direction.normalize!
      hit = Sketchup.active_model.raytest([origin, direction], true)
      {
        hit: !hit.nil?,
        point_mm: hit && hit[0].to_a.map { |n| n.to_mm },
        distance_mm: hit && origin.distance(hit[0]).to_mm,
        path_ids: hit && hit[1].map(&:persistent_id)
      }
    when 'stop' then { stopped: stop }
    else raise ArgumentError, "Unknown command: #{command}"
    end
  end

  def self.process(path)
    id = File.basename(path, '.request.json')
    return unless id.match?(/\A[0-9a-f-]{36}\z/)
    response_path = File.join(QUEUE, "#{id}.response.json")
    # A completed request is never executed again if archiving was interrupted.
    unless File.exist?(response_path)
      began = Time.now
      response = { protocol: 1, id: id, session_id: @session_id }
      begin
        raise ArgumentError, 'Request exceeds 64 KB' if File.size(path) > 65_536
        request = JSON.parse(File.read(path, encoding: 'UTF-8'))
        raise ArgumentError, 'Protocol mismatch' unless request['protocol'] == 1
        raise ArgumentError, 'ID mismatch' unless request['id'] == id
        raise ArgumentError, 'Session mismatch; request will not execute' unless request['session_id'] == @session_id
        raise ArgumentError, 'Expired request; request will not execute' unless Time.iso8601(request.fetch('expires_at')) > Time.now
        raise ArgumentError, 'Arguments must be an object' unless request['args'].is_a?(Hash)
        response[:result] = dispatch(request.fetch('command'), request['args'])
        response[:ok] = true
      rescue StandardError, SyntaxError => error
        response[:ok] = false
        response[:error] = { type: error.class.name, message: error.message, backtrace: error.backtrace&.first(12) }
      end
      response[:duration_ms] = ((Time.now - began) * 1000).round
      response[:completed_at] = Time.now.utc.iso8601
      write_json(response_path, response)
    end
    File.rename(path, path.sub('.request.json', '.handled.json'))
  end

  def self.tick
    return if @busy
    @busy = true
    begin
      if !@last_heartbeat || Time.now - @last_heartbeat >= 2
        write_json(File.join(QUEUE, 'session.json'), status)
        @last_heartbeat = Time.now
      end
      path = Dir.glob(File.join(QUEUE, '*.request.json')).sort.first
      process(path) if path
    rescue StandardError => error
      puts "[CJBridge] #{error.class}: #{error.message}"
    ensure
      @busy = false
    end
  end

  def self.start
    FileUtils.mkdir_p(QUEUE)
    stop if @timer
    existing_path = File.join(QUEUE, 'session.json')
    if File.exist?(existing_path)
      existing = JSON.parse(File.read(existing_path, encoding: 'UTF-8'))
      if existing['running'] && existing['pid'] != Process.pid && Time.now - Time.iso8601(existing['updated_at']) < 10
        raise 'Another SketchUp process owns this bridge folder'
      end
    end
    @session_id = SecureRandom.uuid
    @last_heartbeat = nil
    @timer = UI.start_timer(0.25, true) { tick }
    write_json(existing_path, status)
    puts "[CJBridge] Started. Commands: #{COMMANDS.join(', ')}"
    true
  end
end

CJBridge.start
