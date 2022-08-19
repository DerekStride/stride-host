require "functions_framework"
require "kubeclient"
require "googleauth"
require "websocket-client-simple"
require "google/cloud/pubsub"
require "pry-byebug" if ENV["PRY"]

EXEC_STDIN = 0
EXEC_STDOUT = 1
EXEC_STDERR = 2
TOPIC = "discord-events"
SCOPE = "https://www.googleapis.com/auth/cloud-platform"

SCALE_DOWN_MESSAGE = JSON.dump({
  "data" => {
    "name" => "mc-scale",
    "options" => [{
      "value"=>"off"
    }],
  },
})

def kube_client_options
  config = Kubeclient::Config.read(ENV["KUBE_CONFIG"])
  authorizer = Google::Auth::ServiceAccountCredentials.from_env(scope: SCOPE)
  token = authorizer.fetch_access_token!
  context = config.context

  {
    api_endpoint: context.api_endpoint,
    api_version: context.api_version,
    ssl_options: context.ssl_options,
    bearer_token: token["access_token"],
  }
end

def build_apps_client(api_endpoint:, api_version:, ssl_options:, bearer_token:)
  Kubeclient::Client.new("#{api_endpoint}/apis/apps", api_version, ssl_options: ssl_options, auth_options: { bearer_token: bearer_token })
end

FunctionsFramework.cloud_event "scheduled-mc-scale-down" do |event|
  kube_options = kube_client_options
  statefulset = build_apps_client(**kube_options)
    .get_stateful_set("mc-lutova", "default")

  return "The server is off." if statefulset.status.replicas.zero?

  uri = URI("#{kube_options[:api_endpoint]}/api/#{kube_options[:api_version]}/namespaces/default/pods/mc-lutova-0/exec")
  uri.query = URI.encode_www_form(
    stdin: true,
    stdout: true,
    stderr: true,
    tty: false,
    container: "mc",
    command: "mc-health",
  )
  ws = WebSocket::Client::Simple.connect(
    uri.to_s,
    headers: { Authorization: "Bearer #{kube_options[:bearer_token]}" },
    cert_store: kube_options.dig(:ssl_options, :cert_store),
    verify_mode: kube_options.dig(:ssl_options, :verify_ssl),
  )

  buffer = +""

  ws.on(:message) do |msg|
    ws.close if msg.type == :close
    break if msg.data.empty?

    data = msg.data.unpack("C*")
    case data.shift
    when EXEC_STDOUT
      buffer << data.pack("C*").force_encoding('utf-8')
    when EXEC_STDERR
      logger.warn "E #{data.pack("C*").force_encoding('utf-8')}"
    else
      logger.error "W Unknown channel"
      logger.error "W #{data.inspect}"
    end
  end

  ws.on(:error) { |msg| ws.close }
  ws.on(:close) { |msg| ws.close }

  loop do
    ws.send(EXEC_STDIN)
    break if ws.closed?
    sleep(1)
  end

  match_data = buffer.match(/online=(?<players_online>\d+)/)
  return "Pod is not ready, skipping shutdown" unless match_data

  players_online_match = match_data[:players_online]
  return "Match failed, buffer=\"#{buffer.chomp}\", match_data=\"#{match_data.inspect}\"" if players_online_match.nil? || players_online_match.empty?

  players_online = players_online_match.to_i
  return "Players are online, skipping shutdown." unless players_online.zero?

  client = Google::Cloud::PubSub.new
  topic = client.topic(TOPIC)
  topic.publish(SCALE_DOWN_MESSAGE)

  "The server shutdown was initiated."
end
