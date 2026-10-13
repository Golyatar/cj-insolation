# frozen_string_literal: true
module CJ
  module Loader
    extend self

    DEV_FILE = File.expand_path('cj.rb', __dir__)

    def reload
      puts "[CJ::Loader] loading: #{DEV_FILE}"
      load DEV_FILE
      true
    rescue => e
      puts "[CJ::Loader] ERROR: #{e.class}: #{e.message}"
      puts e.backtrace
      false
    end
  end
end

CJ::Loader.reload