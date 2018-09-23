require 'status_workflow/version'
require 'timeout'

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

  module ClassMethods
    def status_workflow(transitions)
      transitions.inject({}) do |memo, (from_status, to_statuses)|
        to_statuses.each do |to_status|
          memo[to_status] ||= []
          memo[to_status] << from_status
        end
        memo
      end.each do |to_status, from_statuses|
        define_method "enter_#{to_status}!" do
          lock_key = "status_workflow/#{self.class.name}/#{id}"
          Timeout.timeout(8, nil, "timeout waiting for #{self.class.name}/#{id} lock") do
            until StatusWorkflow.redis.set(lock_key, true, nx: true, ex: 4)
              sleep 0.2
            end
          end
          # got the lock, i have 3 (4 expiry on lock - 1 for safety) seconds to set it
          Timeout.timeout(3, nil, "timeout waiting for #{self.class.name}/#{id} status update") do
            # depend on #can_enter_X to reload
            raise InvalidTransition, "can't enter #{to_status} from #{status}, expected #{from_statuses.join('/')}" unless send("can_enter_#{to_status}?")
            update_columns status: to_status, status_changed_at: Time.now
          end
          StatusWorkflow.redis.del lock_key
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
