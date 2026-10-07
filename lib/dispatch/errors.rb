module Dispatch
  # One validation problem: a machine-readable code, the JSON path it points at
  # (e.g. "rules[1].conditions[0].op") and a readable message.
  ValidationError = Struct.new(:code, :path, :message) do
    def to_s
      "#{code} at #{path}: #{message}"
    end
  end

  # Raised when a rules config, roster or claims file is invalid. Carries every
  # problem found, never just the first (Q9); nothing is partially loaded.
  class ConfigError < StandardError
    attr_reader :errors, :source

    def initialize(errors, source: nil)
      @errors = errors
      @source = source
      header = source ? "invalid #{source}" : "invalid config"
      super(([header + ":"] + errors.map { |e| "  #{e}" }).join("\n"))
    end
  end

  # Raised if something tries to assign beyond an adjuster's capacity.
  class CapacityError < StandardError; end

  # Collects ValidationErrors while walking a parsed JSON document.
  class ErrorCollector
    attr_reader :errors

    def initialize
      @errors = []
    end

    def add(code, path, message)
      @errors << ValidationError.new(code, path, message)
    end

    def any?
      !@errors.empty?
    end

    def raise_if_any!(source = nil)
      raise ConfigError.new(@errors, source: source) if any?
    end

    # Flags keys outside `allowed` as unknown_field and required keys that are absent as missing_field.
    def check_keys(hash, path, allowed:, required:)
      hash.each_key do |key|
        add("unknown_field", join(path, key), "unknown field #{key.inspect}") unless allowed.include?(key)
      end
      required.each do |key|
        add("missing_field", join(path, key), "missing required field #{key.inspect}") unless hash.key?(key)
      end
    end

    def join(path, key)
      path.nil? || path.empty? ? key.to_s : "#{path}.#{key}"
    end
  end

  UTF8_BOM = [0xEF, 0xBB, 0xBF].pack("C*").freeze

  # Parses JSON text. The text must be valid UTF-8; a leading BOM (Windows PowerShell 5.1
  # writes one) is stripped. Bad encoding and syntax errors become malformed_json at "$" (Q55).
  def self.parse_json(text, source: nil)
    require "json"
    bytes = text.b
    bytes = bytes.byteslice(UTF8_BOM.bytesize..) if bytes.start_with?(UTF8_BOM)
    utf8 = bytes.force_encoding(Encoding::UTF_8)
    raise_malformed("the file is not valid UTF-8", source) unless utf8.valid_encoding?

    JSON.parse(utf8)
  rescue JSON::ParserError => e
    raise_malformed(e.message.scrub.lines.first.to_s.strip, source)
  end

  def self.raise_malformed(message, source)
    raise ConfigError.new([ValidationError.new("malformed_json", "$", message)], source: source)
  end

  def self.read_json_file(path)
    parse_json(File.binread(path), source: path)
  end

  # Non-negative integer, excluding booleans (which are not Integers in Ruby anyway).
  def self.non_negative_integer?(value)
    value.is_a?(Integer) && value >= 0
  end

  # A JSON number that is finite: 1e400 parses to Infinity and must be rejected (Q55).
  def self.finite_number?(value)
    value.is_a?(Integer) || (value.is_a?(Float) && value.finite?)
  end

  def self.non_empty_string?(value)
    value.is_a?(String) && value.valid_encoding? && !value.strip.empty?
  end
end
