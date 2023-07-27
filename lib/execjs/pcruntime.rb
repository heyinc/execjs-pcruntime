# frozen_string_literal: true

require 'execjs'
require 'execjs/pcruntime/version'
require 'execjs/pcruntime/runtimes'

ExecJS.runtime = ExecJS::Runtimes.autodetect
