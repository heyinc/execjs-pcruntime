# frozen_string_literal: true

require 'execjs/pcruntime/version'
require 'execjs/pcruntime/context_process_runtime'
require 'execjs/runtimes'

module ExecJS
  # ExecJS::Runtimesモジュールの拡張
  module Runtimes
    PCRuntime = PCRuntime::ContextProcessRuntime.new(
      'Node.js (V8) Process as Context',
      %w[nodejs node]
    )

    runtimes.unshift(PCRuntime)
  end
end
