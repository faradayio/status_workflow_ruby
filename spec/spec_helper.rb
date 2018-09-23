require 'bundler/setup'
require 'status_workflow'

require 'pry'

require 'redis'
StatusWorkflow.redis = Redis.new

require 'fileutils'
require 'active_record'
system 'dropdb status_workflow_test'
system 'createdb status_workflow_test'
ActiveRecord::Base.establish_connection 'postgres://localhost/status_workflow_test'
FileUtils.mkdir_p 'log'
ActiveRecord::Base.logger = Logger.new('log/test.log')

require 'database_cleaner'

DatabaseCleaner.strategy = :truncation

RSpec.configure do |config|
  config.before(:each) do
    StatusWorkflow.redis.flushdb
    DatabaseCleaner.start
  end

  config.after(:each) do
    DatabaseCleaner.clean
  end

  # Enable flags like --only-failures and --next-failure
  config.example_status_persistence_file_path = '.rspec_status'

  # Disable RSpec exposing methods globally on `Module` and `main`
  config.disable_monkey_patching!

  config.expect_with :rspec do |c|
    c.syntax = :expect
  end
end
