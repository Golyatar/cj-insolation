# frozen_string_literal: true

require 'json'
require 'time'
require 'securerandom'
require 'fileutils'

module CJBridge
  ROOT = File.expand_path('..', __dir__) unless const_defined?(:ROOT, false)
  QUEUE_ROOT = File.join(ROOT, 'tooling', 'runtime', 'instances') unless const_defined?(:QUEUE_ROOT, false)
  remove_const(:COMMANDS) if const_defined?(:COMMANDS, false)
  COMMANDS = %w[status reload check raycast geometry_test inspect entities selection select create edit move delete save stop snapshot view export].freeze

  def self.write_json(path, data)
    temporary = "#{path}.tmp"
    File.write(temporary, JSON.pretty_generate(data), mode: 'w', encoding: 'UTF-8')
    File.rename(temporary, path)
  end

  def self.status
    model = Sketchup.active_model
    {
      protocol: 1, session_id: @session_id, pid: Process.pid,
      running: !@timer.nil?, updated_at: Time.now.utc.iso8601,
      sketchup_version: Sketchup.version, ruby_version: RUBY_VERSION,
      commands: COMMANDS,
      model_open: !model.nil?,
      model_token: model && model.object_id.to_s,
      connection_panel_available: respond_to?(:show_connection_panel),
      connection_panel_visible: !!(@connection_panel && @connection_panel.visible?),
      model_name: model && model.title, model_path: model && model.path,
      model_entity_count: model ? model.entities.length : 0,
      editing_group: model ? !model.active_path.nil? : false
    }
  end

  def self.active_model!
    model = Sketchup.active_model
    raise 'No active model; open a SketchUp model first.' unless model
    model
  end

  def self.stop
    UI.stop_timer(@timer) if @timer
    @timer = nil
    write_json(File.join(@instance_queue, 'session.json'), status) if @session_id
    true
  end

  def self.ensure_development
    Kernel.load(File.join(ROOT, 'dev', 'session.rb'))
  end

  def self.triple(value)
    raise ArgumentError, 'Expected three finite numbers' unless value.is_a?(Array) && value.length == 3 && value.all? { |n| n.is_a?(Numeric) && n.finite? }
    value
  end

  def self.entity_info(entity)
    {
      persistent_id: entity.persistent_id, type: entity.typename,
      name: entity.respond_to?(:name) ? entity.name : nil,
      tag: entity.respond_to?(:layer) && entity.layer ? entity.layer.name : nil,
      material: entity.respond_to?(:material) && entity.material ? entity.material.name : nil,
      hidden: entity.respond_to?(:hidden?) ? entity.hidden? : false,
      locked: entity.respond_to?(:locked?) ? entity.locked? : false
    }
  end

  def self.find_entity(model, persistent_id)
    id = Integer(persistent_id)
    model.find_entity_by_persistent_id(id)
  end

  def self.walk_entities(entities, seen_definitions = {})
    entities.each do |entity|
      yield entity
      if entity.is_a?(Sketchup::Group)
        walk_entities(entity.entities, seen_definitions) { |child| yield child }
      elsif entity.is_a?(Sketchup::ComponentInstance) && !seen_definitions[entity.definition.persistent_id]
        seen_definitions[entity.definition.persistent_id] = true
        walk_entities(entity.definition.entities, seen_definitions) { |child| yield child }
      end
    end
  end

  def self.with_operation(model, name)
    model.start_operation(name, true)
    begin
      result = yield
      model.commit_operation
      result
    rescue Exception
      model.abort_operation
      raise
    end
  end

  def self.dispatch(command, args)
    raise ArgumentError, 'Unknown command' unless COMMANDS.include?(command)
    if args['expected_model_token'] && active_model!.object_id.to_s != args['expected_model_token']
      raise 'Target model changed; request refused. Read status again.'
    end
    case command
    when 'snapshot', 'view', 'export'
      Kernel.load(File.join(__dir__, 'model_capture.rb'))
      CJModelCapture.run(command, args, active_model!, @instance_queue)
    when 'status' then status
    when 'reload'
      ensure_development
      { reloaded: CJDevelopment.reload }
    when 'check'
      ensure_development
      CJDevelopment.check
    when 'geometry_test'
      raise 'Leave group/component edit mode before geometry tests' if active_model!.active_path
      ensure_development
      Kernel.load(File.join(ROOT, 'tooling', 'geometric_checks.rb'))
      CJGeometryChecks.run
    when 'raycast'
      origin = Geom::Point3d.new(triple(args.fetch('origin_mm')).map { |n| n.mm })
      direction = Geom::Vector3d.new(triple(args.fetch('direction')))
      raise ArgumentError, 'Direction must not be zero' if direction.length == 0
      direction.normalize!
      hit = active_model!.raytest([origin, direction], true)
      {
        hit: !hit.nil?,
        point_mm: hit && hit[0].to_a.map { |n| n.to_mm },
        distance_mm: hit && origin.distance(hit[0]).to_mm,
        path_ids: hit && hit[1].map(&:persistent_id)
      }
    when 'inspect'
      model = active_model!
      {
        title: model.title, path: model.path, version: Sketchup.version,
        units: model.options['UnitsOptions']['LengthUnit'],
        entity_count: model.entities.length, faces: model.number_faces,
        edges: model.entities.grep(Sketchup::Edge).length,
        groups: model.entities.grep(Sketchup::Group).length,
        components: model.entities.grep(Sketchup::ComponentInstance).length,
        tags: model.layers.map(&:name), materials: model.materials.map(&:name),
        scenes: model.pages.map(&:name), editing_group: !model.active_path.nil?,
        modified: model.modified?
      }
    when 'entities'
      model = active_model!
      limit = Integer(args.fetch('limit', 200))
      raise ArgumentError, 'limit must be between 1 and 1000' unless (1..1000).cover?(limit)
      type_filter = args['type']&.to_s
      name_filter = args['name_contains']&.downcase
      tag_filter = args['tag']
      found = []
      walk_entities(model.entities) do |entity|
        info = entity_info(entity)
        next if type_filter && info[:type] != type_filter
        next if name_filter && !info[:name].to_s.downcase.include?(name_filter)
        next if tag_filter && info[:tag] != tag_filter
        found << info
        break if found.length >= limit
      end
      { entities: found, limit: limit, truncated: found.length >= limit }
    when 'selection'
      model = active_model!
      { entities: model.selection.map { |entity| entity_info(entity) } }
    when 'select'
      model = active_model!
      ids = args.fetch('persistent_ids').map { |id| Integer(id) }
      entities = ids.map { |id| find_entity(model, id) }
      raise ArgumentError, 'One or more persistent IDs were not found' if entities.any?(&:nil?)
      model.selection.clear
      model.selection.add(entities)
      { selected: entities.map(&:persistent_id) }
    when 'create'
      model = active_model!
      points = args.fetch('points_mm').map { |point| Geom::Point3d.new(triple(point).map { |n| n.mm }) }
      kind = args.fetch('kind')
      raise ArgumentError, 'Expected kind line or face' unless %w[line face].include?(kind)
      raise ArgumentError, 'A line requires two points' if kind == 'line' && points.length != 2
      raise ArgumentError, 'A face requires at least three points' if kind == 'face' && points.length < 3
      raise ArgumentError, 'Too many points' if points.length > 500
      group = with_operation(model, "CJ Bridge: create #{kind}") do
        created = model.entities.add_group
        created.name = args['name'].to_s if args['name']
        if args['tag']
          tag = model.layers[args['tag']]
          raise ArgumentError, 'Tag not found' unless tag
          created.layer = tag
        end
        geometry = kind == 'line' ? created.entities.add_line(*points) : created.entities.add_face(points)
        raise ArgumentError, 'SketchUp could not create the requested geometry' unless geometry
        created
      end
      { entity: entity_info(group) }
    when 'edit'
      model = active_model!
      entity = find_entity(model, args.fetch('persistent_id'))
      raise ArgumentError, 'Entity not found' unless entity && entity.valid?
      props = args.fetch('properties')
      allowed = %w[name hidden tag material]
      raise ArgumentError, 'Unsupported or empty properties' if props.empty? || (props.keys - allowed).any?
      with_operation(model, 'CJ Bridge: edit entity') do
        entity.name = props['name'].to_s if props.key?('name') && entity.respond_to?(:name=)
        entity.hidden = !!props['hidden'] if props.key?('hidden') && entity.respond_to?(:hidden=)
        if props.key?('tag')
          tag = model.layers[props['tag']]
          raise ArgumentError, 'Tag not found' unless tag
          entity.layer = tag
        end
        if props.key?('material')
          material = props['material'].to_s.empty? ? nil : model.materials[props['material']]
          raise ArgumentError, 'Material not found' if !material && !props['material'].to_s.empty?
          entity.material = material if entity.respond_to?(:material=)
        end
      end
      { entity: entity_info(entity) }
    when 'move'
      model = active_model!
      ids = args.fetch('persistent_ids').map { |id| Integer(id) }
      entities = ids.map { |id| find_entity(model, id) }
      raise ArgumentError, 'One or more persistent IDs were not found' if entities.any?(&:nil?)
      vector = Geom::Vector3d.new(triple(args.fetch('offset_mm')).map { |n| n.mm })
      with_operation(model, 'CJ Bridge: move entities') { entities.each { |entity| entity.transform!(Geom::Transformation.translation(vector)) } }
      { moved: entities.map(&:persistent_id), offset_mm: triple(args.fetch('offset_mm')) }
    when 'delete'
      model = active_model!
      ids = args.fetch('persistent_ids').map { |id| Integer(id) }
      entities = ids.map { |id| find_entity(model, id) }
      raise ArgumentError, 'One or more persistent IDs were not found' if entities.any?(&:nil?)
      raise ArgumentError, 'Locked entities cannot be deleted' if entities.any? { |entity| entity.respond_to?(:locked?) && entity.locked? }
      with_operation(model, 'CJ Bridge: delete entities') do
        parents = entities.group_by(&:parent)
        parents.each { |parent, children| parent.entities.erase_entities(children) }
      end
      { deleted: ids }
    when 'save'
      model = active_model!
      raise ArgumentError, 'Untitled model cannot be saved without a path' if model.path.to_s.empty?
      { saved: model.save, path: model.path }
    when 'stop' then { stopped: stop }
    else raise ArgumentError, "Unknown command: #{command}"
    end
  end

  def self.process(path)
    id = File.basename(path, '.request.json')
    return unless id.match?(/\A[0-9a-f-]{36}\z/)
    response_path = File.join(@instance_queue, "#{id}.response.json")
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
        write_json(File.join(@instance_queue, 'session.json'), status)
        @last_heartbeat = Time.now
      end
      path = Dir.glob(File.join(@instance_queue, '*.request.json')).sort.first
      process(path) if path
    rescue StandardError => error
      puts "[CJBridge] #{error.class}: #{error.message}"
    ensure
      @busy = false
    end
  end

  def self.start
    FileUtils.mkdir_p(QUEUE_ROOT)
    stop if @timer
    @session_id = SecureRandom.uuid
    @instance_queue = File.join(QUEUE_ROOT, @session_id)
    FileUtils.mkdir_p(@instance_queue)
    @last_heartbeat = nil
    @timer = UI.start_timer(0.25, true) { tick }
    write_json(File.join(@instance_queue, 'session.json'), status)
    install_ui
    puts "[CJBridge] Started. Commands: #{COMMANDS.join(', ')}"
    true
  end

  def self.connect
    show_connection_panel
    true
  end

  def self.show_connection_panel
    if @connection_panel && @connection_panel.visible?
      @connection_panel.bring_to_front
      return
    end
    panel = UI::HtmlDialog.new(dialog_title: 'CJ — подключение', preferences_key: 'CJ_Bridge_Connection',
                              width: 520, height: 590, resizable: true, scrollable: true,
                              style: UI::HtmlDialog::STYLE_DIALOG)
    panel.set_file(File.join(__dir__, 'connection.html'))
    panel.add_action_callback('bridge_action') do |_context, action|
      message = nil
      begin
        case action
        when 'status' # Read state only.
        when 'mcp_check'
          raise 'Сначала подключите мост.' unless @timer
          unless @mcp_pid
            python = mcp_python
            launcher = python.sub(/python\.exe\z/i, 'pythonw.exe')
            raise "Python не найден: #{launcher}" unless File.file?(launcher)
            @mcp_output = File.join(@instance_queue, "mcp-check-#{SecureRandom.uuid}.json")
            @mcp_checked_session = @session_id
            @mcp_report = nil
            @mcp_pid = Process.spawn(launcher, File.join(__dir__, 'mcp', 'diagnose.py'),
                                     '--instance', @session_id, '--output', @mcp_output,
                                     out: File::NULL, err: File::NULL)
          end
        when 'connect'
          start unless @timer
          message = 'Мост готов принимать команды.'
        when 'restart'
          start
          message = 'Мост перезапущен. Codex должен заново выбрать этот экземпляр.'
        when 'stop'
          stop
          message = 'Приём команд остановлен.'
        when 'reload'
          ensure_development
          CJDevelopment.reload
          message = 'Плагин инсоляции обновлён из исходников.'
        when 'check'
          ensure_development
          report = CJDevelopment.check
          message = report[:passed] ? 'Проверки плагина прошли.' : 'Есть ошибки в проверках; см. reports/session_check.json.'
        else
          raise ArgumentError, 'Неизвестное действие'
        end
        poll_mcp_check
        data = status.merge(message: message, error: false, mcp: mcp_state)
      rescue StandardError, SyntaxError => error
        data = { running: !@timer.nil?, message: "#{error.class}: #{error.message}", error: true }
      end
      panel.execute_script("renderState(#{JSON.generate(data).gsub('<', '\\u003c')})")
    end
    @connection_panel = panel
    panel.show
  end

  def self.mcp_python
    File.join(ENV.fetch('LOCALAPPDATA'), 'Programs', 'Python', 'Python310', 'python.exe')
  end

  def self.source_stamp
    @loaded_source_stamp
  end

  def self.poll_mcp_check
    return unless @mcp_pid
    @mcp_report = JSON.parse(File.read(@mcp_output, encoding: 'UTF-8')) if File.file?(@mcp_output)
    if Process.waitpid(@mcp_pid, Process::WNOHANG)
      @mcp_pid = nil
      @mcp_report ||= { 'passed' => false, 'message' => 'Проверка завершилась без отчёта.' }
    end
  rescue Errno::ECHILD
    @mcp_pid = nil
  end

  def self.mcp_state
    { checking: !@mcp_pid.nil?, report: @mcp_report,
      stale: @mcp_checked_session && @mcp_checked_session != @session_id,
      command: mcp_python, argument: File.join(__dir__, 'mcp', 'server.py'), cwd: ROOT }
  end

  def self.install_ui
    unless @connect_command
      @connect_command = UI::Command.new('CJ Bridge: подключить') { connect }
      @connect_command.tooltip = 'Подключить CJ Bridge для текущего окна SketchUp'
      @connect_command.status_bar_text = 'Запустить мост для связи с этим экземпляром SketchUp'
      icon = File.join(__dir__, 'icons', 'cj_bridge.svg')
      @connect_command.small_icon = icon
      @connect_command.large_icon = icon
    end

    unless @menu_installed
      menu = UI.menu('Extensions').add_submenu('CJ Bridge')
      menu.add_item(@connect_command)
      menu.add_item('Подключить / перезапустить') { start }
      menu.add_item('Отключить') { stop }
      menu.add_item('Показать состояние') do
        current = status
        UI.messagebox("#{current[:model_name]}\n#{current[:model_path]}\nPID: #{current[:pid]}\nBridge: #{current[:running] ? 'online' : 'offline'}")
      end
      @menu_installed = true
    end

  end
  @connection_panel.close if @connection_panel
  @connection_panel = nil
  @loaded_source_stamp = File.mtime(__FILE__).to_f
end

CJBridge.start
