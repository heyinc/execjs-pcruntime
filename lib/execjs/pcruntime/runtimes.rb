# frozen_string_literal: true

require 'execjs/runtimes'
require 'execjs/pcruntime/context_process_runtime'

module ExecJS
  # extends ExecJS::Runtimes
  module Runtimes
    PCRuntime = PCRuntime::ContextProcessRuntime.new(
      'Node.js (V8) Process as Context',
      %w[nodejs node]
    )

    runtimes.unshift(PCRuntime)
  end
end
