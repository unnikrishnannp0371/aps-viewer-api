class ApplicationService
  # Shared ID encoding helpers available as both class and instance methods.
  # DataManagementService inherits these instead of duplicating them.

  def self.encode_id(id)
    Base64.urlsafe_encode64(id.to_s, padding: false)
  end

  def self.decode_id(encoded_id)
    Base64.urlsafe_decode64(encoded_id.to_s)
  rescue ArgumentError => e
    Rails.logger.error("ID Decoding Error: #{e.message}")
    raise StandardError, "Invalid ID provided"
  end

  # Autodesk Data Management project IDs carry a "b." prefix (e.g. "b.9c8e7447-...").
  # ACC construction APIs (Issues, RFIs, Health) reject that prefix and expect a bare UUID.
  # Use this instead of decode_id whenever passing a project ID to an ACC construction API.
  def self.acc_project_id(encoded_id)
    decode_id(encoded_id).delete_prefix("b.")
  end

  # Delegate instance calls to class methods so existing instance-style callers
  # continue to work without changes.
  def encode_id(id)      = self.class.encode_id(id)
  def decode_id(id)      = self.class.decode_id(id)
  def acc_project_id(id) = self.class.acc_project_id(id)
end
