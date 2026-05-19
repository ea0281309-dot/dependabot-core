# typed: false
# frozen_string_literal: true

require "fileutils"
require "spec_helper"
require "dependabot/file_inspector"
require "tmpdir"

RSpec.describe Dependabot::FileInspector do
  subject(:inspector) { described_class.new }

  def write_file(path, content)
    FileUtils.mkdir_p(File.dirname(path))
    File.write(path, content)
    path
  end

  describe "#inspect" do
    it "analyzes ruby files" do
      Dir.mktmpdir do |dir|
        path = write_file(
          File.join(dir, "sample.rb"),
          <<~RUBY
            class Sample
              def run
                puts "hello" # TODO: remove debugging output
              rescue StandardError
              end
          RUBY
        )

        result = inspector.inspect_path(path)

        expect(result[:kind]).to eq("file")
        expect(result[:file_type]).to eq("ruby")
        expect(result[:main_classes]).to eq(["Sample"])
        expect(result[:main_functions]).to include("run")
        expect(result[:summary]).to include("Ruby file")
        expect(result[:potential_issues].map { |issue| issue[:message] }).to include(
          "Contains a TODO/FIXME marker",
          "Broad rescue clause may hide failures"
        )
      end
    end

    it "analyzes python files" do
      Dir.mktmpdir do |dir|
        path = write_file(
          File.join(dir, "sample.py"),
          <<~PYTHON
            class Widget:
                def build(self):
                    try:
                        return eval("1 + 1")
                    except:
                        return None
          PYTHON
        )

        result = inspector.inspect_path(path)

        expect(result[:kind]).to eq("file")
        expect(result[:file_type]).to eq("python")
        expect(result[:main_classes]).to eq(["Widget"])
        expect(result[:main_functions]).to include("build")
        expect(result[:potential_issues].map { |issue| issue[:message] }).to include(
          "Bare except clause may hide failures",
          "Uses dynamic code execution"
        )
      end
    end

    it "analyzes javascript files" do
      Dir.mktmpdir do |dir|
        path = write_file(
          File.join(dir, "sample.js"),
          <<~JAVASCRIPT
            export class Widget {}

            export const build = () => {
              document.write("hello");
            };
          JAVASCRIPT
        )

        result = inspector.inspect_path(path)

        expect(result[:kind]).to eq("file")
        expect(result[:file_type]).to eq("javascript")
        expect(result[:main_classes]).to eq(["Widget"])
        expect(result[:main_functions]).to include("build")
        expect(result[:potential_issues].map { |issue| issue[:message] }).to include(
          "Touches browser DOM in a potentially unsafe way"
        )
      end
    end

    it "analyzes directories recursively and skips ignored directories" do
      Dir.mktmpdir do |dir|
        write_file(
          File.join(dir, "app", "sample.rb"),
          <<~RUBY
            module Example
              def self.call
              end
            end
          RUBY
        )
        write_file(
          File.join(dir, "scripts", "sample.js"),
          <<~JAVASCRIPT
            export function run() {}
          JAVASCRIPT
        )
        write_file(
          File.join(dir, ".git", "ignored.rb"),
          <<~RUBY
            class Ignored
            end
          RUBY
        )

        result = inspector.inspect_path(dir)

        expect(result[:kind]).to eq("directory")
        expect(result[:file_count]).to eq(2)
        expect(result[:file_types]).to eq("javascript" => 1, "ruby" => 1)
        expect(result[:files].map { |file| File.basename(file[:path]) }).to contain_exactly("sample.rb", "sample.js")
      end
    end
  end
end
