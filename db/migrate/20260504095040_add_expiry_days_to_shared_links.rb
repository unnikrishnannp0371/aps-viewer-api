class AddExpiryDaysToSharedLinks < ActiveRecord::Migration[8.1]
  def change
    add_column :shared_links, :expiry_days, :integer, null: false

    add_index :shared_links, [ :urn, :file_name, :expiry_days ], unique: true
  end
end
