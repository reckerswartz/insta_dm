require "minitest/assertions"

module MinitestAssertionsAdapter
  include Minitest::Assertions

  attr_writer :assertions

  def assertions
    @assertions ||= 0
  end

  def assert_not_nil(object, msg = nil)
    refute_nil(object, msg)
  end

  def assert_not_includes(collection, object, msg = nil)
    refute_includes(collection, object, msg)
  end
end

RSpec.configure do |config|
  config.include MinitestAssertionsAdapter
end
