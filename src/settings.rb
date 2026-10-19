# frozen_string_literal: true
require 'json'
require 'base64'

module CJ
  module Settings
    extend self
    KEY = 'CJ_Settings_v1' unless const_defined?(:KEY, false)

    def values
      stored = Sketchup.read_default(KEY, 'values', '{}') || '{}'
      raise ArgumentError unless stored.is_a?(String)
      stored = Base64.strict_decode64(stored.delete_prefix('b64:')) if stored.start_with?('b64:')
      raw = JSON.parse(stored)
      validate({ 'window' => WindowComponents::DEFAULTS, 'mode' => 'lines',
                 'radius' => ResultStyle.radius, 'live' => true }.merge(raw))
    rescue JSON::ParserError, ArgumentError, TypeError, RuntimeError
      { 'window' => WindowComponents::DEFAULTS.dup, 'mode' => 'lines', 'radius' => 100.0, 'live' => true }
    end

    def validate(data)
      raise ArgumentError, 'Неверные настройки.' unless data.is_a?(Hash)
      WindowComponents.validate(data['window'])
      raise ArgumentError, 'Выберите вид результата.' unless %w[lines surface summary].include?(data['mode'])
      r = data['radius']
      raise ArgumentError, 'Радиус: от 0 до 10000 мм.' unless r.is_a?(Numeric) && r.finite? && r.between?(0, 10000)
      raise ArgumentError, 'Неверный режим пересчёта.' unless [true, false].include?(data['live'])
      data.slice('window', 'mode', 'radius', 'live')
    end

    def save(data)
      data = validate(data)
      # SketchUp 2023 on Windows cannot round-trip quotes in default strings.
      encoded = 'b64:' + Base64.strict_encode64(JSON.generate(data))
      raise 'Не удалось сохранить настройки.' unless Sketchup.write_default(KEY, 'values', encoded)
      Sketchup.write_default('CJ_ResultStyle', 'radius_mm', data['radius'])
      data
    end

    def mode
      values['mode'].to_sym
    end

    def show
      return @dialog.bring_to_front if @dialog && @dialog.visible?
      @dialog = UI::HtmlDialog.new(dialog_title: 'Настройки CJ', preferences_key: KEY,
                                  width: 540, height: 720, resizable: true, scrollable: true)
      labels = ['Ширина окна', 'Высота окна', 'Толщина стены / откосов', 'Посадка внутренней линии', 'Глубина рамы', 'Ширина рамы']
      fields = labels.each_with_index.map { |label, i| "<label>#{label}, мм<input id='w#{i}' type='number' min='0.01' step='any' required></label>" }.join
      @dialog.set_html(<<~HTML)
        <!doctype html><html lang="ru"><meta charset="utf-8"><style>
        *{box-sizing:border-box}body{margin:0;padding:24px;background:#f3f6fa;color:#192e43;font:14px 'Segoe UI',sans-serif}
        h1{font-size:24px;margin:0 0 16px}h2{font-size:17px;margin-top:0}section{padding:18px;background:white;border:1px solid #dee5ed;border-radius:12px;margin-bottom:14px}
        label{display:flex;align-items:center;justify-content:space-between;gap:12px;margin:10px 0}input[type=number]{width:110px}input,select{font:inherit;padding:8px;border:1px solid #c9d5e1;border-radius:6px}
        p{color:#526171;line-height:1.5}button{padding:12px 20px;background:#ffd36a;border:0;border-radius:8px;font:600 14px 'Segoe UI';cursor:pointer}#error{color:#c53939}
        </style><h1>Настройки CJ</h1><form id="form"><section><h2>Окно</h2>#{fields}<p>Размеры применяются при следующей вставке окна.</p></section>
        <section><h2>Результат</h2><label>Вид построения<select id="mode"><option value="lines">Линии</option><option value="surface">Поверхность</option><option value="summary">Итоги</option></select></label>
        <label>Радиус маркера точки, мм<input id="radius" type="number" min="0" max="10000" step="any" required></label><p>0 — без сферы. Вид и радиус применяются при следующем расчёте.</p></section>
        <section><h2>Перемещение точек</h2><label><span>Автопересчёт после перемещения</span><input id="live" type="checkbox"></label><p>Выделите одну или несколько точек рамкой или с Shift и переместите обычным Move (M). После завершения пересчитаются перемещённые точки. При выключении используйте «Пересчитать точки CJ».</p></section>
        <button type="submit">Сохранить</button><p id="error" role="alert"></p></form><script>
        const initial=#{JSON.generate(values)};
        initial.window.forEach((v,i)=>document.getElementById('w'+i).value=v);
        document.getElementById('mode').value=initial.mode;document.getElementById('radius').value=initial.radius;document.getElementById('live').checked=initial.live;
        document.getElementById('form').onsubmit=e=>{e.preventDefault();sketchup.save_settings(JSON.stringify({window:Array.from({length:6},(_,i)=>Number(document.getElementById('w'+i).value)),mode:document.getElementById('mode').value,radius:Number(document.getElementById('radius').value),live:document.getElementById('live').checked}));};
        </script></html>
      HTML
      @dialog.add_action_callback('save_settings') do |_context, raw|
        begin
          save(JSON.parse(raw))
          @dialog.close
        rescue StandardError => error
          @dialog.execute_script("document.getElementById('error').textContent=#{JSON.generate(error.message)}")
        end
      end
      @dialog.show
    end
  end
end
