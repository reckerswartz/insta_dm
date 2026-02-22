# frozen_string_literal: true

require "shellwords"

module BinaryCommandResolver
  private

  def resolve_command_path(command)
    value = command.to_s.strip
    return value if value.empty?
    return value unless path_like_command?(value)

    home = ENV["HOME"].to_s
    expanded = value.gsub("${HOME}", home).gsub("$HOME", home)
    File.expand_path(expanded)
  rescue StandardError
    value
  end

  def command_available?(command)
    resolved = resolve_command_path(command)

    if path_like_command?(resolved)
      File.file?(resolved) && File.executable?(resolved)
    else
      system("command -v #{Shellwords.escape(resolved)} >/dev/null 2>&1")
    end
  end

  def path_like_command?(command)
    value = command.to_s
    value.include?(File::SEPARATOR) || value.start_with?(".", "~", "$")
  end
end
