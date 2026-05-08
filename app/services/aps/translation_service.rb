require_relative "base"
require "uri"

module Aps
  class TranslationService
    class << self
      # Start translation job
      def translate(encoded_urn, access_token)
        raw_urn = Base64.urlsafe_decode64(encoded_urn)

        payload = {
          input: {
            urn: raw_urn
          },
          output: {
            formats: [
              {
                type: "svf2",
                views: [ "2d", "3d" ]
              }
            ]
          }
        }.to_json

        response = RestClient.post(
          "#{Aps::Base::BASE_URL}/modelderivative/v2/designdata/job",
          payload,
          Authorization: "Bearer #{access_token}",
          "Content-Type": "application/json",
          Accept: "application/json",
          "x-ads-force": "true"
        )

        result = JSON.parse(response.body)
        {
          urn: encoded_urn,
          status: result["status"] || "pending"
        }
      rescue RestClient::ExceptionWithResponse => e
        Rails.logger.error("APS Translation Error: #{e.response.body}")
        raise StandardError, "Translation failed: #{e.response.code}"
      end

      def translation_status(encoded_urn, access_token)
        # Decode our encoding layer to get the APS base64 URN
        aps_urn = Base64.urlsafe_decode64(encoded_urn)

        # aps_urn is already the base64 URN APS expects
        # Just URL-encode any special characters for the path
        url_urn = URI.encode_www_form_component(aps_urn)

        response = RestClient.get(
          "#{Aps::Base::BASE_URL}/modelderivative/v2/designdata/#{url_urn}/manifest",
          Authorization: "Bearer #{access_token}",
          Accept: "application/json"
        )

        result = JSON.parse(response.body)
        {
          urn:      encoded_urn,
          status:   result["status"],
          progress: result["progress"] || "0%"
        }
      rescue RestClient::ExceptionWithResponse => e
        Rails.logger.error("APS Status Error: #{e.response.body}")
        raise StandardError, "Status check failed: #{e.response.code}"
      end
    end
  end
end
