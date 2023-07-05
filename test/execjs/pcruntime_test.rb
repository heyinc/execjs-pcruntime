# frozen_string_literal: true

require 'test_helper'

module Execjs
  class PCRuntimeTest < Minitest::Test
    def test_that_it_has_a_version_number
      refute_nil ::Execjs::PCRuntime::VERSION
    end
  end
end
