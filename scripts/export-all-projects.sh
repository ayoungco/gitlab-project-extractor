#!/usr/bin/env bash

set -euo pipefail

OUT_DIR="${1:-project-exports}"
SERVICE="${GITLAB_SERVICE:-gitlab}"
CONTAINER="${GITLAB_CONTAINER:-gitlab-restore}"
POLL_INTERVAL="${GITLAB_EXPORT_POLL_INTERVAL:-5}"
TIMEOUT_SECONDS="${GITLAB_EXPORT_TIMEOUT_SECONDS:-300}"
PROJECT_DELAY_SECONDS="${GITLAB_EXPORT_PROJECT_DELAY_SECONDS:-10}"
RETRY_LIMIT="${GITLAB_EXPORT_RETRY_LIMIT:-12}"
RETRY_SLEEP_SECONDS="${GITLAB_EXPORT_RETRY_SLEEP_SECONDS:-60}"
CONTAINER_OUT="/tmp/gitlab-project-exports-$(date +%Y%m%d%H%M%S)"
TOKEN=""

cleanup() {
  if [[ -n "${TOKEN}" ]]; then
    docker compose exec -T "${SERVICE}" gitlab-rails runner \
      "PersonalAccessToken.find_by_token('${TOKEN}')&.revoke!" >/dev/null 2>&1 || true
  fi
}

trap cleanup EXIT

mkdir -p "${OUT_DIR}"

docker compose exec -T "${SERVICE}" sh -c \
  "mkdir -p /var/log/gitlab/gitlab-rails && touch /var/log/gitlab/gitlab-rails/production.log /var/log/gitlab/gitlab-rails/application_json.log && chown -R git:git /var/log/gitlab/gitlab-rails"

echo "Creating temporary GitLab API token"
TOKEN="$(
  docker compose exec -T "${SERVICE}" gitlab-rails runner "
    require 'securerandom'
    user = User.find_by_username('root') || User.admins.first
    raise 'No admin user found' unless user

    raw = 'glpat-' + SecureRandom.alphanumeric(32)
    token = user.personal_access_tokens.create!(
      name: 'local-bulk-project-export',
      scopes: ['api'],
      expires_at: 1.day.from_now
    )
    token.set_token(raw)
    token.save!
    puts raw
  "
)"

echo "Starting exports inside ${CONTAINER}:${CONTAINER_OUT}"
docker compose exec -T "${SERVICE}" mkdir -p "${CONTAINER_OUT}"
if find "${OUT_DIR}" -maxdepth 1 -type f | grep -q .; then
  echo "Copying existing local exports into container workspace for resume"
  docker cp "${OUT_DIR}/." "${CONTAINER}:${CONTAINER_OUT}/"
fi

set +e
docker compose exec -T \
  -e GITLAB_EXPORT_TOKEN="${TOKEN}" \
  -e GITLAB_EXPORT_DIR="${CONTAINER_OUT}" \
  -e GITLAB_EXPORT_POLL_INTERVAL="${POLL_INTERVAL}" \
  -e GITLAB_EXPORT_TIMEOUT_SECONDS="${TIMEOUT_SECONDS}" \
  -e GITLAB_EXPORT_PROJECT_DELAY_SECONDS="${PROJECT_DELAY_SECONDS}" \
  -e GITLAB_EXPORT_RETRY_LIMIT="${RETRY_LIMIT}" \
  -e GITLAB_EXPORT_RETRY_SLEEP_SECONDS="${RETRY_SLEEP_SECONDS}" \
  "${SERVICE}" ruby <<'RUBY'
require 'fileutils'
require 'json'
require 'net/http'
require 'uri'

$stdout.sync = true
$stderr.sync = true

TOKEN = ENV.fetch('GITLAB_EXPORT_TOKEN')
OUT_DIR = ENV.fetch('GITLAB_EXPORT_DIR')
POLL_INTERVAL = Integer(ENV.fetch('GITLAB_EXPORT_POLL_INTERVAL', '5'))
TIMEOUT_SECONDS = Integer(ENV.fetch('GITLAB_EXPORT_TIMEOUT_SECONDS', '1800'))
PROJECT_DELAY_SECONDS = Integer(ENV.fetch('GITLAB_EXPORT_PROJECT_DELAY_SECONDS', '2'))
RETRY_LIMIT = Integer(ENV.fetch('GITLAB_EXPORT_RETRY_LIMIT', '12'))
RETRY_SLEEP_SECONDS = Integer(ENV.fetch('GITLAB_EXPORT_RETRY_SLEEP_SECONDS', '30'))
BASE = 'http://127.0.0.1/api/v4'

FileUtils.mkdir_p(OUT_DIR)

class ApiError < StandardError
  attr_reader :code, :body, :headers

  def initialize(method, path, response)
    @code = response.code.to_i
    @body = response.body.to_s
    @headers = response.each_header.to_h
    super("#{method.name.split('::').last.upcase} #{path} failed: HTTP #{code} #{summary}")
  end

  def summary
    request_id = body[/Request ID:\s*<code>([^<]+)<\/code>/, 1]
    json_message = begin
      parsed = JSON.parse(body)
      parsed['message'] || parsed
    rescue JSON::ParserError
      nil
    end

    return json_message.inspect if json_message
    return "Request ID #{request_id}" if request_id

    body.gsub(/\s+/, ' ')[0, 240]
  end
