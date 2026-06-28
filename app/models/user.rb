class User < ApplicationRecord
  has_many :monitors, class_name: "Monitoring::Monitor", dependent: :destroy

  normalizes :email_address, with: ->(e) { e.strip.downcase }

  validates :email_address, presence: true, uniqueness: { case_sensitive: false }
end
