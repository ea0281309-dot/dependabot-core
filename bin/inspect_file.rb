#!/usr/bin/env ruby
# typed: strict
# frozen_string_literal: true

ENV["BUNDLE_GEMFILE"] ||= File.expand_path("../Gemfile", __dir__)
require "bundler/setup"

require "json"
require "dependabot/file_inspector"

path = ARGV[0]

unless path
  warn "usage: bin/inspect_file.rb PATH"
  exit 1
end

begin
  result = Dependabot::FileInspector.new.inspect_path(path)
  puts JSON.pretty_generate(result)
rescue Errno::ENOENT, Errno::EACCES => e
  warn e.message
  exit 1
end
