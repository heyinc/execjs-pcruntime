# frozen_string_literal: true

require 'execjs/pcruntime/version'
require 'execjs/pcruntime/runtimes'
require 'execjs'
ExecJS.runtime = ExecJS::Runtimes.autodetect
