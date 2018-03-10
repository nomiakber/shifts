class CreateTemplateTimeSlots < ActiveRecord::Migration
  def self.up
    create_table :template_time_slots do |t|
			t.references :location
			t.references :template
      t.integer :day
      t.datetime :start_time
      t.datetime :end_time

      t.timestamps
    end
  end

  def self.down
    drop_table :template_time_slots
  end
end
