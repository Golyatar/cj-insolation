# frozen_string_literal: true
require 'sketchup.rb'
require 'extensions.rb'

module CJ
  module InsolationExtension
    VERSION = '0.1.0'.freeze unless const_defined?(:VERSION, false)
    unless file_loaded?(__FILE__)
      extension = SketchupExtension.new('CJ Инсоляция — Владивосток', 'cj_insolation/main')
      extension.description = 'Расчёт нескольких инсоляционных точек, цветные лучи и поверхности, CSV-отчёт.'
      extension.version = VERSION
      extension.creator = 'CJ'
      extension.copyright = 'CJ, 2026'
      Sketchup.register_extension(extension, true)
      file_loaded(__FILE__)
    end
  end
end
