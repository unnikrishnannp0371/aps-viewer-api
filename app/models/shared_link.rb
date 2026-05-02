class SharedLink < ApplicationRecord
  validates :token, presence: true, uniqueness: true
  validates :urn, presence: true
  validates :expires_at, presence: true

  def expired?
    expires_at < Time.current
  end

  def valid_for_viewing?
    !expired?
  end
end
