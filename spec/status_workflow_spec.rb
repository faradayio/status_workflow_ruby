ActiveRecord::Base.connection.execute <<-SQL
  CREATE TABLE pets (
    id serial primary key,
    status text,
    status_changed_at timestamp without time zone
  )
SQL
class Pet < ActiveRecord::Base
  before_create do
    self.status ||= 'sleep'
  end
  include StatusWorkflow
  status_workflow(
    sleep: [:fed],
    fed: [:sleep, :run],
    run: [:sleep],
  )
end

RSpec.describe StatusWorkflow do
  describe "pet example" do
    let(:pet) { Pet.create! }
    before do
      expect(pet.status).to eq('sleep')
    end
    it "wakes up and eats" do
      expect{pet.enter_fed!}.not_to raise_error
    end
    it "can't just go running when he wakes up" do
      expect{pet.enter_run!}.to raise_error(/expected.*fed/i)
    end
    it "won't blow up if you gently request a run" do
      expect{pet.enter_run_if_possible}.not_to raise_error
      expect(pet.status).to eq('sleep')
    end
    it "can do the whole routine" do
      expect{
        pet.enter_fed!
        pet.enter_run!
        pet.enter_sleep!
        pet.enter_fed!
      }.not_to raise_error
    end
    it "has locking" do
      pet1 = Pet.first
      pet2 = Pet.first
      t1 = Thread.new do
        pet1.enter_fed!
      end
      t2 = Thread.new do
        pet2.enter_fed!
      end
      t1_succeeded = begin; t1.join; true; rescue; false; end
      t2_succeeded = begin; t2.join; true; rescue; false; end
      expect(t1_succeeded ^ t2_succeeded).to be_truthy
    end
  end
end
