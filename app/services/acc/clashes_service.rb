# app/services/acc/clashes_service.rb
#
# Verified endpoints (same host as APS_BASE_URL, so ApsHttp#get works):
#   Modelsets: GET /bim360/modelset/v3/containers/:id/modelsets
#   Tests:     GET /bim360/clash/v3/containers/:id/modelsets/:ms/tests
#   Resources: GET /bim360/clash/v3/containers/:id/tests/:test/resources
#
# S3 download (different host, no auth) — direct RestClient call.
#
# Status mapping (status=1 confirmed in real data; 2/3 inferred from SDK):
#   1 = new, 2 = assigned, 3 = closed
#
# Cache: class-level in-memory, 1-hour TTL per container_id.

require_relative "../concerns/aps_http"

module Acc
  class ClashesService < ApplicationService
    include ApsHttp

    MODELSET_BASE = "/bim360/modelset/v3".freeze
    CLASH_BASE    = "/bim360/clash/v3".freeze
    CACHE_TTL     = 3600

    @cache        = {}
    @cache_mutex  = Mutex.new
    @fetch_locks  = Hash.new
    @locks_mutex  = Mutex.new

    class << self
      def clear_cache(container_id)
        @cache_mutex.synchronize { @cache.delete(container_id) }
      end

      def cached(container_id)
        @cache_mutex.synchronize do
          entry = @cache[container_id]
          return nil unless entry
          return nil if Time.now - entry[:cached_at] > CACHE_TTL
          entry[:data]
        end
      end

      def store_cache(container_id, data)
        @cache_mutex.synchronize do
          @cache[container_id] = { data: data, cached_at: Time.now }
        end
      end

      # One mutex per container_id, so concurrent requests for the SAME
      # container serialize (second caller waits, then reads the cache the
      # first caller just populated) while different containers never block
      # each other.
      def fetch_lock_for(container_id)
        @locks_mutex.synchronize { @fetch_locks[container_id] ||= Mutex.new }
      end
    end

    def initialize(token:)
      @token = token
    end

    # Returns:
    # {
    #   total:     Integer,
    #   by_status: { new: Integer, assigned: Integer, closed: Integer },
    #   modelsets: [{ modelSetId:, name:, total:, by_status:, lastTestedOn:,
    #                 clashes: [{ id:, status:, modelSetId: }] }]
    # }
    def summary(container_id)
      cached = self.class.cached(container_id)
      return cached if cached

      self.class.fetch_lock_for(container_id).synchronize do
        # Another thread may have finished fetching while we were waiting
        # for this lock — check again before doing the work ourselves.
        cached = self.class.cached(container_id)
        return cached if cached

        modelsets = fetch_modelsets(container_id)
                      .reject { |ms| ms["isDisabled"] || ms["isDeleted"] }

        modelset_summaries = modelsets.filter_map do |ms|
          build_modelset_summary(container_id, ms)
        end

        total_by_status = modelset_summaries.each_with_object(
          { new: 0, assigned: 0, closed: 0 }
        ) do |ms, acc|
          acc[:new]      += ms[:by_status][:new]
          acc[:assigned] += ms[:by_status][:assigned]
          acc[:closed]   += ms[:by_status][:closed]
        end

        result = {
          total:     total_by_status.values.sum,
          by_status: total_by_status,
          modelsets: modelset_summaries
        }

        self.class.store_cache(container_id, result)
        result
      end
    end

    private

    def fetch_modelsets(container_id)
      body = get("#{MODELSET_BASE}/containers/#{container_id}/modelsets", @token)
      body["modelSets"] || []
    rescue StandardError
      []
    end

    def build_modelset_summary(container_id, ms)
      t0 = Time.now
      latest_test = fetch_latest_test(container_id, ms["modelSetId"])
      return nil unless latest_test

      counts_and_clashes = fetch_clash_counts(container_id, latest_test["id"], ms["modelSetId"])
      return nil unless counts_and_clashes

      Rails.logger.info("[clashes timing] modelset #{ms['modelSetId']}: #{((Time.now - t0) * 1000).round}ms")

      {
        modelSetId:   ms["modelSetId"],
        name:         ms["name"],
        total:        counts_and_clashes[:counts].values.sum,
        by_status:    counts_and_clashes[:counts],
        lastTestedOn: latest_test["completedOn"],
        clashes:      counts_and_clashes[:clashes]
      }
    rescue => e
      Rails.logger.warn("ClashesService: skipping modelset #{ms['modelSetId']}: #{e.message}")
      nil
    end

    def fetch_latest_test(container_id, model_set_id)
      body  = get("#{CLASH_BASE}/containers/#{container_id}/modelsets/#{model_set_id}/tests", @token)
      tests = body["tests"] || []
      tests.select { |t| t["status"] == "Success" }
          .max_by { |t| t["modelSetVersion"].to_i }
    rescue StandardError
      nil
    end

    def fetch_clash_counts(container_id, test_id, model_set_id)
      body      = get("#{CLASH_BASE}/containers/#{container_id}/tests/#{test_id}/resources", @token)
      resources = body["resources"] || []

      resource = resources.find { |r| r["type"] == "scope-version-clash.2.0.0" }
      return nil unless resource

      download_and_count(resource["url"], model_set_id)
    end

    # S3 signed URL — different host, no auth header needed.
    def download_and_count(s3_url, model_set_id)
      response = RestClient::Request.execute(
          method: :get, url: s3_url, timeout: 30, open_timeout: 10
      )

      body    = response.body.force_encoding("UTF-8")
      raw_clashes = JSON.parse(body.sub(/\A\xEF\xBB\xBF/, ""))["clashes"] || []

      counts = { new: 0, assigned: 0, closed: 0 }
      retained_clashes = raw_clashes.map do |c|
        case c["status"]
        when 1 then counts[:new]      += 1
        when 2 then counts[:assigned] += 1
        when 3 then counts[:closed]   += 1
        end
        { id: c["id"], status: c["status"], modelSetId: model_set_id }
      end

      { counts: counts, clashes: retained_clashes }
    rescue RestClient::ExceptionWithResponse => e
      Rails.logger.error("ClashesService S3 download failed: #{e.response.code}")
      nil
    rescue StandardError => e
      Rails.logger.error("ClashesService S3 download failed: #{e.message}")
      nil
    end
  end
end
