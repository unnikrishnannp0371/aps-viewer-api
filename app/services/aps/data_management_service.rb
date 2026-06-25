require_relative "../application_service"
require_relative "base"
require_relative "../concerns/aps_http"
require "cgi"

module Aps
  class DataManagementService < ApplicationService
    include ApsHttp

    # encode_id / decode_id / acc_project_id inherited from ApplicationService.

    def initialize(token:)
      @token = token
    end

    # ── Hubs ───────────────────────────────────────────────────────────────

    def get_hubs
      data = get("/project/v1/hubs", @token)
      (data["data"] || []).map do |hub|
        {
          id:   encode_id(hub["id"]),
          name: hub.dig("attributes", "name"),
          type: hub.dig("attributes", "extension", "type")
        }
      end
    end

    # ── Projects ───────────────────────────────────────────────────────────

    def get_projects(hub_id)
      decoded_hub_id = decode_id(hub_id)
      data = get("/project/v1/hubs/#{decoded_hub_id}/projects", @token)

      (data["data"] || []).map do |project|
        {
          project_id: encode_id(project["id"]),
          hub_id:     hub_id,
          name:       project.dig("attributes", "name"),
          type:       project.dig("attributes", "extension", "type")
        }
      end
    end

    # ── Project Details ────────────────────────────────────────────────────

    def get_project_details(hub_id, project_id)
      decoded_hub_id     = decode_id(hub_id)
      decoded_project_id = decode_id(project_id)
      data    = get("/project/v1/hubs/#{decoded_hub_id}/projects/#{decoded_project_id}", @token)
      project = data["data"]

      # IMPORTANT: issue_container_id must come from relationships, not project UUID.
      issue_container_id =
        project.dig("relationships", "issues", "data", "id") ||
        project.dig("relationships", "issueContainerId", "data", "id")

      {
        project_id:         encode_id(project["id"]),
        name:               project.dig("attributes", "name"),
        type:               project.dig("attributes", "extension", "type"),
        issue_container_id: issue_container_id
      }
    end

    # ── Top Folders ────────────────────────────────────────────────────────

    def get_top_folders(hub_id, project_id)
      decoded_hub_id     = decode_id(hub_id)
      decoded_project_id = decode_id(project_id)
      path = "/project/v1/hubs/#{decoded_hub_id}/projects/#{decoded_project_id}/topFolders?projectFilesOnly=true"
      data = get(path, @token)

      data["data"].map do |folder|
        {
          folder_id:  encode_id(folder["id"]),
          project_id: project_id,
          name:       folder.dig("attributes", "name"),
          type:       folder.dig("attributes", "extension", "type")
        }
      end
    end

    # ── Folder Contents ────────────────────────────────────────────────────

    def get_folder_contents(project_id, folder_id)
      decoded_project_id = decode_id(project_id)
      decoded_folder_id  = decode_id(folder_id)
      data = get("/data/v1/projects/#{decoded_project_id}/folders/#{decoded_folder_id}/contents", @token)

      tip_urns = (data["included"] || []).each_with_object({}) do |version, h|
        item_id        = version.dig("relationships", "item", "data", "id")
        derivative_urn = version.dig("relationships", "derivatives", "data", "id")
        h[item_id] = derivative_urn if item_id && derivative_urn
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

    # ── Item Versions ──────────────────────────────────────────────────────

    def get_item_versions(project_id, item_id)
      decoded_project_id = decode_id(project_id)
      decoded_item_id    = decode_id(item_id)
      data = get("/data/v1/projects/#{decoded_project_id}/items/#{decoded_item_id}/versions", @token)

      data["data"].map do |version|
        urn = version.dig("relationships", "derivatives", "data", "id")
        {
          version_id:     encode_id(version["id"]),
          version_urn:    urn ? encode_id(urn) : nil,
          version_number: version.dig("attributes", "versionNumber"),
          name:           version.dig("attributes", "displayName"),
          file_type:      version.dig("attributes", "fileType"),
          created_at:     version.dig("attributes", "createTime"),
          created_by:     version.dig("attributes", "createUserName")
        }
      end
    end
  end
end
