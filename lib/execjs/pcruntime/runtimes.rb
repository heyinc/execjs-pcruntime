# frozen_string_literal: true

require "execjs/pcruntime/version"
require "execjs/pcruntime/context_process_runtime"
require "execjs/runtimes"

module ExecJS
  module Runtimes
    PCRuntime = PCRuntime::ContextProcessRuntime.new(
      name:        "Node.js (V8) fast",
      command:     ["nodejs", "node"],
      runner_path: File.expand_path('../runner.js', __FILE__),
    )

    runtimes.unshift(PCRuntime)
  end
end
