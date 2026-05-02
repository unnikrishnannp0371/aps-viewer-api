class CreateSharedLinks < ActiveRecord::Migration[8.1]
  def change
    create_table :shared_links do |t|
      t.string :token,      null: false
      t.string :urn,        null: false
      t.string :file_name
      t.datetime :expires_at, null: false
      t.integer :view_count, default: 0

      t.timestamps
    end

    add_index :shared_links, :token, unique: true
  end
end
