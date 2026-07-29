# frozen_string_literal: true

require "fileutils"
require "net/http"
require "pg"
require "socket"
require "timeout"

ROOT = File.expand_path("../..", __dir__)
CONTRACT_DIR = __dir__
TMP_DIR = File.join(ROOT, "tmp", "zero-contract")
POSTGRES_IMAGE = "postgres:17"

def free_port
  TCPServer.open("127.0.0.1", 0) { |server| server.addr[1] }
end

def run!(*command, env: {}, chdir: ROOT)
  success = system(env, *command, chdir:)
  raise "Command failed: #{command.join(' ')}" unless success
end

def spawn_service(name, *command, env:, chdir:)
  log_path = File.join(TMP_DIR, "#{name}.log")
  log = File.open(log_path, "a")
  pid = Process.spawn(
    env,
    *command,
    chdir:,
    out: log,
    err: [:child, :out],
    pgroup: true
  )
  [pid, log]
end

def wait_for_http(url, pid:, name:)
  Timeout.timeout(60) do
    loop do
      raise "#{name} exited before becoming ready" unless process_alive?(pid)

      begin
        response = Net::HTTP.get_response(URI(url))
        return if response.code.to_i < 500
      rescue Errno::ECONNREFUSED, EOFError, Net::HTTPBadResponse
        nil
      end
      sleep 0.2
    end
  end
end

def process_alive?(pid)
  Process.waitpid(pid, Process::WNOHANG).nil?
rescue Errno::ECHILD
  false
end

def stop_service(pid)
  return unless process_alive?(pid)

  Process.kill("TERM", -pid)
  Timeout.timeout(10) { Process.wait(pid) }
rescue Errno::EPERM
  Process.kill("TERM", pid)
  Timeout.timeout(10) { Process.wait(pid) }
rescue Errno::ESRCH, Errno::ECHILD
  nil
rescue Timeout::Error
  Process.kill("KILL", -pid)
  Process.wait(pid)
end

def print_logs
  Dir[File.join(TMP_DIR, "*.log")].sort.each do |path|
    warn "\n== #{File.basename(path)} =="
    warn File.readlines(path).last(250).join
  end
end

FileUtils.rm_rf(TMP_DIR)
FileUtils.mkdir_p(TMP_DIR)

postgres_port = free_port
rails_port = free_port
query_port = free_port
zero_port = free_port
change_streamer_port = free_port
container_name = "zero-rails-adapter-contract-#{Process.pid}"
database_url =
  "postgres://postgres:postgres@127.0.0.1:#{postgres_port}/zero_contract"
mutation_log_path = File.join(TMP_DIR, "mutations.jsonl")
services = []
logs = []
passed = false

begin
  run!(
    "docker", "run", "--detach",
    "--name", container_name,
    "--env", "POSTGRES_DB=zero_contract",
    "--env", "POSTGRES_PASSWORD=postgres",
    "--publish", "127.0.0.1:#{postgres_port}:5432",
    POSTGRES_IMAGE,
    "postgres", "-c", "wal_level=logical"
  )

  Timeout.timeout(60) do
    loop do
      connection = PG.connect(database_url)
      connection.close
      break
    rescue PG::Error
      sleep 0.2
    end
  end

  contract_env = {
    "DATABASE_URL" => database_url,
    "MUTATION_LOG_PATH" => mutation_log_path,
    "ZERO_CONTRACT_GENERATED_DIR" => File.join(CONTRACT_DIR, "generated"),
    "ZERO_MUTATE_API_KEY" => "zero-contract-secret"
  }
  run!(
    "bundle", "exec", "ruby", "test/contract/prepare.rb",
    env: contract_env
  )
  run!("npm", "run", "typecheck", chdir: CONTRACT_DIR)

  rails_pid, rails_log = spawn_service(
    "rails",
    "bundle", "exec", "ruby", "test/contract/rails_server.rb",
    env: contract_env.merge("PORT" => rails_port.to_s),
    chdir: ROOT
  )
  services << rails_pid
  logs << rails_log
  wait_for_http(
    "http://127.0.0.1:#{rails_port}/zero/mutate",
    pid: rails_pid,
    name: "Rails endpoint"
  )

  query_pid, query_log = spawn_service(
    "query",
    "npm", "run", "query-server",
    env: contract_env.merge("QUERY_PORT" => query_port.to_s),
    chdir: CONTRACT_DIR
  )
  services << query_pid
  logs << query_log
  wait_for_http(
    "http://127.0.0.1:#{query_port}/health",
    pid: query_pid,
    name: "query endpoint"
  )

  zero_env = contract_env.merge(
    "NODE_ENV" => "development",
    "ZERO_APP_ID" => "contract",
    "ZERO_APP_PUBLICATIONS" => "zero_contract_data",
    "ZERO_CHANGE_STREAMER_PORT" => change_streamer_port.to_s,
    "ZERO_MUTATE_URL" => "http://127.0.0.1:#{rails_port}/zero/mutate",
    "ZERO_NUM_SYNC_WORKERS" => "1",
    "ZERO_PORT" => zero_port.to_s,
    "ZERO_QUERY_URL" => "http://127.0.0.1:#{query_port}/query",
    "ZERO_REPLICA_FILE" => File.join(TMP_DIR, "zero.db"),
    "ZERO_UPSTREAM_DB" => database_url,
    "ZERO_UPSTREAM_MAX_CONNS" => "5"
  )
  zero_pid, zero_log = spawn_service(
    "zero-cache",
    "npm", "run", "zero-cache",
    env: zero_env,
    chdir: CONTRACT_DIR
  )
  services << zero_pid
  logs << zero_log
  wait_for_http(
    "http://127.0.0.1:#{zero_port}/",
    pid: zero_pid,
    name: "zero-cache"
  )

  run!(
    "npm", "run", "client",
    chdir: CONTRACT_DIR,
    env: contract_env.merge(
      "RAILS_MUTATE_URL" => "http://127.0.0.1:#{rails_port}",
      "ZERO_CACHE_URL" => "http://127.0.0.1:#{zero_port}"
    )
  )
  passed = true
ensure
  services.reverse_each { |pid| stop_service(pid) }
  logs.each(&:close)
  run!(
    "docker", "rm", "--force", container_name,
    chdir: ROOT
  ) if system(
    "docker", "container", "inspect", container_name,
    out: File::NULL,
    err: File::NULL
  )
  print_logs unless passed
end
