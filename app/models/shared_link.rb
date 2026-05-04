class SharedLink < ApplicationRecord
  validates :token, presence: true, uniqueness: true
  validates :urn, presence: true
  validates :expires_at, presence: true

  scope :not_expired, -> { where("expires_at >= ?", Time.current) }

  enum :expiry_days, {
    days_7: 7,
    days_30: 30,
    days_90: 90
  }

  def expired?
    expires_at < Time.current
  end

  def valid_for_viewing?
    !expired?
  end
end
