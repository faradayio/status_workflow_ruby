ActiveRecord::Base.connection.execute <<-SQL
  CREATE TABLE pets (
    id serial primary key,
    status text,
    status_changed_at timestamp without time zone,
    error text
  )
SQL
class Pet < ActiveRecord::Base
  before_create do
    self.status ||= 'sleep'
  end
  include StatusWorkflow
  status_workflow(
    sleep: [:feeding],
    feeding: [:fed],
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
      expect{pet.enter_feeding!}.not_to raise_error
    end
    it "sets status_changed_at" do
      expect{pet.enter_feeding!}.to change{pet.reload.status_changed_at}
    end
    it "can't just go running when he wakes up" do
      expect{pet.enter_run!}.to raise_error(/expected.*fed/i)
    end
    it "won't blow up if you gently request a run" do
      expect{pet.enter_run_if_possible}.not_to raise_error
      expect(pet.status).to eq('sleep')
    end
    it "can set an intermediate status with block" do
      expect(pet.status).to eq('sleep')
      pet.status_transition!(:feeding, :fed) do
        expect expect(pet.status).to eq('feeding')
      end
      expect expect(pet.status).to eq('fed')
    end
    it "can set error on block" do
      expect {
        pet.status_transition!(:feeding, :fed) do
          raise "nyet"
        end
      }.to raise_error(/nyet/)
      pet.reload
      expect(pet.error).to match(/RuntimeError.*nyet/)
      expect(pet.status).to eq('error')
    end
    it "can do the whole routine" do
      expect{
        pet.enter_feeding!
        pet.enter_fed!
        pet.enter_run!
        pet.enter_sleep!
        pet.enter_feeding!
      }.not_to raise_error
    end
    it "has locking" do
      copy1 = Pet.first
      copy2 = Pet.first
      t1 = Thread.new do
        copy1.enter_feeding!
      end
      t2 = Thread.new do
        copy2.enter_feeding!
      end
      t1_succeeded = begin; t1.join; true; rescue; false; end
      t2_succeeded = begin; t2.join; true; rescue; false; end
      expect(t1_succeeded ^ t2_succeeded).to be_truthy
    end
    it "has heartbeat" do
      copy1 = Pet.first
      copy2 = Pet.first
      t1 = Thread.new do
        copy1.status_transition!(:feeding, :fed) do
          sleep 5
        end
      end
      t2 = Thread.new do
        sleep 0.5
        copy2.enter_feeding!
      end
      t1_succeeded = begin; t1.join; true; rescue; false; end
      t2_succeeded = begin; t2.join; true; rescue; false; end
      expect(t1_succeeded).to be_truthy
      expect(t2_succeeded).to be_falsey
    end
  end
end
