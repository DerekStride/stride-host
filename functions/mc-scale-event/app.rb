require "functions_framework"
require "kubeclient"
require "googleauth"
require "pry-byebug" if ENV["PRY"]

SCOPE = "https://www.googleapis.com/auth/cloud-platform"
DISCORD_API_URL = "https://discord.com/api/v10"
FOLLOW_UP_PATH_TEMPLATE = "#{DISCORD_API_URL}/webhooks/%{app_id}/%{token}"

FunctionException = Class.new(StandardError)

def mc_scale(apps_client, replicas:)
  apps_client.patch_stateful_set("mc-lutova", { spec: { replicas: replicas } }, "default")
rescue Kubeclient::HttpError => e
  raise FunctionException, <<~ERROR
    Scaling the statefulset failed due to Kubernetes Error: "#{e.class}"

    #{e.message}
  ERROR
end

def send_follow_up(message, app_id:, interaction_token:)
  return unless app_id && interaction_token

  Net::HTTP.post(
    URI(FOLLOW_UP_PATH_TEMPLATE % { app_id: app_id, token: interaction_token }),
    { "content" => message }.to_json,
    { "Content-Type" => "application/json" },
  )
end

def build_kube_client
  config = Kubeclient::Config.read(ENV["KUBE_CONFIG"])
  authorizer = Google::Auth::ServiceAccountCredentials.from_env(scope: SCOPE)
  token = authorizer.fetch_access_token!
  context = config.context

  Kubeclient::Client.new(
    "#{context.api_endpoint}/apis/apps",
    context.api_version,
    ssl_options: context.ssl_options,
    auth_options: {
      bearer_token: token["access_token"],
    },
  )
end

FunctionsFramework.cloud_event "mc-scale" do |event|
  apps_client = build_kube_client
  message = JSON.parse(Base64.decode64(event.data.dig("message", "data")))

  follow_up_options = {
    app_id: message["application_id"],
    interaction_token: message["token"],
  }

  event_name = message.dig("data", "name")
  if event_name == "mc-scale"
    subcommand = message.dig("data", "options", 0, "value")

    if subcommand == "on"
      mc_scale(apps_client, replicas: 1)
      send_follow_up(<<~MSG, **follow_up_options)
        Scaling server up succeeded.
      MSG
    elsif subcommand == "off"
      mc_scale(apps_client, replicas: 0)
      send_follow_up(<<~MSG, **follow_up_options)
        Scaling server down succeeded.
      MSG
    elsif subcommand == "status"
      send_follow_up(<<~MSG, **follow_up_options)
        The server is off?
      MSG
    else
      return "Unknown subcommand: #{subcommand}"
    end

    "Handling /#{event_name} #{subcommand}"
  else
    "Unknown Event: /#{event_name}"
  end
rescue FunctionException => e
  send_follow_up(e.message, **follow_up_options)
rescue Kubeclient::HttpError => e
  send_follow_up(<<~MSG, **follow_up_options)
    Kubernetes Error: "#{e.class}"

    #{e.message}
  MSG
rescue => e
  send_follow_up(<<~MSG, **follow_up_options)
    Error caught: "#{e.class}"

    #{e.message}
  MSG
end
