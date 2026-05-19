# typed: strict
# frozen_string_literal: true

require "find"
require "set"
require "sorbet-runtime"

module Dependabot
  class FileInspector
    extend T::Sig

    IGNORED_DIRECTORIES = T.let(
      %w[.bundle .git build coverage dist node_modules tmp vendor].freeze,
      T::Array[String]
    )

    LONG_LINE_LIMIT = 120

    sig { params(path: String).returns(T::Hash[Symbol, T.untyped]) }
    def inspect_path(path)
      absolute_path = File.expand_path(path)
      raise Errno::ENOENT, absolute_path unless File.exist?(absolute_path)

      if File.directory?(absolute_path)
        inspect_directory(absolute_path)
      else
        inspect_file(absolute_path)
      end
    end

    private

    sig { params(path: String).returns(T::Hash[Symbol, T.untyped]) }
    def inspect_directory(path)
      files = T.let([], T::Array[T::Hash[Symbol, T.untyped]])

      Find.find(path) do |entry|
        if File.directory?(entry)
          if entry != path && ignored_directory?(File.basename(entry))
            Find.prune
          end
          next
        end

        next if File.symlink?(entry)

        files << inspect_file(entry)
      end

      files.sort_by! { |file| file.fetch(:path) }
      file_types = file_type_breakdown(files)
      issue_count = files.sum { |file| file.fetch(:potential_issues).length }

      {
        path: path,
        kind: "directory",
        file_count: files.length,
        file_types: file_types,
        potential_issue_count: issue_count,
        summary: directory_summary(files, file_types, issue_count),
        files: files
      }
    end

    sig { params(path: String).returns(T::Hash[Symbol, T.untyped]) }
    def inspect_file(path)
      raw_content = File.binread(path)

      return binary_file_result(path, raw_content.bytesize) if binary_content?(raw_content)

      content = raw_content.encode("UTF-8", invalid: :replace, undef: :replace, replace: "�")
      lines = content.lines
      file_type = file_type_for(path, content)
      symbols = extract_symbols(file_type, lines)
      issues = detect_potential_issues(file_type, lines, content)

      {
        path: path,
        kind: "file",
        file_type: file_type,
        summary: file_summary(file_type, symbols, lines),
        main_classes: symbols.fetch(:classes),
        main_functions: symbols.fetch(:functions),
        potential_issues: issues,
        line_count: lines.length,
        byte_size: raw_content.bytesize
      }
    end

    sig { params(path: String, byte_size: Integer).returns(T::Hash[Symbol, T.untyped]) }
    def binary_file_result(path, byte_size)
      {
        path: path,
        kind: "file",
        file_type: "binary",
        summary: "Binary file (#{byte_size} bytes) skipped from structural analysis.",
        main_classes: [],
        main_functions: [],
        potential_issues: [],
        line_count: 0,
        byte_size: byte_size
      }
    end

    sig { params(content: String).returns(T::Boolean) }
    def binary_content?(content)
      content.include?("\x00")
    end

    sig { params(directory_name: String).returns(T::Boolean) }
    def ignored_directory?(directory_name)
      IGNORED_DIRECTORIES.include?(directory_name)
    end

    sig { params(files: T::Array[T::Hash[Symbol, T.untyped]]).returns(T::Hash[String, Integer]) }
    def file_type_breakdown(files)
      files.each_with_object(T.let(Hash.new(0), T::Hash[String, Integer])) do |file, counts|
        counts[file.fetch(:file_type)] += 1
      end
    end

    sig do
      params(
        files: T::Array[T::Hash[Symbol, T.untyped]],
        file_types: T::Hash[String, Integer],
        issue_count: Integer
      ).returns(String)
    end
    def directory_summary(files, file_types, issue_count)
      if files.empty?
        "Directory contains no inspectable files."
      else
        type_summary = file_types.sort_by { |type, _count| type }.map { |type, count| "#{type}: #{count}" }.join(", ")
        issue_summary = issue_count.zero? ? "no potential issues" : "#{issue_count} potential issue#{issue_count == 1 ? "" : "s"}"
        "Directory contains #{files.length} file#{files.length == 1 ? "" : "s"} across #{file_types.length} file type#{file_types.length == 1 ? "" : "s"} (#{type_summary}); #{issue_summary}."
      end
    end

    sig do
      params(
        file_type: String,
        symbols: T::Hash[Symbol, T::Array[String]],
        lines: T::Array[String]
      ).returns(String)
    end
    def file_summary(file_type, symbols, lines)
      classes = symbols.fetch(:classes)
      functions = symbols.fetch(:functions)

      if file_type == "binary"
        return "Binary file skipped from structural analysis."
      end

      parts = []
      parts << names_summary(classes, "class", "classes") if classes.any?
      parts << names_summary(functions, "function", "functions") if functions.any?

      if parts.empty?
        "#{human_file_type(file_type)} file with #{lines.length} line#{lines.length == 1 ? "" : "s"} and no obvious classes or functions."
      else
        "#{human_file_type(file_type)} file with #{parts.join('; ')}."
      end
    end

    sig { params(file_type: String).returns(String) }
    def human_file_type(file_type)
      case file_type
      when "javascript" then "JavaScript"
      when "typescript" then "TypeScript"
      when "ruby" then "Ruby"
      when "python" then "Python"
      when "shell" then "Shell"
      when "yaml" then "YAML"
      when "json" then "JSON"
      when "markdown" then "Markdown"
      when "dockerfile" then "Dockerfile"
      when "makefile" then "Makefile"
      when "binary" then "Binary"
      else file_type.capitalize
      end
    end

    sig { params(names: T::Array[String], noun: String, plural_noun: String).returns(String) }
    def names_summary(names, noun, plural_noun)
      preview = names.take(3).join(", ")
      preview += ", …" if names.length > 3

      "#{names.length} #{names.length == 1 ? noun : plural_noun} (#{preview})"
    end

    sig { params(file_type: String, lines: T::Array[String]).returns(T::Hash[Symbol, T::Array[String]]) }
    def extract_symbols(file_type, lines)
      classes = T.let(Set.new, T::Set[String])
      functions = T.let(Set.new, T::Set[String])

      lines.each do |line|
        case file_type
        when "ruby"
          if (match = line.match(/^\s*(?:class|module)\s+([A-Z][A-Za-z0-9_:]*)/))
            classes.add(match[1])
          end
          if (match = line.match(/^\s*def\s+(?:self\.)?([a-zA-Z_][a-zA-Z0-9_!?=]*)/))
            functions.add(match[1])
          end
        when "python"
          if (match = line.match(/^\s*class\s+([A-Za-z_][A-Za-z0-9_]*)/))
            classes.add(match[1])
          end
          if (match = line.match(/^\s*def\s+([A-Za-z_][A-Za-z0-9_]*)/))
            functions.add(match[1])
          end
        when "javascript", "typescript"
          if (match = line.match(/^\s*(?:export\s+)?(?:default\s+)?class\s+([A-Za-z_$][A-Za-z0-9_$]*)/))
            classes.add(match[1])
          end
          if (match = line.match(/^\s*(?:export\s+)?function\s+([A-Za-z_$][A-Za-z0-9_$]*)/))
            functions.add(match[1])
          end
          if (match = line.match(/^\s*(?:export\s+)?(?:const|let|var)\s+([A-Za-z_$][A-Za-z0-9_$]*)\s*=\s*(?:async\s+)?(?:\([^)]*\)|[A-Za-z_$][A-Za-z0-9_$]*)\s*=>/))
            functions.add(match[1])
          end
        when "shell"
          if (match = line.match(/^\s*function\s+([A-Za-z_][A-Za-z0-9_]*)/))
            functions.add(match[1])
          end
        end
      end

      {
        classes: classes.to_a,
        functions: functions.to_a
      }
    end

    sig { params(file_type: String, lines: T::Array[String], content: String).returns(T::Array[T::Hash[Symbol, T.untyped]]) }
    def detect_potential_issues(file_type, lines, content)
      issues = T.let([], T::Array[T::Hash[Symbol, T.untyped]])

      lines.each_with_index do |line, index|
        line_number = index + 1
        stripped_line = line.delete_suffix("\n").delete_suffix("\r")

        if stripped_line.match?(/TODO|FIXME|HACK|XXX/i)
          issues << issue(line_number, "Contains a TODO/FIXME marker", "info")
        end

        if stripped_line.length > LONG_LINE_LIMIT
          issues << issue(line_number, "Line exceeds #{LONG_LINE_LIMIT} characters", "warning")
        end

        if stripped_line.match?(/[ \t]+\z/)
          issues << issue(line_number, "Trailing whitespace", "warning")
        end
      end

      issues << issue(nil, "File does not end with a newline", "info") unless content.end_with?("\n")
      issues << issue(nil, "File is empty", "info") if lines.empty?

      issues.concat(language_specific_issues(file_type, lines))
      issues
    end

    sig { params(file_type: String, lines: T::Array[String]).returns(T::Array[T::Hash[Symbol, T.untyped]]) }
    def language_specific_issues(file_type, lines)
      case file_type
      when "ruby"
        ruby_issues(lines)
      when "python"
        python_issues(lines)
      when "javascript", "typescript"
        javascript_issues(lines)
      else
        []
      end
    end

    sig { params(lines: T::Array[String]).returns(T::Array[T::Hash[Symbol, T.untyped]]) }
    def ruby_issues(lines)
      issues = T.let([], T::Array[T::Hash[Symbol, T.untyped]])
      lines.each_with_index do |line, index|
        next unless line.match?(/^\s*rescue(?:\s+StandardError|\s*=>|\s*$)/)

        issues << issue(index + 1, "Broad rescue clause may hide failures", "warning")
      end
      issues
    end

    sig { params(lines: T::Array[String]).returns(T::Array[T::Hash[Symbol, T.untyped]]) }
    def python_issues(lines)
      issues = T.let([], T::Array[T::Hash[Symbol, T.untyped]])
      lines.each_with_index do |line, index|
        if line.match?(/^\s*except\s*:\s*$/)
          issues << issue(index + 1, "Bare except clause may hide failures", "warning")
        elsif line.match?(/^\s*except\s+Exception\s*:/)
          issues << issue(index + 1, "Catching Exception broadly may hide failures", "warning")
        end

        if line.match?(/\beval\s*\(/) || line.match?(/\bexec\s*\(/)
          issues << issue(index + 1, "Uses dynamic code execution", "warning")
        end
      end
      issues
    end

    sig { params(lines: T::Array[String]).returns(T::Array[T::Hash[Symbol, T.untyped]]) }
    def javascript_issues(lines)
      issues = T.let([], T::Array[T::Hash[Symbol, T.untyped]])
      lines.each_with_index do |line, index|
        if line.match?(/\beval\s*\(/) || line.match?(/\bnew Function\s*\(/)
          issues << issue(index + 1, "Uses dynamic code execution", "warning")
        end

        if line.match?(/\bdocument\.write\s*\(/) || line.match?(/\binnerHTML\s*=/)
          issues << issue(index + 1, "Touches browser DOM in a potentially unsafe way", "warning")
        end
      end
      issues
    end

    sig do
      params(
        line: T.nilable(Integer),
        message: String,
        severity: String
      ).returns(T::Hash[Symbol, T.untyped])
    end
    def issue(line, message, severity)
      {
        line: line,
        severity: severity,
        message: message
      }
    end

    sig { params(path: String, content: String).returns(String) }
    def file_type_for(path, content)
      basename = File.basename(path)
      extension = File.extname(basename).downcase
      shebang = content.lines.first.to_s

      return "ruby" if ruby_filename?(basename, extension) || shebang.include?("ruby")
      return "python" if python_filename?(basename, extension) || shebang.match?(/python\d?/i)
      return "javascript" if javascript_filename?(basename, extension) || shebang.match?(/node|javascript/i)
      return "typescript" if typescript_filename?(basename, extension)
      return "shell" if shell_filename?(basename, extension) || shebang.match?(/(?:ba|z)?sh/i)
      return "yaml" if yaml_filename?(basename, extension)
      return "json" if json_filename?(basename, extension)
      return "markdown" if markdown_filename?(basename, extension)
      return "dockerfile" if dockerfile_filename?(basename, extension)
      return "makefile" if makefile_filename?(basename, extension)

      "text"
    end

    sig { params(basename: String, extension: String).returns(T::Boolean) }
    def ruby_filename?(basename, extension)
      extension == ".rb" || %w[Gemfile Rakefile].include?(basename)
    end

    sig { params(basename: String, extension: String).returns(T::Boolean) }
    def python_filename?(basename, extension)
      extension == ".py" || extension == ".pyi"
    end

    sig { params(basename: String, extension: String).returns(T::Boolean) }
    def javascript_filename?(basename, extension)
      extension == ".js" || extension == ".mjs" || extension == ".cjs"
    end

    sig { params(basename: String, extension: String).returns(T::Boolean) }
    def typescript_filename?(basename, extension)
      extension == ".ts" || extension == ".tsx"
    end

    sig { params(basename: String, extension: String).returns(T::Boolean) }
    def shell_filename?(basename, extension)
      extension == ".sh" || extension == ".bash"
    end

    sig { params(basename: String, extension: String).returns(T::Boolean) }
    def yaml_filename?(basename, extension)
      extension == ".yml" || extension == ".yaml"
    end

    sig { params(basename: String, extension: String).returns(T::Boolean) }
    def json_filename?(basename, extension)
      extension == ".json" || basename == "package-lock.json"
    end

    sig { params(basename: String, extension: String).returns(T::Boolean) }
    def markdown_filename?(basename, extension)
      extension == ".md" || basename == "README" || basename.end_with?(".mdown")
    end

    sig { params(basename: String, extension: String).returns(T::Boolean) }
    def dockerfile_filename?(basename, extension)
      basename.start_with?("Dockerfile")
    end

    sig { params(basename: String, extension: String).returns(T::Boolean) }
    def makefile_filename?(basename, extension)
      extension.empty? && %w[Makefile GNUmakefile BSDmakefile].include?(basename)
    end
  end
end
