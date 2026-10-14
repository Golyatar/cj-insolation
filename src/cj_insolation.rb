# frozen_string_literal: true
require 'sketchup.rb'
require 'extensions.rb'
version_file = File.join(__dir__, 'version.rb')
version_file = File.join(__dir__, 'cj_insolation', 'version.rb') unless File.file?(version_file)
require version_file

module CJ
  module InsolationExtension
    VERSION = CJ::VERSION unless const_defined?(:VERSION, false)
    unless file_loaded?(__FILE__)
      extension = SketchupExtension.new('CJ Инсоляция — Владивосток', 'cj_insolation/main')
      extension.description = 'Расчёт нескольких инсоляционных точек, цветные лучи и поверхности.'
      extension.version = VERSION
      extension.creator = 'CJ'
      extension.copyright = 'CJ, 2026'
      Sketchup.register_extension(extension, true)
      file_loaded(__FILE__)
    end
  end
end
