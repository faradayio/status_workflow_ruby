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

  def status_transition!(intermediate_to_status, final_to_status, prefix = nil)
    result = nil # what the block yields, return to the user
    before_status_transition = self.class.instance_variable_get(:@before_status_transition)
    intermediate_to_status = intermediate_to_status&.to_s
    final_to_status = final_to_status&.to_s
    prefix_ = prefix ? "#{prefix}_" : nil
    status_column = "#{prefix_}status"
    status_changed_at_column = "#{status_column}_changed_at"
    error_column = "#{status_column}_error"
    lock_obtained_at = nil
    lock_key = "status_workflow/#{self.class.name}/#{id}/#{status_column}"
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
      send "#{prefix_}can_enter_#{initial_to_status}?", true
      raise TooSlow, "#{lock_key} lost lock after checking status" if Time.now - lock_obtained_at > LOCK_EXPIRY
      if intermediate_to_status
        update_columns status_column => intermediate_to_status, status_changed_at_column => Time.now
        raise TooSlow, "#{lock_key} lost lock after setting intermediate status #{intermediate_to_status}" if Time.now - lock_obtained_at > LOCK_EXPIRY
      end
      # If a block was given, start a heartbeat thread
      if block_given?
        begin
          heartbeat = Thread.new do
            loop do
              StatusWorkflow.redis.expire lock_key, LOCK_EXPIRY
              lock_obtained_at = Time.now
              sleep LOCK_EXPIRY/2.0
            end
          end
          result = yield
          before_status_transition&.call
        rescue
          # If the block errors, set status to error and record the backtrace
          error = (["#{$!.class} #{$!.message}"] + $!.backtrace).join("\n")
          before_status_transition&.call
          status = read_attribute status_column
          update_columns status_column => "#{status}_error", status_changed_at_column => Time.now, error_column => error
          raise
        end
      end
      # Success!
      if intermediate_to_status
        send "#{prefix_}can_enter_#{final_to_status}?", true
        raise TooSlow, "#{lock_key} lost lock after checking final status" if Time.now - lock_obtained_at > LOCK_EXPIRY
      end
      update_columns status_column => final_to_status, status_changed_at_column => Time.now
    ensure
      raise TooSlow, "#{lock_key} lost lock" if Time.now - lock_obtained_at > LOCK_EXPIRY
      StatusWorkflow.redis.del lock_key
      heartbeat.kill if heartbeat
    end
    result
  end

  module ClassMethods
    def before_status_transition(&blk)
      @before_status_transition = blk
    end
    def status_workflow(workflows)
      if workflows.first.last.is_a?(Array)
        # default mode: use just status
        workflows = { nil => workflows }
      end
      workflows.each do |prefix, transitions|
        if prefix
          # no this is not a mistake, the localvar is prefix_
          prefix_ = "#{prefix}_"
          define_method "#{prefix_}status_transition!" do |*args, &blk|
            status_transition!(*(args+[prefix]), &blk)
          end
        end
        transitions.inject({}) do |memo, (from_status, to_statuses)|
          to_statuses.each do |to_status|
            to_status = to_status.to_sym
            memo[to_status] ||= Set.new
            memo[to_status] << from_status&.to_sym # support nil or strings/symbols
          end
          memo
        end.each do |to_status, from_statuses|
          define_method "#{prefix_}enter_#{to_status}!" do
            send "#{prefix_}status_transition!", nil, to_status
          end
          define_method "#{prefix_}can_enter_#{to_status}?" do |raise_error = false|
            reload
            status = read_attribute "#{prefix_}status"
            memo = from_statuses.include? status&.to_sym
            if raise_error and not memo
              raise InvalidTransition, "can't enter #{to_status} from #{status}, expected #{from_statuses.to_a.join('/')}"
            end
            memo
          end
          define_method "#{prefix_}enter_#{to_status}_if_possible" do
            begin; send("#{prefix_}enter_#{to_status}!"); rescue InvalidTransition; false; end
          end
        end
      end
    end
  end
end
