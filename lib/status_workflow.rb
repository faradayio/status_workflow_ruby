require 'status_workflow/version'
require 'timeout'
require 'set'

module StatusWorkflow
  class InvalidTransition < StandardError; end

  def self.included(klass)
    klass.extend ClassMethods
  end

  def self.redis=(redis)
    @redis = redis
  end

  def self.redis
    @redis or raise("please set StatusWorkflow.redis=")
  end

  LOCK_ACQUISITION_TIMEOUT = 8
  LOCK_EXPIRY = 4
  LOCK_CHECK_RATE = 0.2

  module ClassMethods
    def status_workflow(transitions)
      transitions.inject({}) do |memo, (from_status, to_statuses)|
        to_statuses.each do |to_status|
          memo[to_status] ||= Set.new
          memo[to_status] << from_status
        end
        memo
      end.each do |to_status, from_statuses|
        define_method "enter_#{to_status}!" do |&blk|
          lock_key = "status_workflow/#{self.class.name}/#{id}"
          # Give ourselves 8 seconds to get the lock, checking every 0.2 seconds
          Timeout.timeout(LOCK_ACQUISITION_TIMEOUT, nil, "timeout waiting for #{self.class.name}/#{id} lock") do
            until StatusWorkflow.redis.set(lock_key, true, nx: true, ex: LOCK_EXPIRY)
              sleep LOCK_CHECK_RATE
            end
          end
          heartbeat = nil
          begin
            # Give ourselves 2 seconds to check the status of the lock
            Timeout.timeout(2, nil, "timeout waiting for #{self.class.name}/#{id} status check") do
              # depend on #can_enter_X to reload
              raise InvalidTransition, "can't enter #{to_status} from #{status}, expected #{from_statuses.to_a.join('/')}" unless send("can_enter_#{to_status}?")
            end
            # If a block was given, start a heartbeat thread
            if blk
              begin
                heartbeat = Thread.new do
                  loop do
                    StatusWorkflow.redis.expire lock_key, LOCK_EXPIRY
                    sleep LOCK_EXPIRY/2
                  end
                end
                blk.call
              rescue
                # If the block errors, set status to error and record the backtrace
                error = (["#{$!.class} #{$!.message}"] + $!.backtrace).join("\n")
                update_columns status: 'error', status_changed_at: Time.now, error: error
                raise
              end
            end
            # Success!
            update_columns status: to_status, status_changed_at: Time.now
          ensure
            StatusWorkflow.redis.del lock_key
            heartbeat.kill if heartbeat
          end
          true
        end
        define_method "can_enter_#{to_status}?" do
          reload
          from_statuses.include? status&.to_sym
        end
        define_method "enter_#{to_status}_if_possible" do
          begin; send("enter_#{to_status}!"); rescue InvalidTransition; false; end
        end
      end
    end
  end
end
