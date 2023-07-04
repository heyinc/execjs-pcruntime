require 'test_helper'

class Execjs::PCRuntimeTest < Minitest::Test
  def test_that_it_has_a_version_number
    refute_nil ::Execjs::PCRuntime::VERSION
  end
end
