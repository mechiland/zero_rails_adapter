# frozen_string_literal: true

require "active_record"
require "action_controller/railtie"
require "json"
require "rack/mock"
require "socket"
require "zero_rails_adapter"

ActiveRecord::Base.establish_connection(ENV.fetch("DATABASE_URL"))

class ContractBook < ActiveRecord::Base
end

class ContractLabel < ActiveRecord::Base
end

class ContractBookLabel < ActiveRecord::Base
end

class CreateContractBook < ZeroRailsAdapter::Mutator
  mutation_name "contract_books.create"

  attribute :id, :string
  attribute :sync_id, :string
  attribute :title, :string
  validates :id, :sync_id, :title, presence: true

  def perform
    ContractBook.create!(id:, sync_id:, title:)
    ContractLabel.create!(id: "label-#{id}", name: "Label #{title}")
    ContractBookLabel.create!(
      id: "link-#{id}",
      book_id: id,
      label_id: "label-#{id}"
    )
  end
end

module ZeroContract
  class Application < Rails::Application
    config.eager_load = false
    config.hosts.clear
    config.logger = Logger.new(nil)
    config.root = File.expand_path("../..", __dir__)
    config.secret_key_base = "zero-rails-adapter-contract"

    routes.append do
      mount ZeroRailsAdapter::Engine => "/zero"
    end
  end
end

ZeroRailsAdapter.configure do |config|
  config.request_verifier = ZeroRailsAdapter::RequestVerifiers::ApiKey.new(
    key: ENV.fetch("ZERO_MUTATE_API_KEY")
  )
end
ZeroRailsAdapter.registry.register(CreateContractBook)
ZeroContract::Application.initialize!

port = Integer(ENV.fetch("PORT"))
mutation_log_path = ENV.fetch("MUTATION_LOG_PATH")
server = TCPServer.new("127.0.0.1", port)
stopping = false

stop = proc do
  stopping = true
  server.close
rescue IOError
  nil
end
Signal.trap("INT", &stop)
Signal.trap("TERM", &stop)

until stopping
  socket = nil
  begin
    socket = server.accept
    request_line = socket.gets
    next unless request_line

    method, target, = request_line.split
    headers = {}
    while (line = socket.gets)
      break if line == "\r\n"

      name, value = line.split(":", 2)
      headers[name.downcase] = value.to_s.strip
    end
    body = socket.read(headers.fetch("content-length", "0").to_i)

    if method == "POST" && target.start_with?("/zero/")
      File.open(mutation_log_path, "a") do |file|
        file.puts(JSON.generate({"path" => target, "body" => JSON.parse(body)}))
      end
    end

    rack_headers = headers.each_with_object({}) do |(name, value), result|
      key = case name
      when "content-length" then "CONTENT_LENGTH"
      when "content-type" then "CONTENT_TYPE"
      else "HTTP_#{name.upcase.tr('-', '_')}"
      end
      result[key] = value
    end
    env = Rack::MockRequest.env_for(
      target,
      method:,
      input: body,
      **rack_headers
    )
    status, response_headers, response_body =
      ZeroContract::Application.call(env)
    payload = +""
    response_body.each { |part| payload << part }
    response_body.close if response_body.respond_to?(:close)

    socket.write("HTTP/1.1 #{status} OK\r\n")
    response_headers.each do |name, value|
      next if name.downcase == "content-length"

      socket.write("#{name}: #{Array(value).join("\n#{name}: ")}\r\n")
    end
    socket.write("Content-Length: #{payload.bytesize}\r\n")
    socket.write("Connection: close\r\n\r\n")
    socket.write(payload)
  rescue IOError, Errno::EBADF
    raise unless stopping
  rescue StandardError => error
    warn "#{error.class}: #{error.message}"
    socket&.write(
      "HTTP/1.1 500 Internal Server Error\r\n" \
      "Content-Length: 0\r\nConnection: close\r\n\r\n"
    )
  ensure
    socket&.close
  end
end
