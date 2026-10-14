# frozen_string_literal: true
module CJUpdateChecks
  def self.probe_network
    return if @probe_started
    @probe_started = true
    @probe = Object.new.extend(CJ::Updates)
    path = File.join(CJDevelopment::ROOT, 'reports', 'update_network.json')
    @probe.define_singleton_method(:render) { |message| File.write(path, JSON.pretty_generate({passed:false,error:message})) }
    @probe.fetch(CJ::Updates::API) do |response|
      raise "HTTP #{response.status_code}" unless response.status_code == 200
      release = JSON.parse(response.body)
      name = "cj-insolation-#{release.fetch('tag_name').sub(/^v/,'')}.rbz"
      @probe.fetch(@probe.asset(release,'SHA256SUMS.txt')) do |sums|
        raise "Checksum HTTP #{sums.status_code}" unless sums.status_code == 200
        expected = sums.body.lines.map(&:split).find { |parts| parts[1] == name }
        raise 'Checksum missing' unless expected
        @probe.fetch(@probe.asset(release,name)) do |archive|
          passed = archive.status_code == 200 && Digest::SHA256.hexdigest(archive.body.b) == expected[0]
          File.write(path,JSON.pretty_generate({passed:passed,release:release['tag_name'],bytes:archive.body.bytesize,http:archive.status_code,installed:false}))
        end
      end
    end
  end
  def self.run
    probe_network
    checks = []
    updater = Object.new.extend(CJ::Updates)
    updater.define_singleton_method(:render) { |message = @message| @message = message }
    updater.define_singleton_method(:show) { @shown = true }
    updater.define_singleton_method(:fetch) do |url, &block|
      response = @responses.fetch(url)
      begin
        block.call(Struct.new(:status_code, :body).new(*response))
      rescue StandardError => e
        @busy = false
        render(e.message)
      end
    end
    updater.define_singleton_method(:install_archive) do |path|
      @installed_bytes = File.binread(path)
      @installed_path = path
      raise Interrupt if @cancel_install
      true
    end
    checks << {name: 'update_semantic_versions', passed: updater.newer?('v0.10.0', '0.9.0') && !updater.newer?('v0.2.0', '0.2.0') && !updater.newer?('v0.2.0-beta', '0.1.0')}
    release = {'tag_name'=>'v99.0.0', 'assets'=>['cj-insolation-99.0.0.rbz','SHA256SUMS.txt'].map { |name| {'name'=>name,'browser_download_url'=>CJ::Updates::RELEASES+'/download/v99.0.0/'+name} }}
    previous_check = Sketchup.read_default('CJ_Updates','last_check',0)
    begin
      updater.instance_variable_set(:@responses, {CJ::Updates::API=>[404,'']})
      updater.check
      checks << {name:'update_no_release',passed: !updater.instance_variable_get(:@busy) && !updater.instance_variable_get(:@release)}
      updater.instance_variable_set(:@responses, {CJ::Updates::API=>[403,'']})
      updater.check
      checks << {name:'update_http_error',passed: !updater.instance_variable_get(:@busy) && updater.instance_variable_get(:@message).include?('403')}
      updater.instance_variable_set(:@responses, {CJ::Updates::API=>[200,JSON.generate(release)]})
      updater.check(true)
      checks << {name:'update_available_notification',passed: !!updater.instance_variable_get(:@release) && updater.instance_variable_get(:@shown)}
      bytes = 'test archive bytes'.b
      responses = {updater.asset(release,'SHA256SUMS.txt')=>[200, "#{Digest::SHA256.hexdigest(bytes)}  cj-insolation-99.0.0.rbz\n"], updater.asset(release,'cj-insolation-99.0.0.rbz')=>[200,bytes]}
      updater.instance_variable_set(:@responses,responses)
      updater.install
      checks << {name:'update_verified_install_and_cleanup',passed: updater.instance_variable_get(:@installed_bytes)==bytes && updater.instance_variable_get(:@restart) && !File.exist?(updater.instance_variable_get(:@installed_path))}
      updater.instance_variable_set(:@restart,false)
      updater.instance_variable_set(:@release,release)
      updater.instance_variable_set(:@installed_bytes,nil)
      responses[updater.asset(release,'cj-insolation-99.0.0.rbz')]=[200,'corrupted']
      updater.install
      checks << {name:'update_corrupt_archive_not_installed',passed: updater.instance_variable_get(:@installed_bytes).nil? && !updater.instance_variable_get(:@busy)}
      responses[updater.asset(release,'cj-insolation-99.0.0.rbz')]=[200,bytes]
      updater.instance_variable_set(:@cancel_install,true)
      updater.install
      checks << {name:'update_cancel_cleanup',passed: !updater.instance_variable_get(:@restart) && !updater.instance_variable_get(:@busy) && !File.exist?(updater.instance_variable_get(:@installed_path))}
    ensure
      Sketchup.write_default('CJ_Updates','last_check',previous_check)
    end
    checks
  end
end
