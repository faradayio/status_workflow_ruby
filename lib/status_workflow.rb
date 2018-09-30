require 'status_workflow/version'
require 'timeout'
require 'set'

module StatusWorkflow
  class InvalidTransition < StandardError; end
  class TooSlow < StandardError; end

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

  def status_transition!(intermediate_to_status, final_to_status)
    intermediate_to_status = intermediate_to_status&.to_s
    final_to_status = final_to_status&.to_s
    lock_obtained_at = nil
    lock_key = "status_workflow/#{self.class.name}/#{id}"
    # Give ourselves 8 seconds to get the lock, checking every 0.2 seconds
    Timeout.timeout(LOCK_ACQUISITION_TIMEOUT, nil, "#{lock_key} timeout waiting for lock") do
      until StatusWorkflow.redis.set(lock_key, true, nx: true, ex: LOCK_EXPIRY)
        sleep LOCK_CHECK_RATE
      end
      lock_obtained_at = Time.now
    end
    heartbeat = nil
    initial_to_status = intermediate_to_status || final_to_status
    begin
      # depend on #can_enter_X to reload
      send "can_enter_#{initial_to_status}?", true
      raise TooSlow, "#{lock_key} lost lock after checking status" if Time.now - lock_obtained_at > LOCK_EXPIRY
      if intermediate_to_status
        update_columns status: intermediate_to_status, status_changed_at: Time.now
        raise TooSlow, "#{lock_key} lost lock after setting intermediate status #{intermediate_to_status}" if Time.now - lock_obtained_at > LOCK_EXPIRY
      end
      # If a block was given, start a heartbeat thread
      if block_given?
        begin
          heartbeat = Thread.new do
            loop do
              StatusWorkflow.redis.expire lock_key, LOCK_EXPIRY
              lock_obtained_at = Time.now
              sleep LOCK_EXPIRY/2
            end
          end
          yield
        rescue
          # If the block errors, set status to error and record the backtrace
          error = (["#{$!.class} #{$!.message}"] + $!.backtrace).join("\n")
          update_columns status: 'error', status_changed_at: Time.now, error: error
          raise
        end
      end
      # Success!
      if intermediate_to_status
        send "can_enter_#{final_to_status}?", true
        raise TooSlow, "#{lock_key} lost lock after checking final status" if Time.now - lock_obtained_at > LOCK_EXPIRY
      end
      update_columns status: final_to_status, status_changed_at: Time.now
    ensure
      raise TooSlow, "#{lock_key} lost lock" if Time.now - lock_obtained_at > LOCK_EXPIRY
      StatusWorkflow.redis.del lock_key
      heartbeat.kill if heartbeat
    end
    true
  end

  module ClassMethods
    def status_workflow(transitions)
      transitions.inject({}) do |memo, (from_status, to_statuses)|
        to_statuses.each do |to_status|
          memo[to_status] ||= Set.new
          memo[to_status] << from_status
        end
        memo
      end.each do |to_status, from_statuses|
        define_method "enter_#{to_status}!" do
          status_transition! nil, to_status
        end
        define_method "can_enter_#{to_status}?" do |raise_error = false|
          reload
          memo = from_statuses.include? status&.to_sym
          if raise_error and not memo
            raise InvalidTransition, "can't enter #{to_status} from #{status}, expected #{from_statuses.to_a.join('/')}"
          end
          memo
        end
        define_method "enter_#{to_status}_if_possible" do
          begin; send("enter_#{to_status}!"); rescue InvalidTransition; false; end
        end
      end
    end
  end
end
