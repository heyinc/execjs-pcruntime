# Copied from https://github.com/rails/execjs/blob/v2.8.1/test/bench_execjs.rb
# Released under MIT License
#
# Copyright (c) 2015-2016 Sam Stephenson
# Copyright (c) 2015-2016 Josh Peek
#
# Permission is hereby granted, free of charge, to any person obtaining
# a copy of this software and associated documentation files (the
# "Software"), to deal in the Software without restriction, including
# without limitation the rights to use, copy, modify, merge, publish,
# distribute, sublicense, and/or sell copies of the Software, and to
# permit persons to whom the Software is furnished to do so, subject to
# the following conditions:
#
# The above copyright notice and this permission notice shall be
# included in all copies or substantial portions of the Software.
#
# THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND,
# EXPRESS OR IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF
# MERCHANTABILITY, FITNESS FOR A PARTICULAR PURPOSE AND
# NONINFRINGEMENT. IN NO EVENT SHALL THE AUTHORS OR COPYRIGHT HOLDERS BE
# LIABLE FOR ANY CLAIM, DAMAGES OR OTHER LIABILITY, WHETHER IN AN ACTION
# OF CONTRACT, TORT OR OTHERWISE, ARISING FROM, OUT OF OR IN CONNECTION
# WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE SOFTWARE.
require 'benchmark'
require 'execjs'

TIMES = 10
SOURCE = File.read(File.expand_path("../fixtures/coffee-script.js", __FILE__)).freeze

Benchmark.bmbm do |x|
  ExecJS::Runtimes.runtimes.each do |runtime|
    next if !runtime.available? || runtime.deprecated?

    x.report(runtime.name) do
      ExecJS.runtime = runtime
      context = ExecJS.compile(SOURCE)

      TIMES.times do
        context.call("CoffeeScript.eval", "((x) -> x * x)(8)")
      end
    end
  end
end
