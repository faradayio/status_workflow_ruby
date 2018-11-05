ActiveRecord::Base.connection.execute <<-SQL
  CREATE TABLE pets (
    id serial primary key,
    status text,
    status_changed_at timestamp without time zone,
    status_error text,
    alt_status text,
    alt_status_changed_at timestamp without time zone,
    alt_status_error text
  )
SQL
class Pet < ActiveRecord::Base
  before_create do
    self.status ||= 'sleep'
  end
  include StatusWorkflow
  status_workflow(
    sleep: ['feeding'],
    feeding: [:fed],
    'fed' => [:sleep, :run],
    run: [:sleep],
  )
  before_status_transition do
    ActiveRecord::Base.clear_active_connections!
    ActiveRecord::Base.flush_idle_connections!
  end
end

class PetAlt < ActiveRecord::Base
  self.table_name = 'pets'
  before_create do
    self.alt_status ||= 'sleep'
  end
  include StatusWorkflow
  status_workflow(
    alt: {
      sleep: [:feeding],
      feeding: [:fed],
      fed: [:sleep, :run],
      run: [:sleep],
    }
  )
end

class PetBoth < ActiveRecord::Base
  self.table_name = 'pets'
  before_create do
    self.status ||= 'sleep'
    self.alt_status ||= 'sleep2'
  end
  include StatusWorkflow
  status_workflow(
    nil => {
      sleep: [:feeding],
      feeding: [:fed],
      fed: [:sleep, :run],
      run: [:sleep],
    },
    alt: {
      sleep2: [:feeding2],
      feeding2: [:fed2],
      fed2: [:sleep2, :run2],
      run2: [:sleep2],
    }
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
    it "can always set error" do
      expect{pet.enter_error!}.not_to raise_error
      expect(pet.status).to eq('error')
    end
    it "won't blow up if you gently request a run" do
      expect{pet.enter_run_if_possible}.not_to raise_error
      expect(pet.status).to eq('sleep')
    end
    it "can set an intermediate status with block" do
      expect(pet.status).to eq('sleep')
      pet.status_transition!(:feeding, :fed) do
        expect(pet.status).to eq('feeding')
      end
      expect(pet.status).to eq('fed')
    end
    it "returns the result of the block" do
      result = pet.status_transition!(:feeding, :fed) do
        123
      end
      expect(result).to eq(123)
    end
    it "can set error on block" do
      expect {
        pet.status_transition!(:feeding, :fed) do
          raise "nyet"
        end
      }.to raise_error(/nyet/)
      pet.reload
      expect(pet.status_error).to match(/RuntimeError.*nyet/)
      expect(pet.status).to eq('feeding_error')
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
  describe "alternate column" do
    let(:pet) { PetAlt.create! }
    it "can use an alternate status column" do
      expect(pet.alt_status).to eq('sleep')
      pet.alt_status_transition!(:feeding, :fed) do
        expect(pet.alt_status).to eq('feeding')
      end
      expect(pet.alt_status).to eq('fed')
      expect(pet.alt_status_changed_at).not_to be_nil
      expect(pet.status).to be_nil
    end
    it "can set alternate error" do
      expect {
        pet.alt_status_transition!(:feeding, :fed) do
          raise "nyet"
        end
      }.to raise_error(/nyet/)
      pet.reload
      expect(pet.alt_status_error).to match(/RuntimeError.*nyet/)
      expect(pet.alt_status_changed_at).not_to be_nil
      expect(pet.alt_status).to eq('feeding_error')
      expect(pet.status).to be_nil
    end
  end
  describe "2 columns" do
    let(:pet) { PetBoth.create! }
    it "can use an alternate status column" do
      expect(pet.status).to eq('sleep')
      expect(pet.alt_status).to eq('sleep2')
      pet.status_transition!(:feeding, :fed) do
        expect(pet.status).to eq('feeding')
        expect(pet.alt_status).to eq('sleep2')
      end
      expect(pet.status).to eq('fed')
      expect(pet.alt_status).to eq('sleep2')
      pet.alt_status_transition!(:feeding2, :fed2) do
        expect(pet.status).to eq('fed')
        expect(pet.alt_status).to eq('feeding2')
      end
    end
    it "uses different locks" do
      pet.status_transition!(:feeding, :fed) do
        expect(pet.status).to eq('feeding')
        expect(pet.alt_status).to eq('sleep2')
        pet.alt_status_transition!(:feeding2, :fed2) do
          expect(pet.status).to eq('feeding')
          expect(pet.alt_status).to eq('feeding2')
        end
        expect(pet.status).to eq('feeding')
        expect(pet.alt_status).to eq('fed2')
      end
      expect(pet.status).to eq('fed')
      expect(pet.alt_status).to eq('fed2')
    end
  end

end
