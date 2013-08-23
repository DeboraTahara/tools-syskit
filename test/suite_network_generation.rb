if !ENV['SYSKIT_ENABLE_COVERAGE']
    ENV['SYSKIT_ENABLE_COVERAGE'] = '1'
end
require 'syskit/test'

require './test/network_generation/test_engine'
require './test/network_generation/test_merge_solver'
require './test/network_generation/test_logger'

Syskit.logger = Logger.new(File.open("/dev/null", 'w'))
Syskit.logger.level = Logger::DEBUG