end

def api_uri(path)
  URI("#{BASE}#{path}")
end

def request(method, path)
  uri = api_uri(path)
  req = method.new(uri)
  req['PRIVATE-TOKEN'] = TOKEN

  Net::HTTP.start(uri.host, uri.port, read_timeout: 600) do |http|
    http.request(req)
  end
end

def retry_after_seconds(error, attempt)
  header = error.headers['retry-after'].to_s
  return Integer(header) if header.match?(/\A\d+\z/)

  RETRY_SLEEP_SECONDS * attempt
end

def with_retries(label)
  attempt = 0

  begin
    attempt += 1
    yield
  rescue ApiError => e
    raise unless e.code == 429 && attempt <= RETRY_LIMIT

    sleep_for = retry_after_seconds(e, attempt)
    warn "  #{label} hit rate limit; retrying in #{sleep_for}s (attempt #{attempt}/#{RETRY_LIMIT})"
    sleep sleep_for
    retry
  end
end

def json_request(method, path, allowed:)
  res = request(method, path)
  unless allowed.include?(res.code.to_i)
    raise ApiError.new(method, path, res)
  end

  body = res.body.to_s
  body.empty? ? {} : JSON.parse(body)
end

def download(path, target)
  uri = api_uri(path)
  req = Net::HTTP::Get.new(uri)
  req['PRIVATE-TOKEN'] = TOKEN

  Net::HTTP.start(uri.host, uri.port, read_timeout: 1800) do |http|
    http.request(req) do |res|
      unless res.code.to_i == 200
        body = +''
        res.read_body { |chunk| body << chunk }
        response = Struct.new(:code, :body) do
          def each_header
            return enum_for(:each_header) unless block_given?
          end
        end.new(res.code, body)
        res.each_header { |key, value| response.define_singleton_method(:each_header) { { key => value }.each } }
        raise ApiError.new(Net::HTTP::Get, path, response)
      end

      tmp = "#{target}.tmp"
      File.open(tmp, 'wb') { |file| res.read_body { |chunk| file.write(chunk) } }
      File.rename(tmp, target)
    end
  end
end

projects = []
page = 1
loop do
  uri = "/projects?per_page=100&page=#{page}&simple=true&order_by=id&sort=asc"
  res = request(Net::HTTP::Get, uri)
  raise "GET #{uri} failed: HTTP #{res.code} #{res.body}" unless res.code.to_i == 200

  projects.concat(JSON.parse(res.body))
  next_page = res['x-next-page'].to_s
  break if next_page.empty?

  page = next_page
end

File.write(File.join(OUT_DIR, 'projects.json'), JSON.pretty_generate(projects))
puts "Found #{projects.length} projects"

failures = []

projects.each_with_index do |project, index|
  id = project.fetch('id')
  path = project.fetch('path_with_namespace')
  safe_name = path.gsub(%r{[^0-9A-Za-z._-]+}, '__')
  target = File.join(OUT_DIR, "#{safe_name}.tar.gz")

  puts "[#{index + 1}/#{projects.length}] Exporting #{path}"

  begin
    if File.exist?(target) && File.size(target).positive?
      puts "  already exists, skipping"
      next
    end

    with_retries('export request') do
      json_request(Net::HTTP::Post, "/projects/#{id}/export", allowed: [200, 201, 202, 409])
    end

    started = Time.now
    loop do
      status = with_retries('export status') do
        json_request(Net::HTTP::Get, "/projects/#{id}/export", allowed: [200])
      end
      export_status = status['export_status']

      case export_status
      when 'finished'
        break
      when 'failed'
        raise "export failed"
      end

      if Time.now - started > TIMEOUT_SECONDS
        raise "timed out waiting for export after #{TIMEOUT_SECONDS}s"
      end

      sleep POLL_INTERVAL
    end

    with_retries('export download') do
      download("/projects/#{id}/export/download", target)
    end
    puts "  wrote #{target}"
  rescue => e
    failures << "#{path}: #{e.message}"
    warn "  FAILED: #{e.message}"
  ensure
    sleep PROJECT_DELAY_SECONDS if PROJECT_DELAY_SECONDS.positive? && index < projects.length - 1
  end
end

unless failures.empty?
  File.write(File.join(OUT_DIR, 'failures.txt'), failures.join("\n") + "\n")
  warn "Failed exports:"
  failures.each { |failure| warn "  #{failure}" }
  exit 1
end

puts "All project exports completed"
RUBY
EXPORT_STATUS=$?
set -e

echo "Copying exports to ${OUT_DIR}"
docker cp "${CONTAINER}:${CONTAINER_OUT}/." "${OUT_DIR}/"

if [[ "${EXPORT_STATUS}" -eq 0 ]]; then
  docker compose exec -T "${SERVICE}" rm -rf "${CONTAINER_OUT}" >/dev/null
  echo "Export archives are in ${OUT_DIR}"
else
  echo "Some exports failed. Partial output was copied to ${OUT_DIR}; see failures.txt if present." >&2
  exit "${EXPORT_STATUS}"
fi
