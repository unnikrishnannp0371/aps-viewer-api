require_relative "base"
module Aps
  class DataManagementService
    class << self
      # ----------------------------
      # API Methods
      # ----------------------------
      # These methods correspond to the various endpoints of the APS Data Management API.
      # Each method takes an access token as a parameter and returns the parsed JSON response.

      # Encodes and decodes IDs to create opaque identifiers for clients, preventing direct exposure of raw APS IDs.
      def encode_id(id)
        Base64.urlsafe_encode64(id.to_s, padding: false)
      end

      # Decoding method to convert the opaque identifier back to the original APS ID when making API calls. Handles potential decoding errors gracefully.
      def decode_id(encoded_id)
        Base64.urlsafe_decode64(encoded_id.to_s)
      rescue ArgumentError => e
        Rails.logger.error("ID Decoding Error: #{e.message}")
        raise StandardError, "Invalid ID provided"
      end

      # Fetches the list of hubs accessible to the authenticated user
      def get_hubs(access_token)
        data = get("/project/v1/hubs", access_token)
        data["data"].map do |hub|
          {
            id: encode_id(hub["id"]),
            name: hub["attributes"]["name"],
            type: hub.dig("attributes", "extension", "type")
          }
        end
      end

      # Fetches the list of projects within a specific hub
      def get_projects(hub_id, access_token)
        decoded_hub_id = decode_id(hub_id)
        data = get("/project/v1/hubs/#{decoded_hub_id}/projects", access_token)
        data["data"].map do |project|
          {
            project_id: encode_id(project["id"]),
            hub_id:,
            name: project.dig("attributes", "name"),
            type: project.dig("attributes", "extension", "type")
          }
        end
      end

      # Fetches the top-level folders of a specific project, which typically include "Design" and "Shared"
      def get_top_folders(hub_id, project_id, access_token)
        decoded_project_id = decode_id(project_id)
        decoded_hub_id = decode_id(hub_id)
        data = get("/project/v1/hubs/#{decoded_hub_id}/projects/#{decoded_project_id}/topFolders?projectFilesOnly=true", access_token)
        data["data"].map do |folder|
          {
            folder_id: encode_id(folder["id"]),
            project_id:,
            name: folder.dig("attributes", "name"),
            type: folder.dig("attributes", "extension", "type")
          }
        end
      end

      # Fetches the contents of a specific folder, including subfolders and items
      def get_folder_contents(project_id, folder_id, access_token)
        decoded_project_id = decode_id(project_id)
        decoded_folder_id  = decode_id(folder_id)
        data = get("/data/v1/projects/#{decoded_project_id}/folders/#{decoded_folder_id}/contents", access_token)

        tip_urns = {}
        (data["included"] || []).each do |version|
          vid = version.dig("relationships", "item", "data", "id")
          urn = version.dig("relationships", "derivatives", "data", "id")
          tip_urns[vid] = urn if vid && urn
        end

        data["data"].map do |item|
          raw_item_id = item["id"]
          {
            content_id:  encode_id(raw_item_id),
            folder_id:   folder_id,
            project_id:  project_id,
            name:        item.dig("attributes", "displayName"),
            type:        item.dig("attributes", "extension", "type"),
            tip_urn:     tip_urns[raw_item_id] ? encode_id(tip_urns[raw_item_id]) : nil
          }
        end
      end

      def get_item_versions(project_id, item_id, access_token)
        decoded_project_id = decode_id(project_id)
        decoded_item_id = decode_id(item_id)
        data = get("/data/v1/projects/#{decoded_project_id}/items/#{decoded_item_id}/versions", access_token)
        data["data"].map do |version|
          urn = version.dig("relationships", "derivatives", "data", "id")
          {
            version_id: encode_id(version["id"]),
            version_urn: urn ? encode_id(urn) : nil,
            version_number: version.dig("attributes", "versionNumber"),
            name:           version.dig("attributes", "displayName"),
            file_type:      version.dig("attributes", "fileType"),
            created_at:     version.dig("attributes", "createTime"),
            created_by:     version.dig("attributes", "createUserName")
          }
        end
      end

      private

      # Helper method to perform a GET request to the APS API with the appropriate headers and error handling
      def get(path, access_token)
        response = RestClient.get("#{Aps::Base::BASE_URL}#{path}",
                                  { Authorization: "Bearer #{access_token}" })
        JSON.parse(response.body)
      rescue RestClient::ExceptionWithResponse => e
        Rails.logger.error("APS Data Management Error: #{e.response}")
        raise StandardError, "Failed to fetch data from APS"
      end
    end
  end
end
