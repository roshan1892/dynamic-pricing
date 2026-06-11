class CreateCachedRates < ActiveRecord::Migration[7.1]
  def change
    create_table :cached_rates do |t|
      t.string :period,     null: false
      t.string :hotel,      null: false
      t.string :room,       null: false
      t.string :rate,       null: false
      t.datetime :fetched_at, null: false

      t.timestamps
    end

    add_index :cached_rates, [:period, :hotel, :room], unique: true
  end
end
