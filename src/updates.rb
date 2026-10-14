# frozen_string_literal: true
require 'json'
require 'digest'
require 'tempfile'
module CJ
  module Updates
    extend self
    API = 'https://api.github.com/repos/Golyatar/cj-insolation/releases/latest'.freeze
    RELEASES = 'https://github.com/Golyatar/cj-insolation/releases'.freeze
    def newer?(tag, current = CJ::VERSION)
      return false unless tag.to_s.match?(/\Av?\d+\.\d+\.\d+\z/)
      (tag.sub(/^v/, '').split('.').map(&:to_i) <=> current.split('.').map(&:to_i)) == 1
    end
    def asset(release, name)
      item = release.fetch('assets', []).find { |a| a['name'] == name }
      raise "В выпуске отсутствует #{name}." unless item && item['browser_download_url'].to_s.start_with?(RELEASES + '/download/')
      item['browser_download_url']
    end
    def render(message = @message || 'Нажмите «Проверить» для поиска новой версии.')
      @message = message
      return unless @dialog && @dialog.visible?
      @dialog.execute_script("render(#{JSON.generate({message: message, busy: !!@busy, available: !!@release, restart: !!@restart})})")
    end
    def fetch(url, &done)
      request = Sketchup::Http::Request.new(url)
      request.headers = {'User-Agent' => 'CJ-Insolation'}
      @request = request
      finished = false
      timer = UI.start_timer(60, false) do
        unless finished
          finished = true
          request.cancel
          @busy = false
          render('Сервер не ответил. Проверьте соединение и повторите попытку.')
        end
      end
      request.start do |_req, response|
        next if finished
        finished = true
        UI.stop_timer(timer)
        begin
          done.call(response)
        rescue StandardError => e
          @busy = false
          render("Не удалось обновить: #{e.message}")
        end
      end
    end
    def check(silent = false)
      return if @busy || @restart
      @busy = true
      @release = nil
      render('Проверяем выпуски…')
      fetch(API) do |response|
        @busy = false
        if response.status_code == 404
          render('Публичных выпусков пока нет.')
          next
        end
        raise "GitHub: HTTP #{response.status_code}" unless response.status_code == 200
        release = JSON.parse(response.body)
        Sketchup.write_default('CJ_Updates', 'last_check', Time.now.to_i)
        if !release['prerelease'] && !release['draft'] && newer?(release['tag_name'])
          version = release['tag_name'].sub(/^v/, '')
          asset(release, "cj-insolation-#{version}.rbz")
          asset(release, 'SHA256SUMS.txt')
          @release = release
          render("Доступна версия #{version}. Можно скачать и установить её сейчас.")
          show if silent
        else
          render('У вас актуальная версия.')
        end
      end
    rescue StandardError => e
      @busy = false
      render("Проверка не удалась: #{e.message}")
    end
    def install
      return if @busy || !@release || @restart
      release = @release
      name = "cj-insolation-#{release['tag_name'].sub(/^v/, '')}.rbz"
      @busy = true
      render('Скачиваем и проверяем обновление…')
      fetch(asset(release, 'SHA256SUMS.txt')) do |sums|
        raise 'Не удалось скачать контрольную сумму.' unless sums.status_code == 200
        entry = sums.body.lines.map(&:split).find { |parts| parts[1] == name }
        raise 'Неверная контрольная сумма выпуска.' unless entry && entry[0].match?(/\A[0-9a-f]{64}\z/i)
        expected = entry[0].downcase
        fetch(asset(release, name)) do |archive|
          raise 'Не удалось скачать RBZ.' unless archive.status_code == 200
          bytes = archive.body.b
          raise 'Файл повреждён: контрольная сумма не совпадает.' unless Digest::SHA256.hexdigest(bytes) == expected
          file = Tempfile.new(['cj-update-', '.rbz'])
          begin
            file.binmode; file.write(bytes); file.close
            installed = install_archive(file.path)
            @restart = !!installed
            @release = nil if installed
            render(installed ? 'Обновление установлено. Сохраните работу и перезапустите SketchUp.' : 'Установка не завершена.')
          rescue Interrupt
            render('Установка отменена. Можно повторить попытку.')
          rescue Exception => e # SketchUp's installer can raise Exception, not just StandardError.
            render("Установщик не завершил обновление: #{e.message}")
          ensure
            file.close!; @busy = false; render
          end
        end
      end
    rescue StandardError => e
      @busy = false
      render("Установка не удалась: #{e.message}")
    end
    def install_archive(path)
      Sketchup.install_from_archive(path)
    end
    def show
      return @dialog.bring_to_front if @dialog && @dialog.visible?
      @dialog = UI::HtmlDialog.new(dialog_title: 'CJ — обновления', width: 490, height: 440, preferences_key: 'CJ_Updates_v2', resizable: true, scrollable: true)
      @dialog.set_html(<<~HTML)
        <!doctype html><html lang="ru"><meta charset="utf-8"><style>
        *{box-sizing:border-box}body{margin:0;padding:28px;font:14px 'Segoe UI',sans-serif;background:#f3f6fa;color:#192e43}header{background:#192e43;color:white;padding:22px;border-radius:16px}h1{font-size:24px;margin:0 0 6px}.badge{color:#ffd36a}section{background:white;padding:20px;border-radius:16px;margin:16px 0;border:1px solid #dee5ed}p{line-height:1.6}button{border:0;border-radius:9px;padding:12px 16px;font:600 14px 'Segoe UI';cursor:pointer;background:#e5ebf2;color:#192e43;margin:4px 6px 4px 0}button.primary{background:#ffd36a}button:disabled{opacity:.45;cursor:default}button:focus{outline:2px solid #3c8cce}small{color:#617287}
        </style><header><h1>CJ Инсоляция</h1><span class="badge">Установлена версия #{CJ::VERSION}</span></header>
        <section><p id="status" role="status" aria-live="polite">Проверка обновлений</p><button id="install" class="primary" hidden onclick="sketchup.install()">Установить обновление</button><button id="check" onclick="sketchup.check()">Проверить</button><button onclick="sketchup.releases()">Что нового ↗</button></section>
        <small>Проверяем новые версии при запуске, не чаще раза в день. Установка — по вашему нажатию.</small>
        <script>function render(s){document.getElementById('status').textContent=s.message;document.getElementById('check').disabled=s.busy||s.restart;document.getElementById('install').hidden=!s.available;document.getElementById('install').disabled=s.busy||s.restart}document.addEventListener('DOMContentLoaded',function(){sketchup.ready()})</script></html>
      HTML
      @dialog.add_action_callback('ready') { render }
      @dialog.add_action_callback('check') { check }
      @dialog.add_action_callback('install') { install }
      @dialog.add_action_callback('releases') { UI.openURL(RELEASES) }
      @dialog.show
    end
    unless const_defined?(:TOOLBAR_INSTALLED, false)
      command = UI::Command.new('Версия и обновления') { CJ::Updates.show }
      command.tooltip = 'Проверить и установить обновление CJ'
      command.small_icon = File.join(__dir__, 'icons', 'updates.svg')
      command.large_icon = command.small_icon
      UI.menu('Plugins').add_submenu('CJ').add_item(command) unless const_defined?(:UI_INSTALLED, false)
      UI.toolbar('CJ').add_item(command)
      UI_INSTALLED = true unless const_defined?(:UI_INSTALLED, false)
      TOOLBAR_INSTALLED = true
      UI.start_timer(15, false) { check(true) if Time.now.to_i - Sketchup.read_default('CJ_Updates', 'last_check', 0).to_i >= 86_400 }
    end
  end
end

